// guiltty's renderer: a separate program that Guiltty.Window runs as an
// Erlang port. It keeps a mirror of the visible cells, draws them through a
// backend, and reports keys and window resizes. If it crashes, only the
// window goes away.
//
//   guiltty_gl           port mode: talks the protocol on stdin/stdout
//   guiltty_gl --demo    standalone: draws a fixed screen, no port
//
// stdout belongs to the protocol. Diagnostics go to stderr only.

#define _GNU_SOURCE

#include <SDL3/SDL.h>
#include <signal.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "atlas.h"
#include "backend.h"
#include "protocol.h"

constexpr int font_pixel_size = 18;
constexpr int padding_px = 6;
constexpr uint16_t default_cols = 80;
constexpr uint16_t default_rows = 24;
constexpr uint16_t max_grid = 4096; // cols or rows; far beyond any screen
constexpr int min_cols = 10;
constexpr int min_rows = 3;

struct theme {
    uint8_t palette[palette_size][3];
    uint8_t fg[3], bg[3], cursor[3];
};

struct renderer {
    SDL_Window *window;
    void *backend;
    int cell_w, cell_h;
    uint16_t cols, rows;
    struct cell *cells; // cols * rows
    uint16_t cursor_row, cursor_col;
    bool cursor_visible;
    struct theme theme;
    uint32_t port_event; // SDL user event type for port messages
    bool demo;
    bool dirty;
};

// Reader thread: blocks on stdin and hands each message to the main thread
// as an SDL user event. data1 is the message (nullptr on EOF or error), code
// its length. SDL_PushEvent is safe to call from any thread.
static int port_reader(void *data) {
    uint32_t type = *(uint32_t *)data;
    for (;;) {
        uint8_t *msg = nullptr;
        uint32_t len = 0;
        enum read_result res = proto_read(STDIN_FILENO, &msg, &len);
        if (res == READ_ERROR)
            fprintf(stderr, "renderer: bad message on stdin\n");
        SDL_Event ev = {.user = {.type = type, .code = (Sint32)len, .data1 = msg}};
        if (!SDL_PushEvent(&ev))
            free(msg);
        if (res != READ_OK)
            return 0;
    }
}

[[nodiscard]] static bool send_hello(void) {
    const char *name = renderer_backend.name;
    size_t name_len = strlen(name);
    uint8_t msg[4 + UINT8_MAX];
    if (name_len > UINT8_MAX)
        return false;
    msg[0] = MSG_HELLO;
    put_u16(msg + 1, protocol_version);
    msg[3] = (uint8_t)name_len;
    memcpy(msg + 4, name, name_len);
    return proto_write(STDOUT_FILENO, msg, (uint32_t)(4 + name_len));
}

// The first message from Elixir must be the setup: grid size and theme.
[[nodiscard]] static enum read_result read_setup(struct renderer *r) {
    uint8_t *msg;
    uint32_t len;
    enum read_result res = proto_read(STDIN_FILENO, &msg, &len);
    if (res != READ_OK)
        return res;
    struct reader rd = {msg, len};
    uint8_t tag;
    const uint8_t *colors;
    bool ok = len == setup_message_size && rd_u8(&rd, &tag) && tag == MSG_SETUP &&
              rd_u16(&rd, &r->cols) && rd_u16(&rd, &r->rows) && r->cols > 0 && r->rows > 0 &&
              r->cols <= max_grid && r->rows <= max_grid && rd_bytes(&rd, 3 * setup_colors, &colors);
    if (ok) {
        memcpy(r->theme.palette, colors, 3 * palette_size);
        memcpy(r->theme.fg, colors + 3 * palette_size, 3);
        memcpy(r->theme.bg, colors + 3 * (palette_size + 1), 3);
        memcpy(r->theme.cursor, colors + 3 * (palette_size + 2), 3);
    }
    free(msg);
    return ok ? READ_OK : READ_ERROR;
}

static void send_text(const char *text) {
    size_t n = strlen(text);
    if (n == 0 || n > 64)
        return;
    uint8_t msg[1 + 64];
    msg[0] = MSG_TEXT;
    memcpy(msg + 1, text, n);
    (void)proto_write(STDOUT_FILENO, msg, (uint32_t)(1 + n));
}

static void send_key(SDL_Keycode key, SDL_Keymod mod) {
    uint8_t msg[key_message_size];
    msg[0] = MSG_KEY;
    put_u32(msg + 1, key);
    put_u16(msg + 5, mod);
    (void)proto_write(STDOUT_FILENO, msg, sizeof msg);
}

static void send_resize(uint16_t cols, uint16_t rows) {
    uint8_t msg[resize_message_size];
    msg[0] = MSG_RESIZE;
    put_u16(msg + 1, cols);
    put_u16(msg + 3, rows);
    (void)proto_write(STDOUT_FILENO, msg, sizeof msg);
}

// --- Cells ---

// Turn a wire color into RGB. Bold makes the 8 basic colors bright, as
// xterm does by default.
static void resolve(const struct theme *t, uint32_t color, const uint8_t def[3], bool bold,
                    uint8_t out[3]) {
    switch ((enum color_kind)(color >> 24)) {
    case COLOR_INDEXED: {
        uint8_t i = (uint8_t)color;
        if (bold && i < 8)
            i += 8;
        memcpy(out, t->palette[i], 3);
        return;
    }
    case COLOR_RGB:
        out[0] = (uint8_t)(color >> 16);
        out[1] = (uint8_t)(color >> 8);
        out[2] = (uint8_t)color;
        return;
    case COLOR_DEFAULT:
        break;
    }
    memcpy(out, def, 3);
}

// One wire cell (char, attrs, fg, bg) into a ready-to-draw cell: the theme,
// inverse, dim and hidden are applied here so backends only see final colors.
static void decode_cell(const struct theme *t, const uint8_t *wire, struct cell *out) {
    struct reader rd = {wire, wire_cell_size};
    uint8_t ch, attrs;
    uint32_t fg, bg;
    // Can't fail: the caller checked there are wire_cell_size bytes.
    (void)(rd_u8(&rd, &ch) && rd_u8(&rd, &attrs) && rd_u32(&rd, &fg) && rd_u32(&rd, &bg));

    out->ch = (ch >= atlas_first_char && ch <= atlas_last_char) ? ch : ' ';
    out->attrs = attrs;
    resolve(t, fg, t->fg, attrs & ATTR_BOLD, out->fg);
    resolve(t, bg, t->bg, false, out->bg);

    if (attrs & ATTR_INVERSE) {
        uint8_t tmp[3];
        memcpy(tmp, out->fg, 3);
        memcpy(out->fg, out->bg, 3);
        memcpy(out->bg, tmp, 3);
    }
    if (attrs & ATTR_DIM)
        for (int i = 0; i < 3; i++)
            out->fg[i] = (uint8_t)((out->fg[i] + out->bg[i]) / 2);
    if (attrs & ATTR_HIDDEN) {
        out->ch = ' ';
        out->attrs &= (uint8_t)~(ATTR_UNDERLINE | ATTR_STRIKE);
    }
}

static struct cell blank_cell(const struct theme *t) {
    struct cell c = {.ch = ' '};
    memcpy(c.fg, t->fg, 3);
    memcpy(c.bg, t->bg, 3);
    return c;
}

// Replace the cell mirror with a blank one of the given size.
[[nodiscard]] static bool set_grid_size(struct renderer *r, uint16_t cols, uint16_t rows) {
    size_t n;
    if (ckd_mul(&n, (size_t)cols, (size_t)rows))
        return false;
    struct cell *cells = malloc(n * sizeof *cells);
    if (cells == nullptr)
        return false;
    struct cell blank = blank_cell(&r->theme);
    for (size_t i = 0; i < n; i++)
        cells[i] = blank;
    free(r->cells);
    r->cells = cells;
    r->cols = cols;
    r->rows = rows;
    r->cursor_row = r->cursor_row < rows ? r->cursor_row : rows - 1;
    r->cursor_col = r->cursor_col < cols ? r->cursor_col : cols - 1;
    r->dirty = true;
    return true;
}

// How many cells fit in a drawable of w x h pixels.
static void grid_for_pixels(const struct renderer *r, int w, int h, uint16_t *cols, uint16_t *rows) {
    int c = (w - 2 * padding_px) / r->cell_w;
    int n = (h - 2 * padding_px) / r->cell_h;
    *cols = (uint16_t)SDL_clamp(c, 1, max_grid);
    *rows = (uint16_t)SDL_clamp(n, 1, max_grid);
}

[[nodiscard]] static bool apply_rows(struct renderer *r, struct reader *rd) {
    uint16_t cols, rows, crow, ccol, count;
    uint8_t visible;
    if (!rd_u16(rd, &cols) || !rd_u16(rd, &rows) || !rd_u16(rd, &crow) || !rd_u16(rd, &ccol) ||
        !rd_u8(rd, &visible) || !rd_u16(rd, &count))
        return false;
    // Sent for a grid size we no longer have: the window was resized since.
    // A full update at the new size follows, so dropping it is safe.
    if (cols != r->cols || rows != r->rows)
        return true;

    size_t row_bytes = (size_t)cols * wire_cell_size;
    for (uint16_t i = 0; i < count; i++) {
        uint16_t row;
        const uint8_t *wire;
        if (!rd_u16(rd, &row) || row >= rows || !rd_bytes(rd, row_bytes, &wire))
            return false;
        struct cell *dst = r->cells + (size_t)row * cols;
        for (uint16_t c = 0; c < cols; c++)
            decode_cell(&r->theme, wire + (size_t)c * wire_cell_size, &dst[c]);
    }
    r->cursor_row = crow < rows ? crow : rows - 1;
    r->cursor_col = ccol < cols ? ccol : cols - 1;
    r->cursor_visible = visible != 0;
    r->dirty = true;
    return true;
}

[[nodiscard]] static bool apply_message(struct renderer *r, const uint8_t *msg, uint32_t len) {
    struct reader rd = {msg, len};
    uint8_t tag;
    if (!rd_u8(&rd, &tag))
        return false;
    switch ((enum msg_tag)tag) {
    case MSG_ROWS:
        return apply_rows(r, &rd);
    case MSG_HELLO:
    case MSG_SETUP:
    case MSG_TEXT:
    case MSG_KEY:
    case MSG_RESIZE:
        break;
    }
    fprintf(stderr, "renderer: unexpected message tag %u\n", tag);
    return false;
}

// --- Demo mode ---

// xterm's default palette, for --demo only; in port mode the theme comes
// from Elixir.
static void demo_theme(struct theme *t) {
    static const uint8_t ansi[16][3] = {
        {0, 0, 0},       {205, 0, 0},     {0, 205, 0},     {205, 205, 0},
        {0, 0, 238},     {205, 0, 205},   {0, 205, 205},   {229, 229, 229},
        {127, 127, 127}, {255, 0, 0},     {0, 255, 0},     {255, 255, 0},
        {92, 92, 255},   {255, 0, 255},   {0, 255, 255},   {255, 255, 255},
    };
    static const uint8_t levels[6] = {0, 95, 135, 175, 215, 255};
    memcpy(t->palette, ansi, sizeof ansi);
    for (int i = 0; i < 216; i++) {
        t->palette[16 + i][0] = levels[i / 36];
        t->palette[16 + i][1] = levels[(i / 6) % 6];
        t->palette[16 + i][2] = levels[i % 6];
    }
    for (int i = 0; i < 24; i++)
        memset(t->palette[232 + i], 8 + 10 * i, 3);
    memcpy(t->fg, (uint8_t[]){197, 200, 198}, 3);
    memcpy(t->bg, (uint8_t[]){29, 31, 33}, 3);
    memcpy(t->cursor, t->fg, 3);
}

static void demo_text(struct renderer *r, uint16_t row, uint16_t col, const char *text, uint32_t fg,
                      uint32_t bg, uint8_t attrs) {
    for (; *text != '\0' && col < r->cols && row < r->rows; text++, col++) {
        uint8_t wire[wire_cell_size] = {(uint8_t)*text, attrs};
        put_u32(wire + 2, fg);
        put_u32(wire + 6, bg);
        decode_cell(&r->theme, wire, &r->cells[(size_t)row * r->cols + col]);
    }
}

static void fill_demo(struct renderer *r) {
    constexpr uint32_t def = 0;
    constexpr uint32_t idx = (uint32_t)COLOR_INDEXED << 24;
    constexpr uint32_t rgb = (uint32_t)COLOR_RGB << 24;
    demo_text(r, 0, 0, "guiltty renderer --demo", def, def, ATTR_BOLD);
    demo_text(r, 2, 0, "The quick brown fox jumps over the lazy dog.", def, def, 0);
    demo_text(r, 3, 0, "bold", def, def, ATTR_BOLD);
    demo_text(r, 3, 5, "dim", def, def, ATTR_DIM);
    demo_text(r, 3, 9, "underline", def, def, ATTR_UNDERLINE);
    demo_text(r, 3, 19, "inverse", def, def, ATTR_INVERSE);
    demo_text(r, 3, 27, "strike", def, def, ATTR_STRIKE);
    for (uint16_t i = 0; i < 16; i++) {
        demo_text(r, 5, (uint16_t)(i * 3), "  ", def, idx | i, 0);
        demo_text(r, 6, (uint16_t)(i * 3), "ab", idx | i, def, 0);
    }
    for (uint16_t i = 0; i < 72; i++) {
        uint32_t level = (uint32_t)(i * 255 / 71);
        demo_text(r, 8, i, " ", def, rgb | level << 16 | (255 - level) << 8 | 128, 0);
    }
    for (uint16_t i = 0; i < 24; i++)
        demo_text(r, 9, (uint16_t)(i * 3), "   ", def, idx | (232u + i), 0);
    demo_text(r, 11, 0, "Resize the window; close it to quit.", def, def, 0);
    r->cursor_row = 11;
    r->cursor_col = 37;
    r->cursor_visible = true;
    r->dirty = true;
}

// --- Main loop ---

static void draw(struct renderer *r) {
    struct frame frame = {
        .cols = r->cols,
        .rows = r->rows,
        .cells = r->cells,
        .cursor_row = r->cursor_row,
        .cursor_col = r->cursor_col,
        .cursor_visible = r->cursor_visible,
        .origin_x = padding_px,
        .origin_y = padding_px,
    };
    memcpy(frame.cursor_rgb, r->theme.cursor, 3);
    memcpy(frame.clear_rgb, r->theme.bg, 3);
    renderer_backend.draw_frame(r->backend, &frame);
    r->dirty = false;
}

// The window's drawable changed size: work out the grid that fits and, if
// it's different, start over with a blank one and tell Elixir.
[[nodiscard]] static bool on_pixel_size(struct renderer *r, int w, int h) {
    renderer_backend.resize(r->backend, w, h);
    r->dirty = true;
    uint16_t cols, rows;
    grid_for_pixels(r, w, h, &cols, &rows);
    if (cols == r->cols && rows == r->rows)
        return true;
    if (!set_grid_size(r, cols, rows))
        return false;
    if (r->demo)
        fill_demo(r);
    else
        send_resize(cols, rows);
    return true;
}

// Returns false when it's time to quit.
[[nodiscard]] static bool handle_event(struct renderer *r, const SDL_Event *ev, int *status) {
    if (ev->type == r->port_event) {
        uint8_t *msg = ev->user.data1;
        if (msg == nullptr)
            return false; // stdin closed: Elixir is done with us
        bool ok = apply_message(r, msg, (uint32_t)ev->user.code);
        free(msg);
        if (!ok) {
            *status = 2;
            return false;
        }
        return true;
    }
    switch (ev->type) {
    case SDL_EVENT_QUIT:
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        return false;
    case SDL_EVENT_TEXT_INPUT:
        send_text(ev->text.text);
        break;
    case SDL_EVENT_KEY_DOWN:
        send_key(ev->key.key, ev->key.mod);
        break;
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        if (!on_pixel_size(r, ev->window.data1, ev->window.data2)) {
            *status = 1;
            return false;
        }
        break;
    case SDL_EVENT_WINDOW_EXPOSED:
        r->dirty = true;
        break;
    default:
        break;
    }
    return true;
}

int main(int argc, char *argv[]) {
    struct renderer r = {.demo = argc > 1 && strcmp(argv[1], "--demo") == 0, .cursor_visible = true};
    // If Elixir goes away, writes to stdout fail with EPIPE instead of
    // killing us with SIGPIPE.
    signal(SIGPIPE, SIG_IGN);

    if (r.demo) {
        r.cols = default_cols;
        r.rows = default_rows;
        demo_theme(&r.theme);
    } else {
        // If the hello can't be written or stdin ends before the setup,
        // Elixir already closed the port: nothing to do.
        enum read_result res = send_hello() ? read_setup(&r) : READ_EOF;
        if (res == READ_EOF)
            return 0;
        if (res == READ_ERROR) {
            fprintf(stderr, "renderer: handshake failed\n");
            return 2;
        }
    }
    if (!set_grid_size(&r, r.cols, r.rows))
        return 1;

    char *font = font_find_monospace();
    struct atlas atlas;
    if (font == nullptr || !atlas_build(&atlas, font, font_pixel_size)) {
        fprintf(stderr, "renderer: no usable monospace font\n");
        free(font);
        free(r.cells);
        return 1;
    }
    free(font);
    r.cell_w = atlas.cell_w;
    r.cell_h = atlas.cell_h;

    int status = 1;
    int width, height;
    if (ckd_mul(&width, (int)r.cols, atlas.cell_w) || ckd_add(&width, width, 2 * padding_px) ||
        ckd_mul(&height, (int)r.rows, atlas.cell_h) || ckd_add(&height, height, 2 * padding_px))
        goto out_atlas;

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "renderer: SDL_Init: %s\n", SDL_GetError());
        goto out_atlas;
    }
    if (!renderer_backend.configure())
        goto out_sdl;
    r.window = SDL_CreateWindow("guiltty", width, height,
                                renderer_backend.window_flags | SDL_WINDOW_RESIZABLE);
    if (r.window == nullptr) {
        fprintf(stderr, "renderer: SDL_CreateWindow: %s\n", SDL_GetError());
        goto out_sdl;
    }
    SDL_SetWindowMinimumSize(r.window, min_cols * atlas.cell_w + 2 * padding_px,
                             min_rows * atlas.cell_h + 2 * padding_px);
    r.backend = renderer_backend.init(r.window);
    if (r.backend == nullptr || !renderer_backend.upload_atlas(r.backend, &atlas))
        goto out_window;

    if (r.demo) {
        fill_demo(&r);
    } else {
        r.port_event = SDL_RegisterEvents(1);
        SDL_Thread *reader = SDL_CreateThread(port_reader, "port_reader", &r.port_event);
        if (r.port_event == 0 || reader == nullptr)
            goto out_backend;
        // It may be blocked in read() when we quit; nobody needs to join it.
        SDL_DetachThread(reader);
    }

    // The window manager may not have given us the size we asked for (a
    // tiling one never does): start from what we actually got.
    int pw, ph;
    SDL_GetWindowSizeInPixels(r.window, &pw, &ph);
    if (!on_pixel_size(&r, pw, ph))
        goto out_backend;
    SDL_StartTextInput(r.window);

    status = 0;
    bool running = true;
    while (running) {
        SDL_Event ev;
        if (!SDL_WaitEvent(&ev))
            break;
        running = handle_event(&r, &ev, &status);
        // Drain whatever else is queued before drawing once.
        while (running && SDL_PollEvent(&ev))
            running = handle_event(&r, &ev, &status);
        if (running && r.dirty)
            draw(&r);
    }

out_backend:
    renderer_backend.shutdown(r.backend);
out_window:
    SDL_DestroyWindow(r.window);
out_sdl:
    SDL_Quit();
out_atlas:
    atlas_free(&atlas);
    free(r.cells);
    return status;
}

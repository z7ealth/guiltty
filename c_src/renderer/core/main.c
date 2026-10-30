// guiltty's renderer: a separate program that Guiltty.Window runs as an
// Erlang port. It keeps a mirror of the visible cells, draws them through a
// backend, and reports keys, mouse, paste and window resizes. If it
// crashes, only the window goes away.
//
//   guiltty_gl           port mode: talks the protocol on stdin/stdout
//   guiltty_gl --demo    standalone: draws a fixed screen, no port
//
// stdout belongs to the protocol. Diagnostics go to stderr only.

#define _GNU_SOURCE

#include <SDL3/SDL.h>
#include <limits.h>
#include <signal.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "atlas.h"
#include "backend.h"
#include "protocol.h"

constexpr int default_font_size = 18;
constexpr int padding_px = 6;
constexpr uint16_t default_cols = 80;
constexpr uint16_t default_rows = 24;
constexpr uint16_t max_grid = 4096; // cols or rows; far beyond any screen
constexpr int min_cols = 10;
constexpr int min_rows = 3;
constexpr int max_tabs = 64;
constexpr int max_tab_label = 24;

struct theme {
    uint8_t palette[palette_size][3];
    uint8_t fg[3], bg[3], cursor[3];
};

struct tab {
    char title[max_tab_label + 1]; // printable ASCII only (UTF-8 in MVP 5)
    int start, end; // columns it occupies in the tab bar, for clicks
};

struct renderer {
    SDL_Window *window;
    void *backend;
    struct atlas atlas;
    char font_family[256];
    int font_size;
    int cell_w, cell_h;
    // The terminal grid is cols x rows. The cell mirror has one more row on
    // top, the tab bar, so grid row i is cells row i + 1.
    uint16_t cols, rows;
    struct cell *cells; // cols * (rows + 1)
    int dirty_first, dirty_last; // cell rows changed since the last draw
    uint16_t cursor_row, cursor_col; // in grid rows
    bool cursor_visible;
    struct theme theme;
    struct tab tabs[max_tabs];
    int tab_count, active_tab;
    uint8_t halo_rgb[3];
    Uint64 halo_until; // SDL ticks (ms); 0 = no halo
    int mouse_col, mouse_row; // the cell the pointer was last reported in
    uint8_t buttons_held; // bit n = mouse button n (0 left, 1 middle, 2 right)
    uint32_t port_event; // SDL user event type for port messages
    bool frame_owed; // a ROWS message arrived: report the frame that shows it
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

// --- Sending ---

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

// Pasted text can be large: cap it at what a message may carry.
static void send_paste(const char *text) {
    size_t n = strlen(text);
    if (n == 0)
        return;
    if (n > max_message_size - 1)
        n = max_message_size - 1;
    uint8_t *msg = malloc(n + 1);
    if (msg == nullptr)
        return;
    msg[0] = MSG_PASTE;
    memcpy(msg + 1, text, n);
    (void)proto_write(STDOUT_FILENO, msg, (uint32_t)(n + 1));
    free(msg);
}

static void send_mouse(enum mouse_kind kind, uint8_t button, int col, int row) {
    uint8_t msg[mouse_message_size] = {MSG_MOUSE, kind, button};
    put_u16(msg + 3, (uint16_t)col);
    put_u16(msg + 5, (uint16_t)row);
    put_u16(msg + 7, SDL_GetModState());
    (void)proto_write(STDOUT_FILENO, msg, sizeof msg);
}

static void send_resize(uint16_t cols, uint16_t rows) {
    uint8_t msg[resize_message_size];
    msg[0] = MSG_RESIZE;
    put_u16(msg + 1, cols);
    put_u16(msg + 3, rows);
    (void)proto_write(STDOUT_FILENO, msg, sizeof msg);
}

static void send_frame(uint32_t micros) {
    uint8_t msg[5] = {MSG_FRAME};
    put_u32(msg + 1, micros);
    (void)proto_write(STDOUT_FILENO, msg, sizeof msg);
}

static void send_tab_click(int index) {
    uint8_t msg[2] = {MSG_TAB_CLICK, (uint8_t)index};
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

static struct cell *grid_row(struct renderer *r, int row) {
    return r->cells + (size_t)(row + 1) * r->cols;
}

static void mark_row(struct renderer *r, int cells_row) {
    r->dirty_first = cells_row < r->dirty_first ? cells_row : r->dirty_first;
    r->dirty_last = cells_row > r->dirty_last ? cells_row : r->dirty_last;
}

// --- The tab bar ---

static void mix(const uint8_t a[3], const uint8_t b[3], int percent_b, uint8_t out[3]) {
    for (int i = 0; i < 3; i++)
        out[i] = (uint8_t)((a[i] * (100 - percent_b) + b[i] * percent_b) / 100);
}

// Draw the tab bar into cells row 0: " 1 title " per tab, the active one
// in the theme's blue, the rest dimmer on a bar slightly lighter than the
// background.
static void build_tab_bar(struct renderer *r) {
    struct cell bar = {.ch = ' '};
    mix(r->theme.bg, r->theme.fg, 12, bar.bg);
    memcpy(bar.fg, r->theme.palette[7], 3);
    for (int c = 0; c < r->cols; c++)
        r->cells[c] = bar;

    int col = 0;
    for (int i = 0; i < r->tab_count && col < r->cols; i++) {
        char label[max_tab_label + 16];
        snprintf(label, sizeof label, " %d %s ", i + 1, r->tabs[i].title);
        struct cell look = bar;
        if (i == r->active_tab) {
            memcpy(look.fg, r->theme.bg, 3);
            memcpy(look.bg, r->theme.palette[4], 3);
            look.attrs = ATTR_BOLD;
        }
        r->tabs[i].start = col;
        for (const char *p = label; *p != '\0' && col < r->cols; p++, col++) {
            look.ch = (uint8_t)*p;
            r->cells[col] = look;
        }
        r->tabs[i].end = col;
        col++; // a gap between tabs
    }
    mark_row(r, 0);
    r->dirty = true;
}

// Keep printable ASCII, turn each UTF-8 character into one '?' (MVP 5), cut
// to max_tab_label characters.
static void clean_title(const uint8_t *src, size_t len, char *dst) {
    size_t n = 0;
    for (size_t i = 0; i < len && n < (size_t)max_tab_label; i++) {
        uint8_t c = src[i];
        if (c >= 0x20 && c < 0x7f)
            dst[n++] = (char)c;
        else if (c >= 0xC0)
            dst[n++] = '?';
    }
    dst[n] = '\0';
}

[[nodiscard]] static bool apply_tabs(struct renderer *r, struct reader *rd) {
    uint8_t active, count;
    if (!rd_u8(rd, &active) || !rd_u8(rd, &count))
        return false;
    int n = 0;
    for (int i = 0; i < count; i++) {
        uint8_t len;
        const uint8_t *title;
        if (!rd_u8(rd, &len) || !rd_bytes(rd, len, &title))
            return false;
        if (n < max_tabs)
            clean_title(title, len, r->tabs[n++].title);
    }
    r->tab_count = n;
    r->active_tab = active < n ? active : 0;
    build_tab_bar(r);
    return true;
}

// --- Grid size ---

// Replace the cell mirror with a blank one of the given size.
[[nodiscard]] static bool set_grid_size(struct renderer *r, uint16_t cols, uint16_t rows) {
    size_t n;
    if (ckd_mul(&n, (size_t)cols, (size_t)rows + 1))
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
    r->dirty_first = 0;
    r->dirty_last = rows;
    build_tab_bar(r);
    return true;
}

// How many cells fit in a drawable of w x h pixels, below the tab bar.
static void grid_for_pixels(const struct renderer *r, int w, int h, uint16_t *cols, uint16_t *rows) {
    int c = (w - 2 * padding_px) / r->cell_w;
    int n = (h - 2 * padding_px) / r->cell_h - 1;
    *cols = (uint16_t)SDL_clamp(c, 1, max_grid);
    *rows = (uint16_t)SDL_clamp(n, 1, max_grid);
}

// The window's drawable changed size (or the font did): work out the grid
// that fits and, if it's different, start over with a blank one and tell
// Elixir.
[[nodiscard]] static bool on_pixel_size(struct renderer *r, int w, int h);

// --- Messages from Elixir ---

[[nodiscard]] static bool read_theme(struct reader *rd, struct theme *t) {
    const uint8_t *colors;
    if (!rd_bytes(rd, theme_size, &colors))
        return false;
    memcpy(t->palette, colors, 3 * palette_size);
    memcpy(t->fg, colors + 3 * palette_size, 3);
    memcpy(t->bg, colors + 3 * (palette_size + 1), 3);
    memcpy(t->cursor, colors + 3 * (palette_size + 2), 3);
    return true;
}

// u16 size, then the family name: the rest of the message.
[[nodiscard]] static bool read_font(struct reader *rd, struct renderer *r) {
    uint16_t size;
    if (!rd_u16(rd, &size) || size < 6 || size > 96 || rd->left == 0 ||
        rd->left >= sizeof r->font_family)
        return false;
    r->font_size = size;
    memcpy(r->font_family, rd->p, rd->left);
    r->font_family[rd->left] = '\0';
    rd->p += rd->left;
    rd->left = 0;
    return true;
}

// The first message from Elixir must be the setup: grid size, theme, font.
[[nodiscard]] static enum read_result read_setup(struct renderer *r) {
    uint8_t *msg;
    uint32_t len;
    enum read_result res = proto_read(STDIN_FILENO, &msg, &len);
    if (res != READ_OK)
        return res;
    struct reader rd = {msg, len};
    uint8_t tag;
    bool ok = len > setup_fixed_size && rd_u8(&rd, &tag) && tag == MSG_SETUP &&
              rd_u16(&rd, &r->cols) && rd_u16(&rd, &r->rows) && r->cols > 0 && r->rows > 0 &&
              r->cols <= max_grid && r->rows <= max_grid && read_theme(&rd, &r->theme) &&
              read_font(&rd, r);
    free(msg);
    return ok ? READ_OK : READ_ERROR;
}

[[nodiscard]] static bool load_font(struct renderer *r) {
    char *path = font_find(r->font_family);
    struct atlas atlas;
    bool ok = path != nullptr && atlas_build(&atlas, path, r->font_size);
    free(path);
    if (!ok) {
        fprintf(stderr, "renderer: no usable font for \"%s\"\n", r->font_family);
        return false;
    }
    atlas_free(&r->atlas);
    r->atlas = atlas;
    r->cell_w = atlas.cell_w;
    r->cell_h = atlas.cell_h;
    return true;
}

// A new font: new atlas, new cell size, so a new grid for the same window.
[[nodiscard]] static bool change_font(struct renderer *r) {
    if (!load_font(r) || !renderer_backend.upload_atlas(r->backend, &r->atlas))
        return true; // keep the old font; not worth dying over
    SDL_SetWindowMinimumSize(r->window, min_cols * r->cell_w + 2 * padding_px,
                             (min_rows + 1) * r->cell_h + 2 * padding_px);
    int w, h;
    SDL_GetWindowSizeInPixels(r->window, &w, &h);
    // Force a new grid even if cols and rows happen to stay the same.
    r->cols = 0;
    return on_pixel_size(r, w, h);
}

[[nodiscard]] static bool apply_rows(struct renderer *r, struct reader *rd) {
    uint16_t cols, rows, crow, ccol, count;
    uint8_t visible;
    if (!rd_u16(rd, &cols) || !rd_u16(rd, &rows) || !rd_u16(rd, &crow) || !rd_u16(rd, &ccol) ||
        !rd_u8(rd, &visible) || !rd_u16(rd, &count))
        return false;
    // Elixir waits for a frame report before sending the next update.
    r->frame_owed = true;
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
        struct cell *dst = grid_row(r, row);
        for (uint16_t c = 0; c < cols; c++)
            decode_cell(&r->theme, wire + (size_t)c * wire_cell_size, &dst[c]);
        mark_row(r, row + 1);
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
    case MSG_TITLE: {
        // SDL wants a C string; titles are short (Elixir caps them).
        char title[1024];
        size_t n = rd.left < sizeof title - 1 ? rd.left : sizeof title - 1;
        memcpy(title, rd.p, n);
        title[n] = '\0';
        SDL_SetWindowTitle(r->window, title);
        return true;
    }
    case MSG_THEME:
        // Elixir sends every row again after this, decoded with the new theme.
        if (!read_theme(&rd, &r->theme))
            return false;
        build_tab_bar(r);
        return true;
    case MSG_FONT:
        return read_font(&rd, r) && change_font(r);
    case MSG_TABS:
        return apply_tabs(r, &rd);
    case MSG_HALO: {
        uint16_t ms;
        if (!rd_u8(&rd, &r->halo_rgb[0]) || !rd_u8(&rd, &r->halo_rgb[1]) ||
            !rd_u8(&rd, &r->halo_rgb[2]) || !rd_u16(&rd, &ms))
            return false;
        r->halo_until = SDL_GetTicks() + ms;
        r->dirty = true;
        return true;
    }
    case MSG_RAISE:
        SDL_RaiseWindow(r->window);
        return true;
    case MSG_HELLO:
    case MSG_SETUP:
    case MSG_TEXT:
    case MSG_KEY:
    case MSG_RESIZE:
    case MSG_PASTE:
    case MSG_MOUSE:
    case MSG_FRAME:
    case MSG_TAB_CLICK:
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
        decode_cell(&r->theme, wire, &grid_row(r, row)[col]);
    }
}

static void fill_demo(struct renderer *r) {
    constexpr uint32_t def = 0;
    constexpr uint32_t idx = (uint32_t)COLOR_INDEXED << 24;
    constexpr uint32_t rgb = (uint32_t)COLOR_RGB << 24;
    r->tab_count = 2;
    r->active_tab = 0;
    snprintf(r->tabs[0].title, sizeof r->tabs[0].title, "demo");
    snprintf(r->tabs[1].title, sizeof r->tabs[1].title, "another tab");
    build_tab_bar(r);
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

static bool halo_on(const struct renderer *r) {
    return r->halo_until != 0 && SDL_GetTicks() < r->halo_until;
}

static void draw(struct renderer *r) {
    struct frame frame = {
        .cols = r->cols,
        .rows = (uint16_t)(r->rows + 1),
        .cells = r->cells,
        .dirty_first = r->dirty_first,
        .dirty_last = r->dirty_last,
        .cursor_row = (uint16_t)(r->cursor_row + 1),
        .cursor_col = r->cursor_col,
        .cursor_visible = r->cursor_visible,
        .origin_x = padding_px,
        .origin_y = padding_px,
    };
    memcpy(frame.cursor_rgb, r->theme.cursor, 3);
    // The halo is the padding around the grid, lit up for a moment.
    memcpy(frame.clear_rgb, halo_on(r) ? r->halo_rgb : r->theme.bg, 3);

    Uint64 start = SDL_GetTicksNS();
    renderer_backend.draw_frame(r->backend, &frame);
    if (r->frame_owed) {
        send_frame((uint32_t)((SDL_GetTicksNS() - start) / 1000));
        r->frame_owed = false;
    }
    r->dirty = false;
    r->dirty_first = INT_MAX;
    r->dirty_last = -1;
}

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

// The cell under a point in the window: cells row 0 is the tab bar.
static void cell_at(const struct renderer *r, float x, float y, int *col, int *cells_row) {
    *col = SDL_clamp(((int)x - padding_px) / r->cell_w, 0, r->cols - 1);
    *cells_row = SDL_clamp(((int)y - padding_px) / r->cell_h, 0, r->rows);
}

// SDL numbers buttons 1 left, 2 middle, 3 right; the protocol 0, 1, 2.
static bool protocol_button(uint8_t sdl_button, uint8_t *out) {
    if (sdl_button < SDL_BUTTON_LEFT || sdl_button > SDL_BUTTON_RIGHT)
        return false;
    *out = (uint8_t)(sdl_button - SDL_BUTTON_LEFT);
    return true;
}

static void click_tab_bar(const struct renderer *r, int col) {
    for (int i = 0; i < r->tab_count; i++)
        if (col >= r->tabs[i].start && col < r->tabs[i].end) {
            send_tab_click(i);
            return;
        }
}

// Mouse events go to Elixir, which reports them to the program only if it
// asked (and as it asked). Motion is sent only when the pointer enters a
// new cell, so moving within one cell costs nothing. A click on the tab
// bar switches tabs instead.
static void handle_mouse(struct renderer *r, const SDL_Event *ev) {
    int col, cells_row;
    uint8_t button;
    switch (ev->type) {
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
        if (!protocol_button(ev->button.button, &button))
            return;
        cell_at(r, ev->button.x, ev->button.y, &col, &cells_row);
        if (cells_row == 0) {
            if (ev->type == SDL_EVENT_MOUSE_BUTTON_DOWN && button == 0)
                click_tab_bar(r, col);
            return;
        }
        if (ev->type == SDL_EVENT_MOUSE_BUTTON_DOWN)
            r->buttons_held |= (uint8_t)(1u << button);
        else
            r->buttons_held &= (uint8_t)~(1u << button);
        send_mouse(ev->type == SDL_EVENT_MOUSE_BUTTON_DOWN ? MOUSE_PRESS : MOUSE_RELEASE, button,
                   col, cells_row - 1);
        break;
    case SDL_EVENT_MOUSE_MOTION:
        cell_at(r, ev->motion.x, ev->motion.y, &col, &cells_row);
        if (cells_row == 0 || (col == r->mouse_col && cells_row == r->mouse_row))
            return;
        // Report the lowest button held, or 3 for none.
        button = 3;
        for (uint8_t b = 0; b < 3; b++)
            if (r->buttons_held & (1u << b)) {
                button = b;
                break;
            }
        send_mouse(MOUSE_MOTION, button, col, cells_row - 1);
        break;
    case SDL_EVENT_MOUSE_WHEEL:
        if (ev->wheel.y == 0)
            return;
        cell_at(r, ev->wheel.mouse_x, ev->wheel.mouse_y, &col, &cells_row);
        if (cells_row == 0)
            return;
        send_mouse(MOUSE_WHEEL, ev->wheel.y > 0 ? 0 : 1, col, cells_row - 1);
        break;
    default:
        return;
    }
    r->mouse_col = col;
    r->mouse_row = cells_row;
}

// Ctrl+Shift+V and Shift+Insert paste the clipboard instead of being keys.
static bool is_paste(SDL_Keycode key, SDL_Keymod mod) {
    bool shift = mod & SDL_KMOD_SHIFT, ctrl = mod & SDL_KMOD_CTRL;
    return (key == SDLK_V && ctrl && shift) || (key == SDLK_INSERT && shift && !ctrl);
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
        if (!r->demo)
            send_text(ev->text.text);
        break;
    case SDL_EVENT_KEY_DOWN:
        // In --demo, stdout is the terminal you started it from: send nothing.
        if (r->demo)
            break;
        if (is_paste(ev->key.key, ev->key.mod)) {
            char *text = SDL_GetClipboardText();
            if (text != nullptr)
                send_paste(text);
            SDL_free(text);
        } else {
            send_key(ev->key.key, ev->key.mod);
        }
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
    case SDL_EVENT_MOUSE_MOTION:
    case SDL_EVENT_MOUSE_WHEEL:
        if (!r->demo)
            handle_mouse(r, ev);
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

// Sleep until an event arrives, or until the halo should go out.
static bool wait_event(struct renderer *r, SDL_Event *ev) {
    if (r->halo_until == 0)
        return SDL_WaitEvent(ev);
    Uint64 now = SDL_GetTicks();
    if (now >= r->halo_until || !SDL_WaitEventTimeout(ev, (Sint32)(r->halo_until - now))) {
        r->halo_until = 0;
        r->dirty = true;
        return false;
    }
    return true;
}

int main(int argc, char *argv[]) {
    struct renderer r = {
        .demo = argc > 1 && strcmp(argv[1], "--demo") == 0,
        .font_family = "monospace",
        .font_size = default_font_size,
        .cursor_visible = true,
        .dirty_first = INT_MAX,
        .dirty_last = -1,
        .mouse_col = -1,
        .mouse_row = -1,
    };
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
    if (!load_font(&r)) {
        free(r.cells);
        return 1;
    }

    int status = 1;
    int width, height;
    if (ckd_mul(&width, (int)r.cols, r.cell_w) || ckd_add(&width, width, 2 * padding_px) ||
        ckd_mul(&height, (int)r.rows + 1, r.cell_h) || ckd_add(&height, height, 2 * padding_px))
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
    SDL_SetWindowMinimumSize(r.window, min_cols * r.cell_w + 2 * padding_px,
                             (min_rows + 1) * r.cell_h + 2 * padding_px);
    r.backend = renderer_backend.init(r.window);
    if (r.backend == nullptr || !renderer_backend.upload_atlas(r.backend, &r.atlas))
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
        if (wait_event(&r, &ev)) {
            running = handle_event(&r, &ev, &status);
            // Drain whatever else is queued before drawing once.
            while (running && SDL_PollEvent(&ev))
                running = handle_event(&r, &ev, &status);
        }
        if (running && r.dirty)
            draw(&r);
        else if (running && r.frame_owed) {
            // Nothing visible changed (an update for an old size): still
            // tell Elixir, or it would wait forever.
            send_frame(0);
            r.frame_owed = false;
        }
    }

out_backend:
    renderer_backend.shutdown(r.backend);
out_window:
    SDL_DestroyWindow(r.window);
out_sdl:
    SDL_Quit();
out_atlas:
    atlas_free(&r.atlas);
    free(r.cells);
    return status;
}

// guiltty's renderer: a separate program that Guiltty.Window runs as an
// Erlang port. It keeps a mirror of the visible cells, draws them through a
// backend, and reports keys. If it crashes, only the window goes away.
//
//   guiltty_renderer_gl           port mode: talks the protocol on stdin/stdout
//   guiltty_renderer_gl --demo    standalone: draws a fixed screen, no port
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

struct renderer {
    SDL_Window *window;
    void *backend;
    uint16_t cols, rows;
    uint8_t *cells; // cols * rows
    uint16_t cursor_row, cursor_col;
    uint32_t port_event; // SDL user event type for port messages
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

// The first message from Elixir must be the setup: the grid size.
[[nodiscard]] static enum read_result read_setup(uint16_t *cols, uint16_t *rows) {
    uint8_t *msg;
    uint32_t len;
    enum read_result res = proto_read(STDIN_FILENO, &msg, &len);
    if (res != READ_OK)
        return res;
    struct reader r = {msg, len};
    uint8_t tag;
    bool ok = rd_u8(&r, &tag) && tag == MSG_SETUP && rd_u16(&r, cols) && rd_u16(&r, rows) &&
              *cols > 0 && *rows > 0;
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

// Store one row of cells. Anything outside printable ASCII becomes a space,
// so the backend never sees a byte the atlas doesn't have.
static void store_row(struct renderer *r, uint16_t row, const uint8_t *bytes, uint16_t len) {
    uint8_t *dst = r->cells + (size_t)row * r->cols;
    for (uint16_t i = 0; i < r->cols; i++) {
        uint8_t c = i < len ? bytes[i] : ' ';
        dst[i] = (c >= atlas_first_char && c <= atlas_last_char) ? c : ' ';
    }
}

[[nodiscard]] static bool apply_message(struct renderer *r, const uint8_t *msg, uint32_t len) {
    struct reader rd = {msg, len};
    uint8_t tag;
    if (!rd_u8(&rd, &tag))
        return false;
    switch ((enum msg_tag)tag) {
    case MSG_ROWS: {
        uint16_t crow, ccol, count;
        if (!rd_u16(&rd, &crow) || !rd_u16(&rd, &ccol) || !rd_u16(&rd, &count))
            return false;
        for (uint16_t i = 0; i < count; i++) {
            uint16_t row, n;
            const uint8_t *bytes;
            if (!rd_u16(&rd, &row) || !rd_u16(&rd, &n) || !rd_bytes(&rd, n, &bytes) || row >= r->rows)
                return false;
            store_row(r, row, bytes, n);
        }
        r->cursor_row = crow < r->rows ? crow : r->rows - 1;
        r->cursor_col = ccol < r->cols ? ccol : r->cols - 1;
        r->dirty = true;
        return true;
    }
    case MSG_HELLO:
    case MSG_SETUP:
    case MSG_TEXT:
    case MSG_KEY:
        break;
    }
    fprintf(stderr, "renderer: unexpected message tag %u\n", tag);
    return false;
}

static void fill_demo(struct renderer *r) {
    static const char *lines[] = {
        "guiltty renderer --demo",
        "",
        "The quick brown fox jumps over the lazy dog.",
        "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG!",
        "0123456789 ~!@#$%^&*()_+-={}[]|\\:;\"'<>,.?/`",
        "",
        "Close the window to quit.",
    };
    for (uint16_t i = 0; i < sizeof lines / sizeof lines[0] && i < r->rows; i++)
        store_row(r, i, (const uint8_t *)lines[i], (uint16_t)strlen(lines[i]));
    r->cursor_row = 6;
    r->cursor_col = 25;
    r->dirty = true;
}

static void draw(struct renderer *r) {
    struct frame frame = {
        .cols = r->cols,
        .rows = r->rows,
        .cells = r->cells,
        .cursor_row = r->cursor_row,
        .cursor_col = r->cursor_col,
        .origin_x = padding_px,
        .origin_y = padding_px,
    };
    renderer_backend.draw_frame(r->backend, &frame);
    r->dirty = false;
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
        renderer_backend.resize(r->backend, ev->window.data1, ev->window.data2);
        r->dirty = true;
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
    bool demo = argc > 1 && strcmp(argv[1], "--demo") == 0;
    // If Elixir goes away, writes to stdout fail with EPIPE instead of
    // killing us with SIGPIPE.
    signal(SIGPIPE, SIG_IGN);

    struct renderer r = {.cols = default_cols, .rows = default_rows};
    if (!demo) {
        // If the hello can't be written or stdin ends before the setup,
        // Elixir already closed the port: nothing to do.
        enum read_result res = send_hello() ? read_setup(&r.cols, &r.rows) : READ_EOF;
        if (res == READ_EOF)
            return 0;
        if (res == READ_ERROR) {
            fprintf(stderr, "renderer: handshake failed\n");
            return 2;
        }
    }

    size_t ncells;
    if (ckd_mul(&ncells, (size_t)r.cols, (size_t)r.rows) || (r.cells = malloc(ncells)) == nullptr)
        return 1;
    memset(r.cells, ' ', ncells);

    char *font = font_find_monospace();
    struct atlas atlas;
    if (font == nullptr || !atlas_build(&atlas, font, font_pixel_size)) {
        fprintf(stderr, "renderer: no usable monospace font\n");
        free(font);
        free(r.cells);
        return 1;
    }
    free(font);

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
    r.window = SDL_CreateWindow("guiltty", width, height, renderer_backend.window_flags);
    if (r.window == nullptr) {
        fprintf(stderr, "renderer: SDL_CreateWindow: %s\n", SDL_GetError());
        goto out_sdl;
    }
    r.backend = renderer_backend.init(r.window, r.cols, r.rows);
    if (r.backend == nullptr || !renderer_backend.upload_atlas(r.backend, &atlas))
        goto out_window;
    int pw, ph;
    SDL_GetWindowSizeInPixels(r.window, &pw, &ph);
    renderer_backend.resize(r.backend, pw, ph);
    SDL_StartTextInput(r.window);

    if (demo) {
        fill_demo(&r);
    } else {
        r.port_event = SDL_RegisterEvents(1);
        SDL_Thread *reader = SDL_CreateThread(port_reader, "port_reader", &r.port_event);
        if (r.port_event == 0 || reader == nullptr)
            goto out_backend;
        // It may be blocked in read() when we quit; nobody needs to join it.
        SDL_DetachThread(reader);
    }

    status = 0;
    r.dirty = true;
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

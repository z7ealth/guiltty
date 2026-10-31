// libFuzzer target: everything the renderer does with messages from
// Elixir, on random input. An input is a replay file: {:packet, 4} frames,
// SETUP first, exactly what `guiltty_gl-dbg --replay FILE` reads. So a
// crash found here replays in the real renderer.
//
// The renderer's own code runs, included whole (so its static functions
// are reachable): read_setup, then apply_message for each message and
// draw whenever something changed, as main()'s loop does. Only the GPU is
// replaced, by a backend that checks what it's asked to draw instead.
//
// Left out, on purpose:
// - OPEN_URL: it would really open URLs (SDL_OpenURL runs xdg-open).
// - FONT: only parsed; loading a font per input would make each run take
//   milliseconds, and the font is fixed (monospace, 16 px) for all of them.
// - Grids over 512 x 128: legal, but each run would spend its time
//   clearing cells; size checks are the same for any size.

#define main renderer_main
#include "../renderer/core/main.c"
#undef main

#include <sys/mman.h>

// --- A backend that checks instead of drawing ---

static const struct atlas *uploaded;

static bool check_configure(void) {
    return true;
}

static void *check_init(SDL_Window *) {
    return &uploaded;
}

static bool check_upload_atlas(void *, const struct atlas *atlas) {
    uploaded = atlas;
    return true;
}

// What a real backend trusts the core for: every slot inside the atlas,
// the cursor inside the grid, the dirty rows inside the frame.
static void check_draw_frame(void *, const struct frame *f) {
    if (f->cols == 0 || f->rows == 0 || f->cells == nullptr)
        abort();
    for (size_t i = 0; i < (size_t)f->cols * f->rows; i++)
        if (f->cells[i].slot >= uploaded->slot_count)
            abort();
    if (f->cursor_row >= f->rows || f->cursor_col >= f->cols)
        abort();
    if (f->dirty_first <= f->dirty_last && (f->dirty_first < 0 || f->dirty_last >= f->rows))
        abort();
}

static void check_resize(void *, int, int) {}
static void check_shutdown(void *) {}

const struct backend renderer_backend = {
    .name = "fuzz",
    .configure = check_configure,
    .init = check_init,
    .upload_atlas = check_upload_atlas,
    .draw_frame = check_draw_frame,
    .resize = check_resize,
    .shutdown = check_shutdown,
};

// LeakSanitizer, which libFuzzer runs after inputs, can't follow some of
// fontconfig's pointers (it keeps parts of its config as encoded offsets),
// so the config it parses once, at the first fonts_open, looks leaked
// mid-run. It isn't: fonts_close frees it (FcFini), and nothing is
// reported at exit. Only that path is excused, which needs full stacks
// (the fast unwinder stops inside fontconfig): a pattern or font set
// guiltty forgets to free would still be reported.
const char *__asan_default_options(void);
const char *__asan_default_options(void) {
    return "fast_unwind_on_malloc=0";
}

const char *__lsan_default_suppressions(void);
const char *__lsan_default_suppressions(void) {
    return "leak:XML_ParseBuffer\n";
}

// --- The target ---

static struct fonts fonts;
static struct atlas atlas;
static int input_fd;

// At exit, before LeakSanitizer looks (it registered its own check
// earlier, and atexit runs handlers in reverse): fonts_close also frees
// fontconfig's global state (FcFini).
static void close_fonts(void) {
    atlas_free(&atlas);
    fonts_close(&fonts);
}

int LLVMFuzzerInitialize(int *, char ***) {
    setlocale(LC_CTYPE, "C.UTF-8");
    // The renderer writes FRAME and RESIZE reports to stdout; libFuzzer
    // reports on stderr, so stdout can go.
    int null = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (null < 0 || dup2(null, STDOUT_FILENO) < 0)
        abort();
    close(null);
    // The input is put in a memory file that takes stdin's place, so the
    // renderer reads it exactly as it reads the port.
    input_fd = memfd_create("fuzz-input", MFD_CLOEXEC);
    if (input_fd < 0 || !fonts_open(&fonts, "monospace", 16) || !atlas_init(&atlas, &fonts))
        abort();
    atexit(close_fonts);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (ftruncate(input_fd, 0) < 0 || pwrite(input_fd, data, size, 0) != (ssize_t)size ||
        lseek(input_fd, 0, SEEK_SET) < 0 || dup2(input_fd, STDIN_FILENO) < 0)
        abort();

    // As main() starts it, with the shared font and an emptied atlas.
    atlas_reset(&atlas);
    struct renderer r = {
        .backend = &uploaded,
        .fonts = fonts,
        .atlas = atlas,
        .cell_w = fonts.cell_w,
        .cell_h = fonts.cell_h,
        .font_family = "monospace",
        .font_size = 16,
        .scale = 1.0f,
        .padding_option = padding_px,
        .padding = padding_px,
        .opacity = 100,
        .bold_is_bright = true,
        .focused = true,
        .cursor_visible = true,
        .dirty_first = INT_MAX,
        .dirty_last = -1,
        .mouse_col = -1,
        .mouse_row = -1,
    };
    uploaded = &r.atlas;

    if (read_setup(&r) != READ_OK || r.cols > 512 || r.rows > 128 ||
        !set_grid_size(&r, r.cols, r.rows))
        goto done;

    uint8_t *msg;
    uint32_t len;
    while (proto_read(STDIN_FILENO, &msg, &len) == READ_OK) {
        bool ok = true;
        if (msg[0] == MSG_FONT) {
            struct reader rd = {msg + 1, len - 1};
            (void)read_font(&rd, &r);
        } else if (msg[0] != MSG_OPEN_URL) {
            ok = apply_message(&r, msg, len);
        }
        free(msg);
        // A message the renderer refuses ends it, as in main().
        if (!ok)
            break;
        if (r.dirty)
            draw(&r);
    }

done:
    // Carried over to the next run: fallback fonts the run opened (or
    // they'd be opened again, and leak), and the atlas, which atlas_reset
    // empties at the start of each run.
    fonts = r.fonts;
    atlas = r.atlas;
    free(r.cells);
    free(r.glyphs);
    free(r.clusters);
    return 0;
}

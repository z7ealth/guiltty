// guiltty's renderer: a separate program that Guiltty.Window runs as an
// Erlang port. It keeps a mirror of the visible cells, draws them through a
// backend, and reports keys, mouse, paste and window resizes. If it
// crashes, only the window goes away.
//
// Text arrives as codepoints and cluster ids (see protocol.h). Each one is
// looked up in the glyph atlas (atlas.c), which draws it with the right
// font the first time (fonts.c).
//
//   guiltty_gl           port mode: talks the protocol on stdin/stdout
//   guiltty_gl --demo    standalone: draws a fixed screen, no port
//
// stdout belongs to the protocol. Diagnostics go to stderr only.

#define _GNU_SOURCE

#include <SDL3/SDL.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <signal.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wchar.h>

#include "atlas.h"
#include "backend.h"
#include "fonts.h"
#include "protocol.h"

constexpr int default_font_size = 18;
constexpr int padding_px = 6;
constexpr uint16_t default_cols = 80;
constexpr uint16_t default_rows = 24;
constexpr uint16_t max_grid = 4096; // cols or rows; far beyond any screen
constexpr int min_cols = 10;
constexpr int min_rows = 3;
constexpr int max_tabs = 64;
constexpr int max_tab_label = 24; // columns
constexpr size_t max_short_text = 256; // tab titles, status, preedit (bytes, with the NUL)

struct theme {
    uint8_t palette[palette_size][3];
    uint8_t fg[3], bg[3], cursor[3];
};

struct tab {
    char title[max_short_text]; // UTF-8
    int start, end; // columns it occupies in the tab bar, for clicks
};

// The text of a cluster id (protocol.h), as Elixir defined it.
struct cluster {
    uint8_t len;
    char text[max_cluster_bytes];
};

struct renderer {
    SDL_Window *window;
    void *backend;
    struct fonts fonts;
    struct atlas atlas;
    bool atlas_full; // a lookup failed: reset the atlas and look everything up again
    char font_family[256];
    int font_size; // in points: the pixel size is font_size * scale
    float scale; // the display's content scale (2.0 on a HiDPI screen)
    int padding_option; // pixels around the grid at scale 1, from the config
    int padding; // pixels around the grid: padding_option * scale
    uint8_t opacity; // the default background's, in percent
    bool transparent; // the window was created able to show what's behind it
    bool bold_is_bright;
    // The tab bar is drawn at the bottom. It's still row 0 of the cell
    // mirror; only where it's drawn (and where clicks land) changes.
    bool tab_bar_bottom;
    int cell_w, cell_h;
    // The terminal grid is cols x rows. The cell mirror has one more row on
    // top, the tab bar, so grid row i is cells row i + 1.
    uint16_t cols, rows;
    struct cell *cells; // cols * (rows + 1)
    uint32_t *glyphs; // what each cell shows (codepoint or cluster id), to look it up again
    struct cluster *clusters; // indexed by id - first_cluster
    uint32_t cluster_cap;
    int dirty_first, dirty_last; // cell rows changed since the last draw
    uint16_t cursor_row, cursor_col; // in grid rows
    bool cursor_visible;
    uint8_t cursor_style; // enum cursor_shape, | cursor_blinks
    bool blink_off; // in the dark half of a blink
    Uint64 blink_next; // SDL ticks of the next blink change; 0 = not blinking
    bool focused;
    struct theme theme;
    struct tab tabs[max_tabs];
    int tab_count, active_tab;
    char status[max_short_text]; // shown at the right of the tab bar
    bool status_warning; // draw it as a warning (a broken config)
    char preedit[max_short_text]; // text being composed in an input method
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

static void send_mouse(enum mouse_kind kind, uint8_t button, int col, int row, uint8_t clicks) {
    uint8_t msg[mouse_message_size] = {MSG_MOUSE, kind, button};
    put_u16(msg + 3, (uint16_t)col);
    put_u16(msg + 5, (uint16_t)row);
    put_u16(msg + 7, SDL_GetModState());
    msg[9] = clicks;
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

// --- Glyphs ---

// The UTF-8 text a glyph stands for.
static size_t glyph_text(const struct renderer *r, uint32_t glyph, char out[max_cluster_bytes]) {
    if (glyph < first_cluster)
        return utf8_put(glyph <= 0x10FFFF ? glyph : 0xFFFD, out);
    uint32_t i = glyph - first_cluster;
    if (i < r->cluster_cap && r->clusters[i].len > 0) {
        memcpy(out, r->clusters[i].text, r->clusters[i].len);
        return r->clusters[i].len;
    }
    return utf8_put(0xFFFD, out); // never defined: shouldn't happen
}

[[nodiscard]] static bool define_cluster(struct renderer *r, uint32_t id, const uint8_t *text, uint8_t len) {
    if (id < first_cluster || id - first_cluster >= max_clusters || len == 0 || len > max_cluster_bytes)
        return false;
    uint32_t i = id - first_cluster;
    if (i >= r->cluster_cap) {
        uint32_t cap = r->cluster_cap == 0 ? 256 : r->cluster_cap;
        while (cap <= i)
            cap *= 2;
        struct cluster *grown = realloc(r->clusters, cap * sizeof *grown);
        if (grown == nullptr)
            return false;
        memset(grown + r->cluster_cap, 0, (cap - r->cluster_cap) * sizeof *grown);
        r->clusters = grown;
        r->cluster_cap = cap;
    }
    r->clusters[i].len = len;
    memcpy(r->clusters[i].text, text, len);
    return true;
}

// Point cell idx at its glyph's atlas slot. The right half of a wide
// character uses the slot after its left half's.
static void find_slot(struct renderer *r, size_t idx) {
    struct cell *c = &r->cells[idx];
    uint32_t glyph = r->glyphs[idx];
    c->slot = 0;
    c->attrs &= (uint16_t)~CELL_COLOR_GLYPH;
    if (c->attrs & ATTR_SPACER) {
        const struct cell *left = idx % r->cols > 0 ? &r->cells[idx - 1] : nullptr;
        if (left != nullptr && (left->attrs & ATTR_WIDE) && left->slot != 0) {
            c->slot = (uint16_t)(left->slot + 1);
            c->attrs |= left->attrs & CELL_COLOR_GLYPH;
        }
        return;
    }
    if (glyph == 0 || glyph == ' ' || (c->attrs & ATTR_HIDDEN) || r->fonts.count == 0)
        return;
    char text[max_cluster_bytes];
    size_t len = glyph_text(r, glyph, text);
    bool color;
    if (!atlas_lookup(&r->atlas, &r->fonts, text, len, (c->attrs & ATTR_WIDE) ? 2 : 1, &c->slot, &color)) {
        r->atlas_full = true;
        return;
    }
    if (color)
        c->attrs |= CELL_COLOR_GLYPH;
}

// Nerd Font icons (powerline prompts are full of them) live in the
// Private Use Area. wcwidth says they're one column, but most are drawn
// wider. Like Ghostty, an icon followed by a plain space gets both cells;
// otherwise it's shrunk into one (fonts.c).
static void widen_icons(struct renderer *r, size_t first) {
    for (size_t c = 0; c + 1 < r->cols; c++) {
        size_t i = first + c;
        struct cell *icon = &r->cells[i], *next = &r->cells[i + 1];
        constexpr uint16_t paired = ATTR_WIDE | ATTR_SPACER | ATTR_HIDDEN;
        if (!private_use(r->glyphs[i]) || r->glyphs[i + 1] != ' ' || (icon->attrs & paired) ||
            (next->attrs & paired))
            continue;
        char text[max_cluster_bytes];
        size_t len = glyph_text(r, r->glyphs[i], text);
        uint16_t slot;
        bool color;
        if (!atlas_lookup(&r->atlas, &r->fonts, text, len, 2, &slot, &color)) {
            r->atlas_full = true;
            return;
        }
        // The space shows the icon's right half, in the icon's color.
        icon->slot = slot;
        next->slot = (uint16_t)(slot + 1);
        memcpy(next->fg, icon->fg, 3);
        uint16_t flag = color ? CELL_COLOR_GLYPH : 0;
        icon->attrs = (uint16_t)((icon->attrs & ~CELL_COLOR_GLYPH) | flag);
        next->attrs = (uint16_t)((next->attrs & ~CELL_COLOR_GLYPH) | flag);
        c++;
    }
}

// Every cell of one row to its atlas slot.
static void row_slots(struct renderer *r, size_t first) {
    for (size_t c = 0; c < r->cols; c++)
        find_slot(r, first + c);
    widen_icons(r, first);
}

// The atlas filled up: start it over with just what's on screen now.
static void refill_atlas(struct renderer *r) {
    if (!r->atlas_full)
        return;
    atlas_reset(&r->atlas);
    r->atlas_full = false;
    for (size_t row = 0; row <= r->rows; row++)
        row_slots(r, row * r->cols);
    // Still full: more different glyphs on screen than slots. The rest
    // stay blank until the next refill.
    r->atlas_full = false;
    r->dirty_first = 0;
    r->dirty_last = r->rows;
    r->dirty = true;
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

static void mix(const uint8_t a[3], const uint8_t b[3], int percent_b, uint8_t out[3]) {
    for (int i = 0; i < 3; i++)
        out[i] = (uint8_t)((a[i] * (100 - percent_b) + b[i] * percent_b) / 100);
}

// One wire cell (glyph, attrs, fg, bg) into cell idx of the mirror: the
// theme, inverse, dim, hidden and search marks are applied here so
// backends only see final colors.
static void decode_cell(struct renderer *r, const uint8_t *wire, size_t idx) {
    const struct theme *t = &r->theme;
    struct reader rd = {wire, wire_cell_size};
    uint32_t glyph, fg, bg;
    uint16_t attrs;
    // Can't fail: the caller checked there are wire_cell_size bytes.
    (void)(rd_u32(&rd, &glyph) && rd_u16(&rd, &attrs) && rd_u32(&rd, &fg) && rd_u32(&rd, &bg));

    struct cell *out = &r->cells[idx];
    *out = (struct cell){.attrs = attrs};
    r->glyphs[idx] = glyph;
    resolve(t, fg, t->fg, (attrs & ATTR_BOLD) && r->bold_is_bright, out->fg);
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
    // Search matches: yellow, the current one brighter.
    if (attrs & ATTR_CURRENT_MATCH) {
        memcpy(out->bg, t->palette[11], 3);
        memcpy(out->fg, t->bg, 3);
    } else if (attrs & ATTR_MATCH) {
        mix(t->bg, t->palette[3], 55, out->bg);
        memcpy(out->fg, t->fg, 3);
    }
    if (attrs & ATTR_HIDDEN)
        out->attrs &= (uint16_t)~(ATTR_UNDERLINE | ATTR_STRIKE);
    constexpr uint16_t recolored = ATTR_INVERSE | ATTR_MATCH | ATTR_CURRENT_MATCH;
    if ((bg >> 24) == COLOR_DEFAULT && !(attrs & recolored))
        out->attrs |= CELL_DEFAULT_BG;
    find_slot(r, idx);
}

static struct cell blank_cell(const struct theme *t) {
    struct cell c = {.attrs = CELL_DEFAULT_BG};
    memcpy(c.fg, t->fg, 3);
    memcpy(c.bg, t->bg, 3);
    return c;
}

static size_t grid_index(const struct renderer *r, int row, int col) {
    return (size_t)(row + 1) * r->cols + (size_t)col;
}

static void mark_row(struct renderer *r, int cells_row) {
    r->dirty_first = cells_row < r->dirty_first ? cells_row : r->dirty_first;
    r->dirty_last = cells_row > r->dirty_last ? cells_row : r->dirty_last;
}

// --- The tab bar ---

// Puts UTF-8 text in cells row 0 from col, styled like `look`, stopping
// before `limit`. Returns the column after it. Widths come from wcwidth(3),
// like a program would measure them.
static int bar_text(struct renderer *r, int col, const char *text, struct cell look, int limit) {
    size_t len = strlen(text);
    for (size_t i = 0; i < len && col < limit;) {
        uint32_t cp = utf8_next((const uint8_t *)text, len, &i);
        int w = wcwidth((wchar_t)cp);
        if (w <= 0)
            continue; // combining marks and controls: skip in the tab bar
        if (col + w > limit)
            break;
        r->cells[col] = look;
        r->glyphs[col] = cp;
        if (w == 2) {
            r->cells[col].attrs |= ATTR_WIDE;
            r->cells[col + 1] = look;
            r->cells[col + 1].attrs |= ATTR_SPACER;
            r->glyphs[col + 1] = 0;
        }
        find_slot(r, (size_t)col);
        if (w == 2)
            find_slot(r, (size_t)col + 1);
        col += w;
    }
    return col;
}

static int text_columns(const char *text) {
    size_t len = strlen(text);
    int cols = 0;
    for (size_t i = 0; i < len;) {
        int w = wcwidth((wchar_t)utf8_next((const uint8_t *)text, len, &i));
        cols += w > 0 ? w : 0;
    }
    return cols;
}

// Like bar_text, but if the text doesn't fit before `limit`, it ends in "…".
static int bar_text_cut(struct renderer *r, int col, const char *text, struct cell look, int limit) {
    if (col + text_columns(text) <= limit)
        return bar_text(r, col, text, look, limit);
    int end = bar_text(r, col, text, look, limit - 1);
    return bar_text(r, end, "…", look, limit);
}

// Draw the tab bar into cells row 0. Flat tabs, " 1 title ", with thin
// separators between them, on a bar a little lighter than the background.
// The active tab is lighter still, in the full text color, with an accent
// line along its bottom in the theme's blue; the others are muted. The
// status (search, scrollback) sits at the right end.
static void build_tab_bar(struct renderer *r) {
    struct cell bar = {};
    mix(r->theme.bg, r->theme.fg, 8, bar.bg);
    mix(r->theme.bg, r->theme.fg, 55, bar.fg);
    for (int c = 0; c < r->cols; c++) {
        r->cells[c] = bar;
        r->glyphs[c] = ' ';
    }

    int limit = r->cols;
    int status_w = text_columns(r->status);
    if (status_w > 0) {
        struct cell look = bar;
        if (r->status_warning) {
            // A warning (the config didn't load) in the theme's red.
            memcpy(look.bg, r->theme.palette[1], 3);
            memcpy(look.fg, r->theme.bg, 3);
            look.attrs = ATTR_BOLD;
        } else {
            mix(r->theme.bg, r->theme.fg, 30, look.bg);
            memcpy(look.fg, r->theme.fg, 3);
        }
        // At most two thirds of the bar: the tabs stay visible.
        int room = r->cols * 2 / 3 - 2;
        if (status_w > room)
            status_w = room > 1 ? room : 1;
        int start = r->cols - status_w - 2;
        if (start < 0)
            start = 0;
        int end = bar_text(r, start, " ", look, r->cols);
        end = bar_text_cut(r, end, r->status, look, end + status_w);
        bar_text(r, end, " ", look, r->cols);
        limit = start - 1;
    }

    struct cell separator = bar;
    mix(r->theme.bg, r->theme.fg, 25, separator.fg);
    int col = 0;
    for (int i = 0; i < r->tab_count && col < limit; i++) {
        struct cell look = bar;
        if (i == r->active_tab) {
            mix(r->theme.bg, r->theme.fg, 16, look.bg);
            memcpy(look.fg, r->theme.fg, 3);
            look.attrs = ATTR_BOLD | CELL_ACCENT;
        }
        char number[16];
        snprintf(number, sizeof number, " %d ", i + 1);
        r->tabs[i].start = col;
        col = bar_text(r, col, number, look, limit);
        int title_end = col + max_tab_label < limit ? col + max_tab_label : limit;
        col = bar_text_cut(r, col, r->tabs[i].title, look, title_end);
        col = bar_text(r, col, " ", look, limit);
        r->tabs[i].end = col;
        col = bar_text(r, col, "│", separator, limit);
    }
    mark_row(r, 0);
    r->dirty = true;
}

// Keep a title's text, minus control characters.
static void clean_text(const uint8_t *src, size_t len, char *dst, size_t size) {
    size_t n = 0;
    for (size_t i = 0; i < len && n + 1 < size; i++)
        if (src[i] >= 0x20 && src[i] != 0x7f)
            dst[n++] = (char)src[i];
    // Don't end in the middle of a UTF-8 character.
    while (n > 0 && ((uint8_t)dst[n - 1] & 0xC0) == 0x80 && n + 1 >= size)
        n--;
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
            clean_text(title, len, r->tabs[n++].title, sizeof r->tabs[0].title);
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
    uint32_t *glyphs = calloc(n, sizeof *glyphs);
    if (cells == nullptr || glyphs == nullptr) {
        free(cells);
        free(glyphs);
        return false;
    }
    struct cell blank = blank_cell(&r->theme);
    for (size_t i = 0; i < n; i++)
        cells[i] = blank;
    free(r->cells);
    free(r->glyphs);
    r->cells = cells;
    r->glyphs = glyphs;
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
    int c = (w - 2 * r->padding) / r->cell_w;
    int n = (h - 2 * r->padding) / r->cell_h - 1;
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

// u16 padding, u8 opacity percent, u8 flags.
[[nodiscard]] static bool read_options(struct reader *rd, struct renderer *r) {
    uint16_t padding;
    uint8_t opacity, flags;
    if (!rd_u16(rd, &padding) || !rd_u8(rd, &opacity) || !rd_u8(rd, &flags) || padding > 100 ||
        opacity < 10 || opacity > 100)
        return false;
    r->padding_option = padding;
    r->opacity = opacity;
    r->bold_is_bright = flags & OPTION_BOLD_IS_BRIGHT;
    r->tab_bar_bottom = flags & OPTION_TAB_BAR_BOTTOM;
    return true;
}

// The first message from Elixir must be the setup: grid size, theme,
// options, font.
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
              read_options(&rd, r) && read_font(&rd, r);
    free(msg);
    return ok ? READ_OK : READ_ERROR;
}

// Opens the font at the current size and scale, with a fresh atlas for
// it. On failure the old font and atlas stay.
[[nodiscard]] static bool load_font(struct renderer *r) {
    int px = (int)lroundf((float)r->font_size * r->scale);
    struct fonts fonts;
    struct atlas atlas;
    if (!fonts_open(&fonts, r->font_family, px))
        return false;
    if (!atlas_init(&atlas, &fonts)) {
        fonts_close(&fonts);
        return false;
    }
    if (r->fonts.count > 0) {
        atlas_free(&r->atlas);
        fonts_close(&r->fonts);
    }
    r->fonts = fonts;
    r->atlas = atlas;
    r->cell_w = fonts.cell_w;
    r->cell_h = fonts.cell_h;
    r->padding = (int)lroundf((float)r->padding_option * r->scale);
    return true;
}

// The window's own icon, for taskbars that ask the window rather than the
// .desktop file (Xfce's does). SDL3 reads only BMP, so `make icons` keeps a
// BMP copy of the logo next to this binary, in priv/. No icon, no problem.
static void set_window_icon(SDL_Window *window) {
    const char *dir = SDL_GetBasePath();
    char path[4096];
    if (dir == nullptr || snprintf(path, sizeof path, "%sguiltty.bmp", dir) >= (int)sizeof path)
        return;
    SDL_Surface *icon = SDL_LoadBMP(path);
    if (icon == nullptr)
        return;
    SDL_SetWindowIcon(window, icon);
    SDL_DestroySurface(icon);
}

// The smallest window that still fits min_cols x min_rows, in window
// coordinates (SDL sizes windows in those, not pixels).
static void set_minimum_size(struct renderer *r) {
    float density = SDL_GetWindowPixelDensity(r->window);
    if (density <= 0)
        density = 1;
    int w = min_cols * r->cell_w + 2 * r->padding, h = (min_rows + 1) * r->cell_h + 2 * r->padding;
    SDL_SetWindowMinimumSize(r->window, (int)((float)w / density), (int)((float)h / density));
}

// A new font (or zoom, or display scale): new atlas, new cell size, so a
// new grid for the same window.
[[nodiscard]] static bool change_font(struct renderer *r) {
    if (!load_font(r) || !renderer_backend.upload_atlas(r->backend, &r->atlas))
        return true; // keep the old font; not worth dying over
    atlas_mark_clean(&r->atlas);
    set_minimum_size(r);
    int w, h;
    SDL_GetWindowSizeInPixels(r->window, &w, &h);
    // Force a new grid even if cols and rows happen to stay the same.
    r->cols = 0;
    return on_pixel_size(r, w, h);
}

constexpr Uint64 blink_ms = 600;

// The cursor shows solid right after it moves or you type, then blinks
// (if its style says so, and only while the window has the focus).
static void restart_blink(struct renderer *r) {
    r->blink_off = false;
    bool blinks = (r->cursor_style & cursor_blinks) && r->focused;
    r->blink_next = blinks ? SDL_GetTicks() + blink_ms : 0;
    r->dirty = true;
}

// Where the input method should show its candidates: at the cursor, in
// window coordinates.
static void update_text_area(struct renderer *r) {
    if (r->window == nullptr || r->demo)
        return;
    float density = SDL_GetWindowPixelDensity(r->window);
    if (density <= 0)
        density = 1;
    SDL_Rect area = {
        .x = (int)((float)(r->padding + r->cursor_col * r->cell_w) / density),
        .y = (int)((float)(r->padding + (r->cursor_row + (r->tab_bar_bottom ? 0 : 1)) * r->cell_h) /
                   density),
        .w = (int)((float)r->cell_w / density),
        .h = (int)((float)r->cell_h / density),
    };
    SDL_SetTextInputArea(r->window, &area, 0);
}

[[nodiscard]] static bool apply_rows(struct renderer *r, struct reader *rd) {
    uint16_t cols, rows, crow, ccol, nclusters, count;
    uint8_t visible, style;
    if (!rd_u16(rd, &cols) || !rd_u16(rd, &rows) || !rd_u16(rd, &crow) || !rd_u16(rd, &ccol) ||
        !rd_u8(rd, &visible) || !rd_u8(rd, &style) || !rd_u16(rd, &nclusters))
        return false;
    // Elixir waits for a frame report before sending the next update.
    r->frame_owed = true;
    // Cluster definitions apply whatever the size: Elixir won't send them again.
    for (uint16_t i = 0; i < nclusters; i++) {
        uint32_t id;
        uint8_t len;
        const uint8_t *text;
        if (!rd_u32(rd, &id) || !rd_u8(rd, &len) || !rd_bytes(rd, len, &text) ||
            !define_cluster(r, id, text, len))
            return false;
    }
    if (!rd_u16(rd, &count))
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
        size_t first = grid_index(r, row, 0);
        for (uint16_t c = 0; c < cols; c++)
            decode_cell(r, wire + (size_t)c * wire_cell_size, first + c);
        widen_icons(r, first);
        mark_row(r, row + 1);
    }
    bool moved = r->cursor_row != crow || r->cursor_col != ccol || r->cursor_style != style;
    r->cursor_style = style;
    r->cursor_row = crow < rows ? crow : rows - 1;
    r->cursor_col = ccol < cols ? ccol : cols - 1;
    r->cursor_visible = visible != 0;
    if (moved) {
        update_text_area(r);
        restart_blink(r);
    }
    r->dirty = true;
    return true;
}

// Text to put on the clipboard: SDL wants a C string.
static void set_clipboard(struct reader *rd) {
    uint8_t target;
    if (!rd_u8(rd, &target))
        return;
    char *text = malloc(rd->left + 1);
    if (text == nullptr)
        return;
    memcpy(text, rd->p, rd->left);
    text[rd->left] = '\0';
    if (target == 1)
        SDL_SetPrimarySelectionText(text);
    else
        SDL_SetClipboardText(text);
    free(text);
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
    case MSG_STATUS: {
        uint8_t style;
        if (!rd_u8(&rd, &style))
            return false;
        r->status_warning = style == 1;
        clean_text(rd.p, rd.left, r->status, sizeof r->status);
        build_tab_bar(r);
        return true;
    }
    case MSG_CLIPBOARD:
        set_clipboard(&rd);
        return true;
    case MSG_OPTIONS: {
        int padding = r->padding_option;
        if (!read_options(&rd, r))
            return false;
        update_text_area(r); // the tab bar may have moved
        if (r->opacity < 100 && !r->transparent)
            fprintf(stderr, "renderer: opacity applies to windows opened from now on\n");
        // Elixir sends every row again (bold may have changed colors). New
        // padding means a new grid for the same window.
        if (padding != r->padding_option) {
            r->padding = (int)lroundf((float)r->padding_option * r->scale);
            set_minimum_size(r);
            int w, h;
            SDL_GetWindowSizeInPixels(r->window, &w, &h);
            r->cols = 0;
            return on_pixel_size(r, w, h);
        }
        r->dirty = true;
        return true;
    }
    case MSG_OPEN_URL: {
        char *url = malloc(rd.left + 1);
        if (url == nullptr)
            return true;
        memcpy(url, rd.p, rd.left);
        url[rd.left] = '\0';
        if (!SDL_OpenURL(url))
            fprintf(stderr, "renderer: can't open %s: %s\n", url, SDL_GetError());
        free(url);
        return true;
    }
    case MSG_PASTE_PRIMARY: {
        char *text = SDL_GetPrimarySelectionText();
        if (text != nullptr)
            send_paste(text);
        SDL_free(text);
        return true;
    }
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

static void demo_cell(struct renderer *r, uint16_t row, uint16_t col, uint32_t glyph, uint32_t fg,
                      uint32_t bg, uint16_t attrs) {
    uint8_t wire[wire_cell_size];
    put_u32(wire, glyph);
    put_u16(wire + 4, attrs);
    put_u32(wire + 6, fg);
    put_u32(wire + 10, bg);
    decode_cell(r, wire, grid_index(r, row, col));
}

// UTF-8, one codepoint per cell (two when wcwidth says it's wide).
static void demo_text(struct renderer *r, uint16_t row, uint16_t col, const char *text, uint32_t fg,
                      uint32_t bg, uint16_t attrs) {
    size_t len = strlen(text);
    for (size_t i = 0; i < len && row < r->rows;) {
        uint32_t cp = utf8_next((const uint8_t *)text, len, &i);
        int w = wcwidth((wchar_t)cp) == 2 ? 2 : 1;
        if (col + w > r->cols)
            return;
        demo_cell(r, row, col, cp, fg, bg, w == 2 ? attrs | ATTR_WIDE : attrs);
        if (w == 2)
            demo_cell(r, row, col + 1, 0, fg, bg, attrs | ATTR_SPACER);
        col = (uint16_t)(col + w);
    }
}

static void fill_demo(struct renderer *r) {
    constexpr uint32_t def = 0;
    constexpr uint32_t idx = (uint32_t)COLOR_INDEXED << 24;
    constexpr uint32_t rgb = (uint32_t)COLOR_RGB << 24;
    r->tab_count = 2;
    r->active_tab = 0;
    snprintf(r->tabs[0].title, sizeof r->tabs[0].title, "🔒 demo");
    snprintf(r->tabs[1].title, sizeof r->tabs[1].title, "日本語 tab");
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
    demo_text(r, 11, 0, "héllo wörld · 日本語のテキスト · 😀 ⚡ ❤ ★ │ ┌─┐ ▒", def, def, 0);
    // Clusters, defined the way Elixir would: e + combining acute, a flag,
    // a thumbs up with a skin tone.
    static const char *clusters[] = {"e\xcc\x81", "\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5",
                                     "\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd"};
    for (uint32_t i = 0; i < 3; i++)
        (void)define_cluster(r, first_cluster + i, (const uint8_t *)clusters[i], (uint8_t)strlen(clusters[i]));
    demo_text(r, 12, 0, "clusters:", def, def, 0);
    demo_cell(r, 12, 10, first_cluster, def, def, 0);
    demo_cell(r, 12, 12, first_cluster + 1, def, def, ATTR_WIDE);
    demo_cell(r, 12, 13, 0, def, def, ATTR_SPACER);
    demo_cell(r, 12, 15, first_cluster + 2, def, def, ATTR_WIDE);
    demo_cell(r, 12, 16, 0, def, def, ATTR_SPACER);
    demo_text(r, 13, 0, "search match", def, def, ATTR_MATCH);
    demo_text(r, 13, 13, "current match", def, def, ATTR_MATCH | ATTR_CURRENT_MATCH);
    demo_text(r, 15, 0, "Resize the window; close it to quit.", def, def, 0);
    snprintf(r->status, sizeof r->status, "find: demo");
    build_tab_bar(r);
    refill_atlas(r);
    r->cursor_row = 15;
    r->cursor_col = 37;
    r->cursor_visible = true;
    r->dirty = true;
}

// --- Main loop ---

static bool halo_on(const struct renderer *r) {
    return r->halo_until != 0 && SDL_GetTicks() < r->halo_until;
}

// Text being composed in an input method (a dead key's accent, Japanese
// before it's converted) shows at the cursor, underlined, until it's done.
// It's drawn over the cells for one frame; the row is put back after.
static int overlay_preedit(struct renderer *r, struct cell *saved, uint32_t *saved_glyphs) {
    if (r->preedit[0] == '\0' || !r->cursor_visible)
        return -1;
    int row = r->cursor_row + 1;
    size_t first = (size_t)row * r->cols;
    memcpy(saved, r->cells + first, r->cols * sizeof *saved);
    memcpy(saved_glyphs, r->glyphs + first, r->cols * sizeof *saved_glyphs);
    struct cell look = r->cells[first + r->cursor_col];
    look.attrs = ATTR_UNDERLINE;
    // bar_text writes row 0; shift the row pointers so it writes this one.
    struct cell *cells = r->cells;
    uint32_t *glyphs = r->glyphs;
    r->cells += first;
    r->glyphs += first;
    bar_text(r, r->cursor_col, r->preedit, look, r->cols);
    r->cells = cells;
    r->glyphs = glyphs;
    mark_row(r, row);
    return row;
}

static void draw(struct renderer *r) {
    struct cell saved[max_grid];
    uint32_t saved_glyphs[max_grid];
    int preedit_row = overlay_preedit(r, saved, saved_glyphs);
    refill_atlas(r);
    if (!renderer_backend.upload_atlas(r->backend, &r->atlas))
        fprintf(stderr, "renderer: atlas upload failed\n");
    atlas_mark_clean(&r->atlas);

    size_t cursor = grid_index(r, r->cursor_row, r->cursor_col);
    struct frame frame = {
        .cols = r->cols,
        .rows = (uint16_t)(r->rows + 1),
        .cells = r->cells,
        .dirty_first = r->dirty_first,
        .dirty_last = r->dirty_last,
        .cursor_row = (uint16_t)(r->cursor_row + 1),
        .cursor_col = r->cursor_col,
        .cursor_visible = r->cursor_visible && preedit_row < 0 && !r->blink_off,
        // Without the focus, a hollow block: typing wouldn't go here.
        .cursor_shape = r->focused ? (uint8_t)(r->cursor_style & 0x3) : CURSOR_HOLLOW,
        .opacity = r->transparent ? (float)r->opacity / 100.0f : 1.0f,
        .first_row_last = r->tab_bar_bottom,
        .cursor_wide = (r->cells[cursor].attrs & ATTR_WIDE) != 0 && r->cursor_col + 1 < r->cols,
        .origin_x = r->padding,
        .origin_y = r->padding,
    };
    memcpy(frame.cursor_rgb, r->theme.cursor, 3);
    memcpy(frame.accent_rgb, r->theme.palette[4], 3);
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

    if (preedit_row >= 0) {
        size_t first = (size_t)preedit_row * r->cols;
        memcpy(r->cells + first, saved, r->cols * sizeof *saved);
        memcpy(r->glyphs + first, saved_glyphs, r->cols * sizeof *saved_glyphs);
        mark_row(r, preedit_row);
    }
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

// The cell under a point in the window: cells row 0 is the tab bar. SDL
// gives mouse positions in window coordinates; on a HiDPI screen a window
// coordinate is several pixels.
static void cell_at(const struct renderer *r, float x, float y, int *col, int *cells_row) {
    float density = SDL_GetWindowPixelDensity(r->window);
    if (density <= 0)
        density = 1;
    int px = (int)(x * density), py = (int)(y * density);
    *col = SDL_clamp((px - r->padding) / r->cell_w, 0, r->cols - 1);
    int shown = SDL_clamp((py - r->padding) / r->cell_h, 0, r->rows);
    // The row on screen to the row in the mirror: with the bar at the
    // bottom, the last row on screen is mirror row 0.
    *cells_row = !r->tab_bar_bottom ? shown : shown == r->rows ? 0 : shown + 1;
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

// Mouse events go to Elixir, which reports them to the program if it
// asked, or uses them to select and scroll. Motion is sent only when the
// pointer enters a new cell, so moving within one cell costs nothing. A
// click on the tab bar switches tabs instead; a drag that started below
// it and wanders up there counts as the top row (so a selection can reach
// it).
static void handle_mouse(struct renderer *r, const SDL_Event *ev) {
    int col, cells_row;
    uint8_t button;
    switch (ev->type) {
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP: {
        if (!protocol_button(ev->button.button, &button))
            return;
        cell_at(r, ev->button.x, ev->button.y, &col, &cells_row);
        bool down = ev->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
        if (cells_row == 0 && down) {
            if (button == 0)
                click_tab_bar(r, col);
            return;
        }
        if (cells_row == 0 && !(r->buttons_held & (1u << button)))
            return;
        if (down)
            r->buttons_held |= (uint8_t)(1u << button);
        else
            r->buttons_held &= (uint8_t)~(1u << button);
        uint8_t clicks = ev->button.clicks > 0 ? ev->button.clicks : 1;
        send_mouse(down ? MOUSE_PRESS : MOUSE_RELEASE, button, col, cells_row > 0 ? cells_row - 1 : 0,
                   clicks);
        break;
    }
    case SDL_EVENT_MOUSE_MOTION:
        cell_at(r, ev->motion.x, ev->motion.y, &col, &cells_row);
        if ((cells_row == 0 && r->buttons_held == 0) ||
            (col == r->mouse_col && cells_row == r->mouse_row))
            return;
        // Report the lowest button held, or 3 for none.
        button = 3;
        for (uint8_t b = 0; b < 3; b++)
            if (r->buttons_held & (1u << b)) {
                button = b;
                break;
            }
        send_mouse(MOUSE_MOTION, button, col, cells_row > 0 ? cells_row - 1 : 0, 1);
        break;
    case SDL_EVENT_MOUSE_WHEEL:
        if (ev->wheel.y == 0)
            return;
        cell_at(r, ev->wheel.mouse_x, ev->wheel.mouse_y, &col, &cells_row);
        if (cells_row == 0)
            return;
        send_mouse(MOUSE_WHEEL, ev->wheel.y > 0 ? 0 : 1, col, cells_row - 1, 1);
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

// The window moved to a screen with another scale: same font size in
// points, more (or fewer) pixels.
[[nodiscard]] static bool on_scale(struct renderer *r) {
    float scale = SDL_GetWindowDisplayScale(r->window);
    if (scale <= 0 || scale == r->scale)
        return true;
    r->scale = scale;
    return change_font(r);
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
        // A finished composition (é after a dead key) arrives here.
        r->preedit[0] = '\0';
        restart_blink(r);
        if (!r->demo)
            send_text(ev->text.text);
        break;
    case SDL_EVENT_TEXT_EDITING:
        // An input method is composing: show what it has so far.
        snprintf(r->preedit, sizeof r->preedit, "%s", ev->edit.text != nullptr ? ev->edit.text : "");
        mark_row(r, r->cursor_row + 1);
        r->dirty = true;
        break;
    case SDL_EVENT_KEY_DOWN:
        restart_blink(r);
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
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
        if (!on_scale(r)) {
            *status = 1;
            return false;
        }
        break;
    case SDL_EVENT_WINDOW_EXPOSED:
        r->dirty = true;
        break;
    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_FOCUS_LOST:
        r->focused = ev->type == SDL_EVENT_WINDOW_FOCUS_GAINED;
        restart_blink(r);
        break;
    default:
        break;
    }
    return true;
}

// Sleep until an event arrives, or until something on a timer changes:
// the halo going out, the cursor blinking. Returns false for a timer.
static bool wait_event(struct renderer *r, SDL_Event *ev) {
    Uint64 deadline = r->halo_until;
    if (r->blink_next != 0 && (deadline == 0 || r->blink_next < deadline))
        deadline = r->blink_next;
    if (deadline == 0)
        return SDL_WaitEvent(ev);
    Uint64 now = SDL_GetTicks();
    if (now < deadline && SDL_WaitEventTimeout(ev, (Sint32)(deadline - now)))
        return true;
    now = SDL_GetTicks();
    if (r->halo_until != 0 && now >= r->halo_until) {
        r->halo_until = 0;
        r->dirty = true;
    }
    if (r->blink_next != 0 && now >= r->blink_next) {
        r->blink_off = !r->blink_off;
        r->blink_next = now + blink_ms;
        r->dirty = true;
    }
    return false;
}

int main(int argc, char *argv[]) {
    struct renderer r = {
        .demo = argc > 1 && strcmp(argv[1], "--demo") == 0,
        .font_family = "monospace",
        .font_size = default_font_size,
        .scale = 1.0f,
        .padding_option = padding_px,
        .opacity = 100,
        .bold_is_bright = true,
        .focused = true,
        .cursor_visible = true,
        .dirty_first = INT_MAX,
        .dirty_last = -1,
        .mouse_col = -1,
        .mouse_row = -1,
    };
    // If Elixir goes away, writes to stdout fail with EPIPE instead of
    // killing us with SIGPIPE.
    signal(SIGPIPE, SIG_IGN);
    // wcwidth(3) needs a UTF-8 locale to know how wide characters are.
    setlocale(LC_CTYPE, "C.UTF-8");

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

    int status = 1;
    // The window's class (WM_CLASS on X11, app_id on Wayland) is what
    // desktops use to match it with guiltty.desktop: its name and icon in
    // the taskbar and the window switcher.
    (void)SDL_SetAppMetadata("guiltty", nullptr, "guiltty");
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "renderer: SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    // The font's pixel size depends on the screen's scale, so the font
    // loads now, before the window exists (its size depends on the font).
    float scale = SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay());
    r.scale = scale > 0 ? scale : 1.0f;
    if (!load_font(&r))
        goto out_sdl;
    if (!set_grid_size(&r, r.cols, r.rows))
        goto out_font;

    int width, height;
    if (ckd_mul(&width, (int)r.cols, r.cell_w) || ckd_add(&width, width, 2 * r.padding) ||
        ckd_mul(&height, (int)r.rows + 1, r.cell_h) || ckd_add(&height, height, 2 * r.padding))
        goto out_font;
    if (!renderer_backend.configure())
        goto out_font;
    // HIGH_PIXEL_DENSITY: on a HiDPI screen, draw at full resolution instead
    // of being scaled up blurry. TRANSPARENT: a window with an alpha
    // channel, which the compositor blends with what's behind it. It can
    // only be chosen now, so a later change of opacity needs a new window.
    r.transparent = r.opacity < 100;
    r.window = SDL_CreateWindow("guiltty", width, height,
                                renderer_backend.window_flags | SDL_WINDOW_RESIZABLE |
                                    SDL_WINDOW_HIGH_PIXEL_DENSITY |
                                    (r.transparent ? SDL_WINDOW_TRANSPARENT : 0));
    if (r.window == nullptr) {
        fprintf(stderr, "renderer: SDL_CreateWindow: %s\n", SDL_GetError());
        goto out_font;
    }
    // We asked for pixels, but SDL sizes windows in window coordinates.
    float density = SDL_GetWindowPixelDensity(r.window);
    if (density > 1.0f)
        SDL_SetWindowSize(r.window, (int)((float)width / density), (int)((float)height / density));
    set_minimum_size(&r);
    set_window_icon(r.window);
    r.backend = renderer_backend.init(r.window);
    if (r.backend == nullptr || !renderer_backend.upload_atlas(r.backend, &r.atlas))
        goto out_window;
    atlas_mark_clean(&r.atlas);

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
    // tiling one never does): start from what we actually got. And the
    // window may be on another screen than the primary one.
    int pw, ph;
    SDL_GetWindowSizeInPixels(r.window, &pw, &ph);
    if (!on_pixel_size(&r, pw, ph) || !on_scale(&r))
        goto out_backend;
    SDL_StartTextInput(r.window);
    update_text_area(&r);

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
out_font:
    atlas_free(&r.atlas);
    fonts_close(&r.fonts);
out_sdl:
    SDL_Quit();
    free(r.cells);
    free(r.glyphs);
    free(r.clusters);
    return status;
}

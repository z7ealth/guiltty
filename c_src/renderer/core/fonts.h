// Fonts: the one you asked for, plus whatever fontconfig finds for the
// characters it doesn't have (CJK, emoji, icons). Draws a grapheme cluster
// into a cell-sized RGBA area, shaped with HarfBuzz.
#pragma once

#include <stddef.h>
#include <stdint.h>

constexpr int max_fonts = 24;
constexpr int max_missing = 256;

struct font;

struct fonts {
    void *ft; // FT_Library; kept opaque so callers don't need FreeType headers
    struct font *list[max_fonts]; // list[0] is the primary font
    int count;
    char family[256];
    int pixel_size;
    // The cell, from the primary font.
    int cell_w, cell_h;
    int baseline; // pixels from the top of a cell down to the baseline
    int line_thickness; // for underline and strikethrough
    // Codepoints no installed font has, so we don't ask fontconfig again.
    uint32_t missing[max_missing];
    int missing_count;
};

// Opens the font that best matches `family` (a fontconfig name, such as
// "monospace" or "JetBrainsMono Nerd Font Mono") at `pixel_size`.
[[nodiscard]] bool fonts_open(struct fonts *f, const char *family, int pixel_size);
void fonts_close(struct fonts *f);

// Draws a cluster (UTF-8) into an area `width` cells wide and one cell
// high: `rgba` points at its top-left pixel, `stride` is bytes per row of
// the whole bitmap. Returns true if the glyph has colors of its own (an
// emoji); otherwise it's drawn white, with alpha as coverage, for the
// backend to tint.
bool fonts_render(struct fonts *f, const char *utf8, size_t len, int width, uint8_t *rgba,
                  size_t stride);

// The longest run of characters shaped together to look for ligatures.
constexpr int max_ligature_run = 32;

// Shapes `n` characters (one per cell, n <= max_ligature_run) with the
// primary font and finds where the font joined them: a ligature such as
// "->" or "!=". spans[i] is the number of cells of the ligature that
// starts at i (2 or more), or 0.
void fonts_ligatures(const struct fonts *f, const uint32_t *cps, int n, uint8_t *spans);

// The Private Use Area, where Nerd Font icons live.
bool private_use(uint32_t cp);

// Decodes one UTF-8 character at s[*i], advancing *i. Invalid bytes give
// U+FFFD.
uint32_t utf8_next(const uint8_t *s, size_t len, size_t *i);

// Encodes a codepoint; returns the number of bytes (1-4) written to out.
size_t utf8_put(uint32_t cp, char out[4]);

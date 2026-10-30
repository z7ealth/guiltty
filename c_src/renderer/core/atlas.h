// The glyph atlas: every printable ASCII glyph rasterized by FreeType into
// one 8-bit bitmap, laid out as a grid of equal cells. It lives on the CPU;
// a backend uploads it as a texture.
#pragma once

#include <stdint.h>

constexpr uint8_t atlas_first_char = 32; // ' '
constexpr uint8_t atlas_last_char = 126; // '~'
constexpr int atlas_grid_cols = 16;

struct atlas {
    int cell_w, cell_h; // one terminal cell, in pixels
    int baseline; // pixels from the top of a cell down to the baseline
    int line_thickness; // for underline and strikethrough
    int width, height; // the whole bitmap, in pixels
    uint8_t *pixels; // width * height coverage values, row-major
};

// Asks fontconfig for the font that best matches a family name (for
// example "monospace", the user's default). Returns a malloc'd path.
[[nodiscard]] char *font_find(const char *family);

[[nodiscard]] bool atlas_build(struct atlas *atlas, const char *font_path, int pixel_size);

void atlas_free(struct atlas *atlas);

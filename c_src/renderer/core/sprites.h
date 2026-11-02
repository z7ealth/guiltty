// Characters guiltty draws itself instead of taking them from a font:
// block elements (█ ▀ ▌ ▖...), shades (░ ▒ ▓), box-drawing lines
// (─ │ ┌ ┼ ╭...) and the solid powerline shapes (Nerd Fonts' U+E0B0,
// U+E0B2, U+E0B4, U+E0B6). A font's versions rarely fill the cell exactly, so
// neighbors leave gaps, and its shades are dot patterns. Drawn here, they
// fill the cell to the pixel and meet the next one.
#pragma once

#include <stddef.h>
#include <stdint.h>

// Whether `cp` is one of ours. Those are always one cell wide: never
// widened like a font's icons.
bool sprite_has(uint32_t cp);

// Draws codepoint `cp` into a cell_w x cell_h RGBA area (white, alpha as
// coverage). Returns false if it isn't one of ours.
bool sprite_render(uint32_t cp, int cell_w, int cell_h, int thickness, uint8_t *rgba, size_t stride);

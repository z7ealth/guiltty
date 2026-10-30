// Characters guiltty draws itself instead of taking them from a font:
// block elements (█ ▀ ▌ ▖...), shades (░ ▒ ▓) and box-drawing lines
// (─ │ ┌ ┼ ╭...). A font's versions rarely fill the cell exactly, so
// neighbors leave gaps, and its shades are dot patterns. Drawn here, they
// fill the cell to the pixel and meet the next one.
#pragma once

#include <stddef.h>
#include <stdint.h>

// Draws codepoint `cp` into a cell_w x cell_h RGBA area (white, alpha as
// coverage). Returns false if it isn't one of ours.
bool sprite_render(uint32_t cp, int cell_w, int cell_h, int thickness, uint8_t *rgba, size_t stride);

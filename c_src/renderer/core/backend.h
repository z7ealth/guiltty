// The seam between the renderer core and a GPU backend.
//
// The core owns the window, the events, the port and the cells; a backend
// only uploads and draws. The core never includes GL or Vulkan headers. Each
// backend builds into its own binary and defines `renderer_backend`.
#pragma once

#include <SDL3/SDL.h>
#include <stdint.h>

#include "atlas.h"

// Attribute bits, the same as Guiltty.Grid's.
enum cell_attr : uint16_t {
    ATTR_BOLD = 0x01,
    ATTR_DIM = 0x02,
    ATTR_ITALIC = 0x04,
    ATTR_UNDERLINE = 0x08,
    ATTR_BLINK = 0x10,
    ATTR_INVERSE = 0x20,
    ATTR_HIDDEN = 0x40,
    ATTR_STRIKE = 0x80,
    ATTR_WIDE = 0x100, // the left half of a wide character
    ATTR_SPACER = 0x200, // the right half
    ATTR_MATCH = 0x400, // a search match (Guiltty.View)
    ATTR_CURRENT_MATCH = 0x800, // the match the search is on
    // Not on the wire, set by the core. The glyph has its own colors
    // (emoji): draw it as is instead of in the fg color.
    CELL_COLOR_GLYPH = 0x8000,
    // The background is the theme's default: with a translucent window,
    // only these cells let the desktop show through.
    CELL_DEFAULT_BG = 0x4000,
    // Draw the accent line along the bottom (the active tab).
    CELL_ACCENT = 0x2000,
};

// A cell ready to draw: the core has already applied the theme, inverse,
// dim and hidden, and found the glyph in the atlas, so a backend only sees
// an atlas slot and final colors. This is also the per-instance vertex
// data the GL backend uploads.
struct cell {
    uint16_t slot; // atlas slot; 0 is blank
    uint16_t attrs; // the backend still draws bold, underline, strike, color glyphs
    uint8_t fg[3];
    uint8_t bg[3];
    uint8_t pad[2];
};
static_assert(sizeof(struct cell) == 12, "uploaded as-is, 12 bytes per cell");

// Everything needed to draw one frame. cells holds cols * rows entries,
// row-major. Only rows dirty_first..dirty_last changed since the previous
// frame (none if dirty_first > dirty_last); the backend may upload just
// those, unless the grid's size changed.
struct frame {
    uint16_t cols, rows;
    const struct cell *cells;
    int dirty_first, dirty_last;
    uint16_t cursor_row, cursor_col;
    bool cursor_visible;
    bool cursor_wide; // the cursor is on a wide character: draw it two cells wide
    uint8_t cursor_shape; // enum cursor_shape (protocol.h)
    uint8_t accent_rgb[3]; // the line under the active tab
    float opacity; // of cells with CELL_DEFAULT_BG and of the padding; 1 = opaque
    // Draw cells row 0 (the tab bar) below the others instead of above.
    bool first_row_last;
    uint8_t cursor_rgb[3];
    uint8_t clear_rgb[3]; // the padding around the grid
    int origin_x, origin_y; // padding from the window's top-left, in pixels
};

// Callers must check every bool and pointer result ([[nodiscard]] can't be
// put on function-pointer members).
struct backend {
    const char *name;
    // Flags SDL needs to create a window this backend can draw into.
    SDL_WindowFlags window_flags;
    // Called before the window exists (e.g. to request a GL version).
    bool (*configure)(void);
    // Returns the backend's private state, or nullptr on failure.
    void *(*init)(SDL_Window *window);
    // Uploads the atlas: all of it when its generation changed since the
    // last upload, otherwise only the rows between dirty_top and
    // dirty_bottom (if any). The core then marks it clean.
    bool (*upload_atlas)(void *state, const struct atlas *atlas);
    // Draws and presents one frame. The grid size may change between frames.
    void (*draw_frame)(void *state, const struct frame *frame);
    void (*resize)(void *state, int width_px, int height_px);
    void (*shutdown)(void *state);
};

extern const struct backend renderer_backend;

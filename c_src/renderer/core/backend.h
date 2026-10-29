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
enum cell_attr : uint8_t {
    ATTR_BOLD = 0x01,
    ATTR_DIM = 0x02,
    ATTR_ITALIC = 0x04,
    ATTR_UNDERLINE = 0x08,
    ATTR_BLINK = 0x10,
    ATTR_INVERSE = 0x20,
    ATTR_HIDDEN = 0x40,
    ATTR_STRIKE = 0x80,
};

// A cell ready to draw: the core has already applied the theme, inverse,
// dim and hidden, so a backend only sees final colors. This is also the
// per-instance vertex data the GL backend uploads.
struct cell {
    uint8_t ch; // printable ASCII
    uint8_t attrs; // the backend still draws bold, underline and strike
    uint8_t fg[3];
    uint8_t bg[3];
};
static_assert(sizeof(struct cell) == 8, "uploaded as-is, 8 bytes per cell");

// Everything needed to draw one frame. cells holds cols * rows entries,
// row-major.
struct frame {
    uint16_t cols, rows;
    const struct cell *cells;
    uint16_t cursor_row, cursor_col;
    bool cursor_visible;
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
    bool (*upload_atlas)(void *state, const struct atlas *atlas);
    // Draws and presents one frame. The grid size may change between frames.
    void (*draw_frame)(void *state, const struct frame *frame);
    void (*resize)(void *state, int width_px, int height_px);
    void (*shutdown)(void *state);
};

extern const struct backend renderer_backend;

// The seam between the renderer core and a GPU backend.
//
// The core owns the window, the events, the port and the cells; a backend
// only uploads and draws. The core never includes GL or Vulkan headers. Each
// backend builds into its own binary and defines `renderer_backend`.
#pragma once

#include <SDL3/SDL.h>
#include <stdint.h>

#include "atlas.h"

// Everything needed to draw one frame. cells holds cols * rows bytes, one
// ASCII character per cell, row-major.
struct frame {
    uint16_t cols, rows;
    const uint8_t *cells;
    uint16_t cursor_row, cursor_col;
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
    void *(*init)(SDL_Window *window, uint16_t cols, uint16_t rows);
    bool (*upload_atlas)(void *state, const struct atlas *atlas);
    // Draws and presents one frame.
    void (*draw_frame)(void *state, const struct frame *frame);
    void (*resize)(void *state, int width_px, int height_px);
    void (*shutdown)(void *state);
};

extern const struct backend renderer_backend;

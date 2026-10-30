// What both stages need for a frame, sent with each draw as push
// constants (a small block of data in the command buffer itself; Vulkan
// guarantees at least 128 bytes). Must match struct push in vk_backend.c.
layout(push_constant, std430) uniform Frame {
    vec2 viewport;      // window size in pixels
    vec2 origin;        // top-left padding in pixels
    vec2 cell;          // cell size in pixels
    float opacity;      // of default backgrounds; 1 = opaque
    int pass;           // 0 = backgrounds, 1 = glyphs
    int cols;           // grid columns
    int atlas_cols;     // slots per atlas row
    int cursor;         // instance index of the cursor cell, -1 if hidden
    int cursor2;        // its right half on a wide character, or -1
    int rows;           // rows of cells, the tab bar's included
    int first_row_last; // 1: draw row 0 (the tab bar) at the bottom
    int underline_y;    // pixel rows inside the cell
    int strike_y;
    int line_thickness;
    int cursor_shape;   // 0 block, 1 underline, 2 bar, 3 hollow block
    vec4 cursor_color;
    vec4 accent;        // the line under the active tab
} u;

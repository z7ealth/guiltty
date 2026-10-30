#version 450
#extension GL_GOOGLE_include_directive : require

// The Vulkan twin of gl/shaders/cell.vert: one instance per cell, four
// vertices per instance (a triangle strip). Per-cell data (struct cell):
layout(location = 0) in uint a_slot;  // the glyph's slot in the atlas, 0 = blank
layout(location = 1) in uint a_attrs; // bold, underline, strike, color glyph bits
layout(location = 2) in vec4 a_fg;    // final colors, 0..1 (alpha unused)
layout(location = 3) in vec4 a_bg;

#include "frame.glsl"

layout(location = 0) out vec2 v_texel; // position in the atlas, in texels
layout(location = 1) out vec2 v_local; // position inside the cell, in pixels
layout(location = 2) flat out uint v_attrs;
layout(location = 3) flat out vec3 v_fg;
layout(location = 4) flat out vec3 v_bg;
layout(location = 5) flat out int v_is_cursor; // 0 no, 1 the cursor's cell, 2 its right half

void main() {
    // Strip order: (0,0) (1,0) (0,1) (1,1)
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1);
    int row = gl_InstanceIndex / u.cols;
    if (u.first_row_last == 1)
        row = row == 0 ? u.rows - 1 : row - 1;
    vec2 cell = vec2(gl_InstanceIndex % u.cols, row);

    // Vulkan's y axis points down, like pixel rows: no flip, unlike GL.
    vec2 px = u.origin + (cell + corner) * u.cell;
    gl_Position = vec4(px / u.viewport * 2.0 - 1.0, 0.0, 1.0);

    int slot = int(a_slot);
    vec2 slot_xy = vec2(slot % u.atlas_cols, slot / u.atlas_cols);
    v_texel = (slot_xy + corner) * u.cell;
    v_local = corner * u.cell;
    v_attrs = a_attrs;
    v_fg = a_fg.rgb;
    v_bg = a_bg.rgb;
    v_is_cursor = gl_InstanceIndex == u.cursor ? 1 : gl_InstanceIndex == u.cursor2 ? 2 : 0;
}

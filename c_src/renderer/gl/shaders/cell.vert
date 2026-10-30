#version 330 core

// One instance per cell, four vertices per instance (a triangle strip).
// Per-cell data (struct cell, 12 bytes):
layout(location = 0) in uint a_slot; // the glyph's slot in the atlas, 0 = blank
layout(location = 1) in uint a_attrs; // bold, underline, strike, color glyph bits
layout(location = 2) in vec3 a_fg; // final colors, 0..1
layout(location = 3) in vec3 a_bg;

uniform vec2 u_viewport; // window size in pixels
uniform vec2 u_origin; // top-left padding in pixels
uniform vec2 u_cell; // cell size in pixels
uniform int u_cols; // grid columns
uniform int u_atlas_cols; // slots per atlas row
uniform int u_cursor; // instance index of the cursor cell, -1 if hidden
uniform int u_cursor2; // its right half when it's on a wide character, or -1

out vec2 v_texel; // position in the atlas, in texels
out vec2 v_local; // position inside the cell, in pixels
flat out uint v_attrs;
flat out vec3 v_fg;
flat out vec3 v_bg;
flat out int v_is_cursor;

void main() {
    // Strip order: (0,0) (1,0) (0,1) (1,1)
    vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
    vec2 cell = vec2(gl_InstanceID % u_cols, gl_InstanceID / u_cols);

    vec2 px = u_origin + (cell + corner) * u_cell;
    vec2 ndc = px / u_viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0); // pixels grow down, NDC grows up

    // A wide glyph fills two neighboring slots; each half of the character
    // is a cell of its own that names its slot.
    int slot = int(a_slot);
    vec2 slot_xy = vec2(slot % u_atlas_cols, slot / u_atlas_cols);
    v_texel = (slot_xy + corner) * u_cell;
    v_local = corner * u_cell;
    v_attrs = a_attrs;
    v_fg = a_fg;
    v_bg = a_bg;
    v_is_cursor = (gl_InstanceID == u_cursor || gl_InstanceID == u_cursor2) ? 1 : 0;
}

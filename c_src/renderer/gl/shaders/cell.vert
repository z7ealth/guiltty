#version 330 core

// One instance per cell, four vertices per instance (a triangle strip).
layout(location = 0) in uint a_glyph; // the cell's ASCII byte

uniform vec2 u_viewport; // window size in pixels
uniform vec2 u_origin; // top-left padding in pixels
uniform vec2 u_cell; // cell size in pixels
uniform int u_cols; // grid columns
uniform int u_atlas_cols; // glyphs per atlas row
uniform int u_first_char; // first character in the atlas
uniform int u_cursor; // instance index of the cursor cell

out vec2 v_texel; // position in the atlas, in texels
flat out int v_is_cursor;

void main() {
    // Strip order: (0,0) (1,0) (0,1) (1,1)
    vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
    vec2 cell = vec2(gl_InstanceID % u_cols, gl_InstanceID / u_cols);

    vec2 px = u_origin + (cell + corner) * u_cell;
    vec2 ndc = px / u_viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0); // pixels grow down, NDC grows up

    int slot = int(a_glyph) - u_first_char;
    vec2 slot_xy = vec2(slot % u_atlas_cols, slot / u_atlas_cols);
    v_texel = (slot_xy + corner) * u_cell;
    v_is_cursor = gl_InstanceID == u_cursor ? 1 : 0;
}

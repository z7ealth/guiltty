#version 330 core

in vec2 v_texel;
flat in int v_is_cursor;

uniform sampler2D u_atlas; // one channel: glyph coverage
uniform vec3 u_fg;
uniform vec3 u_bg;

out vec4 out_color;

void main() {
    // The atlas maps 1:1 to window pixels, so fetch the exact texel.
    float coverage = texelFetch(u_atlas, ivec2(v_texel), 0).r;
    // The block cursor is the cell with its colors swapped.
    vec3 fg = v_is_cursor == 1 ? u_bg : u_fg;
    vec3 bg = v_is_cursor == 1 ? u_fg : u_bg;
    out_color = vec4(mix(bg, fg, coverage), 1.0);
}

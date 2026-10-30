#version 450
#extension GL_GOOGLE_include_directive : require

// The Vulkan twin of gl/shaders/cell.frag, line for line: drawn twice,
// backgrounds then glyphs.

layout(location = 0) in vec2 v_texel;
layout(location = 1) in vec2 v_local;
layout(location = 2) flat in uint v_attrs;
layout(location = 3) flat in vec3 v_fg;
layout(location = 4) flat in vec3 v_bg;
layout(location = 5) flat in int v_is_cursor;

#include "frame.glsl"

// RGBA: white + coverage in alpha, or an emoji's own colors.
layout(set = 0, binding = 0) uniform sampler2D u_atlas;

layout(location = 0) out vec4 out_color;

const uint BOLD = 0x01u;
const uint UNDERLINE = 0x08u;
const uint STRIKE = 0x80u;
const uint COLOR_GLYPH = 0x8000u;
const uint DEFAULT_BG = 0x4000u;
const uint ACCENT = 0x2000u;

const int BLOCK = 0;
const int UNDERLINE_CURSOR = 1;
const int BAR = 2;
const int HOLLOW = 3;

bool on_line(int y, int top) {
    return y >= top && y < top + u.line_thickness;
}

bool on_cursor_shape() {
    if (v_is_cursor == 0 || u.cursor_shape == BLOCK)
        return false;
    vec2 p = v_local;
    float t = float(max(u.line_thickness, 1));
    if (u.cursor_shape == UNDERLINE_CURSOR)
        return p.y >= u.cell.y - 2.0 * t;
    if (u.cursor_shape == BAR)
        return v_is_cursor == 1 && p.x < 2.0 * t;
    bool last = v_is_cursor == 2 || u.cursor2 < 0;
    return p.y < t || p.y >= u.cell.y - t || (v_is_cursor == 1 && p.x < t) ||
           (last && p.x >= u.cell.x - t);
}

void main() {
    if (u.pass == 0) {
        bool block = v_is_cursor != 0 && u.cursor_shape == BLOCK;
        float a = (v_attrs & DEFAULT_BG) != 0u && !block ? u.opacity : 1.0;
        out_color = vec4((block ? u.cursor_color.rgb : v_bg) * a, a);
        return;
    }

    float accent = 2.0 * float(u.line_thickness);
    bool on_accent = u.first_row_last == 1 ? v_local.y < accent : v_local.y >= u.cell.y - accent;
    if ((v_attrs & ACCENT) != 0u && on_accent) {
        out_color = vec4(u.accent.rgb, 1.0);
        return;
    }
    if (on_cursor_shape()) {
        out_color = vec4(u.cursor_color.rgb, 1.0);
        return;
    }

    ivec2 texel = ivec2(v_texel);
    vec4 glyph = texelFetch(u_atlas, texel, 0);

    int y = int(v_local.y);
    bool line = ((v_attrs & UNDERLINE) != 0u && on_line(y, u.underline_y)) ||
                ((v_attrs & STRIKE) != 0u && on_line(y, u.strike_y));

    if ((v_attrs & COLOR_GLYPH) != 0u && !line) {
        if (glyph.a <= 0.0)
            discard;
        out_color = glyph;
        return;
    }

    float coverage = glyph.a;
    if ((v_attrs & BOLD) != 0u && v_local.x >= 1.0)
        coverage = max(coverage, texelFetch(u_atlas, texel - ivec2(1, 0), 0).a);
    if (line)
        coverage = 1.0;

    if (coverage <= 0.0)
        discard;
    vec3 fg = v_is_cursor != 0 && u.cursor_shape == BLOCK ? v_bg : v_fg;
    out_color = vec4(fg, coverage);
}

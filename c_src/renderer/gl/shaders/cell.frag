#version 330 core

// Drawn twice: pass 0 paints every cell's background, pass 1 blends the
// glyphs on top. Splitting them means a glyph that spills past its cell
// is never covered by its neighbor's background.

in vec2 v_texel;
in vec2 v_local;
flat in uint v_attrs;
flat in vec3 v_fg;
flat in vec3 v_bg;
flat in int v_is_cursor;

uniform int u_pass; // 0 = backgrounds, 1 = glyphs
uniform sampler2D u_atlas; // RGBA: white + coverage in alpha, or an emoji's own colors
uniform vec3 u_cursor_color;
uniform int u_underline_y; // pixel rows inside the cell
uniform int u_strike_y;
uniform int u_line_thickness;
uniform int u_cursor_shape; // 0 block, 1 underline, 2 bar, 3 hollow block
uniform vec3 u_accent; // the line under the active tab
uniform float u_opacity; // of default backgrounds; 1 = opaque
uniform vec2 u_cell; // cell size in pixels
uniform int u_cursor2; // the cursor's right half (wide character), or -1
uniform int u_first_row_last; // 1: the tab bar is at the bottom

out vec4 out_color;

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
    return y >= top && y < top + u_line_thickness;
}

// Is this pixel part of a cursor that isn't a block: a line under the
// cell, a bar at its left, or the outline of a block?
bool on_cursor_shape() {
    if (v_is_cursor == 0 || u_cursor_shape == BLOCK)
        return false;
    vec2 p = v_local;
    float t = float(max(u_line_thickness, 1));
    if (u_cursor_shape == UNDERLINE_CURSOR)
        return p.y >= u_cell.y - 2.0 * t;
    if (u_cursor_shape == BAR)
        return v_is_cursor == 1 && p.x < 2.0 * t;
    // Hollow: top and bottom on both halves, a side on each end.
    bool last = v_is_cursor == 2 || u_cursor2 < 0; // the right end of the cursor
    return p.y < t || p.y >= u_cell.y - t || (v_is_cursor == 1 && p.x < t) ||
           (last && p.x >= u_cell.x - t);
}

void main() {
    if (u_pass == 0) {
        // The block cursor is a cell painted in the cursor color. Colors
        // go out premultiplied: the default background may be translucent.
        bool block = v_is_cursor != 0 && u_cursor_shape == BLOCK;
        float a = (v_attrs & DEFAULT_BG) != 0u && !block ? u_opacity : 1.0;
        out_color = vec4((block ? u_cursor_color : v_bg) * a, a);
        return;
    }

    // The accent line under the active tab, then the thin cursors: they go
    // over whatever is in the cell.
    // The accent line runs along the tab's edge that faces the terminal.
    float accent = 2.0 * float(u_line_thickness);
    bool on_accent = u_first_row_last == 1 ? v_local.y < accent : v_local.y >= u_cell.y - accent;
    if ((v_attrs & ACCENT) != 0u && on_accent) {
        out_color = vec4(u_accent, 1.0);
        return;
    }
    if (on_cursor_shape()) {
        out_color = vec4(u_cursor_color, 1.0);
        return;
    }

    // The atlas maps 1:1 to window pixels, so fetch the exact texel.
    ivec2 texel = ivec2(v_texel);
    vec4 glyph = texelFetch(u_atlas, texel, 0);

    int y = int(v_local.y);
    bool line = ((v_attrs & UNDERLINE) != 0u && on_line(y, u_underline_y)) ||
                ((v_attrs & STRIKE) != 0u && on_line(y, u_strike_y));

    // An emoji brings its own colors.
    if ((v_attrs & COLOR_GLYPH) != 0u && !line) {
        if (glyph.a <= 0.0)
            discard;
        out_color = glyph;
        return;
    }

    float coverage = glyph.a;
    // We have one font weight; fake bold by smearing each glyph one pixel
    // to the right.
    if ((v_attrs & BOLD) != 0u && v_local.x >= 1.0)
        coverage = max(coverage, texelFetch(u_atlas, texel - ivec2(1, 0), 0).a);
    if (line)
        coverage = 1.0;

    if (coverage <= 0.0)
        discard;
    // Under the block cursor, text takes the cell's background color.
    vec3 fg = v_is_cursor != 0 && u_cursor_shape == BLOCK ? v_bg : v_fg;
    out_color = vec4(fg, coverage);
}

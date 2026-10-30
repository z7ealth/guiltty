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

out vec4 out_color;

const uint BOLD = 0x01u;
const uint UNDERLINE = 0x08u;
const uint STRIKE = 0x80u;
const uint COLOR_GLYPH = 0x8000u;

bool on_line(int y, int top) {
    return y >= top && y < top + u_line_thickness;
}

void main() {
    if (u_pass == 0) {
        // The block cursor is a cell painted in the cursor color.
        out_color = vec4(v_is_cursor == 1 ? u_cursor_color : v_bg, 1.0);
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
    vec3 fg = v_is_cursor == 1 ? v_bg : v_fg;
    out_color = vec4(fg, coverage);
}

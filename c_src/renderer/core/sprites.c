#include "sprites.h"

#include <math.h>

// --- Filling rectangles ---

static void put(uint8_t *rgba, size_t stride, int x, int y, uint8_t alpha) {
    uint8_t *p = rgba + (size_t)y * stride + (size_t)x * 4;
    p[0] = p[1] = p[2] = 255;
    if (alpha > p[3])
        p[3] = alpha;
}

// Fill the part of the cell from (x0, y0) to (x1, y1), given in eighths of
// the cell, with `alpha`.
static void fill8(int w, int h, uint8_t *rgba, size_t stride, int x0, int y0, int x1, int y1,
                  uint8_t alpha) {
    for (int y = y0 * h / 8; y < y1 * h / 8; y++)
        for (int x = x0 * w / 8; x < x1 * w / 8; x++)
            put(rgba, stride, x, y, alpha);
}

// U+2580..U+259F, block elements.
static bool block(uint32_t cp, int w, int h, uint8_t *rgba, size_t stride) {
    if (cp == 0x2580) { // ▀ upper half
        fill8(w, h, rgba, stride, 0, 0, 8, 4, 255);
    } else if (cp >= 0x2581 && cp <= 0x2588) { // ▁..█ lower 1/8 .. full
        fill8(w, h, rgba, stride, 0, 8 - (int)(cp - 0x2580), 8, 8, 255);
    } else if (cp >= 0x2589 && cp <= 0x258F) { // ▉..▏ left 7/8 .. 1/8
        fill8(w, h, rgba, stride, 0, 0, 8 - (int)(cp - 0x2588), 8, 255);
    } else if (cp == 0x2590) { // ▐ right half
        fill8(w, h, rgba, stride, 4, 0, 8, 8, 255);
    } else if (cp >= 0x2591 && cp <= 0x2593) {
        // ░ ▒ ▓: a quarter, half, three quarters of the color, evenly, the
        // way they're meant to look (fonts draw them as dot patterns).
        fill8(w, h, rgba, stride, 0, 0, 8, 8, (uint8_t)(64 * (cp - 0x2590)));
    } else if (cp == 0x2594) { // ▔ upper 1/8
        fill8(w, h, rgba, stride, 0, 0, 8, 1, 255);
    } else if (cp == 0x2595) { // ▕ right 1/8
        fill8(w, h, rgba, stride, 7, 0, 8, 8, 255);
    } else if (cp >= 0x2596 && cp <= 0x259F) {
        // ▖..▟ quadrants: bits for upper left, upper right, lower left,
        // lower right.
        static const uint8_t quads[] = {0b0010, 0b0001, 0b1000, 0b1011, 0b1001,
                                        0b1110, 0b1101, 0b0100, 0b0110, 0b0111};
        static_assert(sizeof quads == 0x259F - 0x2596 + 1, "one entry per quadrant character");
        uint8_t q = quads[cp - 0x2596];
        if (q & 0b1000)
            fill8(w, h, rgba, stride, 0, 0, 4, 4, 255);
        if (q & 0b0100)
            fill8(w, h, rgba, stride, 4, 0, 8, 4, 255);
        if (q & 0b0010)
            fill8(w, h, rgba, stride, 0, 4, 4, 8, 255);
        if (q & 0b0001)
            fill8(w, h, rgba, stride, 4, 4, 8, 8, 255);
    } else {
        return false;
    }
    return true;
}

// --- Box-drawing lines ---

// Each light/heavy box character is four arms from the center: up, right,
// down, left, each 0 (none), 1 (light) or 2 (heavy).
#define ARMS(u, r, d, l) (uint16_t)((u) << 12 | (r) << 8 | (d) << 4 | (l))

// U+2500..U+254B. Zero: not a plain set of arms (the dashed lines), so the
// font draws it.
static const uint16_t box_arms[] = {
    ARMS(0, 1, 0, 1), ARMS(0, 2, 0, 2), ARMS(1, 0, 1, 0), ARMS(2, 0, 2, 0), // ─ ━ │ ┃
    0, 0, 0, 0, 0, 0, 0, 0,                                                 // dashes
    ARMS(0, 1, 1, 0), ARMS(0, 2, 1, 0), ARMS(0, 1, 2, 0), ARMS(0, 2, 2, 0), // ┌ ┍ ┎ ┏
    ARMS(0, 0, 1, 1), ARMS(0, 0, 1, 2), ARMS(0, 0, 2, 1), ARMS(0, 0, 2, 2), // ┐ ┑ ┒ ┓
    ARMS(1, 1, 0, 0), ARMS(1, 2, 0, 0), ARMS(2, 1, 0, 0), ARMS(2, 2, 0, 0), // └ ┕ ┖ ┗
    ARMS(1, 0, 0, 1), ARMS(1, 0, 0, 2), ARMS(2, 0, 0, 1), ARMS(2, 0, 0, 2), // ┘ ┙ ┚ ┛
    ARMS(1, 1, 1, 0), ARMS(1, 2, 1, 0), ARMS(2, 1, 1, 0), ARMS(1, 1, 2, 0), // ├ ┝ ┞ ┟
    ARMS(2, 1, 2, 0), ARMS(2, 2, 1, 0), ARMS(1, 2, 2, 0), ARMS(2, 2, 2, 0), // ┠ ┡ ┢ ┣
    ARMS(1, 0, 1, 1), ARMS(1, 0, 1, 2), ARMS(2, 0, 1, 1), ARMS(1, 0, 2, 1), // ┤ ┥ ┦ ┧
    ARMS(2, 0, 2, 1), ARMS(2, 0, 1, 2), ARMS(1, 0, 2, 2), ARMS(2, 0, 2, 2), // ┨ ┩ ┪ ┫
    ARMS(0, 1, 1, 1), ARMS(0, 1, 1, 2), ARMS(0, 2, 1, 1), ARMS(0, 2, 1, 2), // ┬ ┭ ┮ ┯
    ARMS(0, 1, 2, 1), ARMS(0, 1, 2, 2), ARMS(0, 2, 2, 1), ARMS(0, 2, 2, 2), // ┰ ┱ ┲ ┳
    ARMS(1, 1, 0, 1), ARMS(1, 1, 0, 2), ARMS(1, 2, 0, 1), ARMS(1, 2, 0, 2), // ┴ ┵ ┶ ┷
    ARMS(2, 1, 0, 1), ARMS(2, 1, 0, 2), ARMS(2, 2, 0, 1), ARMS(2, 2, 0, 2), // ┸ ┹ ┺ ┻
    ARMS(1, 1, 1, 1), ARMS(1, 1, 1, 2), ARMS(1, 2, 1, 1), ARMS(1, 2, 1, 2), // ┼ ┽ ┾ ┿
    ARMS(2, 1, 1, 1), ARMS(1, 1, 2, 1), ARMS(2, 1, 2, 1), ARMS(2, 1, 1, 2), // ╀ ╁ ╂ ╃
    ARMS(2, 2, 1, 1), ARMS(1, 1, 2, 2), ARMS(1, 2, 2, 1), ARMS(2, 2, 1, 2), // ╄ ╅ ╆ ╇
    ARMS(1, 2, 2, 2), ARMS(2, 1, 2, 2), ARMS(2, 2, 2, 1), ARMS(2, 2, 2, 2), // ╈ ╉ ╊ ╋
};

// U+2574..U+257F: half lines.
static const uint16_t half_arms[] = {
    ARMS(0, 0, 0, 1), ARMS(1, 0, 0, 0), ARMS(0, 1, 0, 0), ARMS(0, 0, 1, 0), // ╴ ╵ ╶ ╷
    ARMS(0, 0, 0, 2), ARMS(2, 0, 0, 0), ARMS(0, 2, 0, 0), ARMS(0, 0, 2, 0), // ╸ ╹ ╺ ╻
    ARMS(0, 2, 0, 1), ARMS(1, 0, 2, 0), ARMS(0, 1, 0, 2), ARMS(2, 0, 1, 0), // ╼ ╽ ╾ ╿
};

// Anti-aliased coverage of a line `width` pixels thick for a pixel whose
// center is `d` pixels from the line's middle.
static uint8_t coverage(double d, double width) {
    double a = width / 2 + 0.5 - d;
    return a <= 0 ? 0 : a >= 1 ? 255 : (uint8_t)(a * 255);
}

static void rect(uint8_t *rgba, size_t stride, int x0, int y0, int x1, int y1) {
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++)
            put(rgba, stride, x, y, 255);
}

// Where a stroke `t` pixels thick starts so that it's centered on pixel
// `c` (an even thickness leans up or left by half a pixel).
static int start(int c, int t) { return c - (t - 1) / 2; }

// Straight arms are whole pixels, no anti-aliasing: they're axis-aligned,
// so they stay crisp, and they meet the neighboring cell's exactly. The
// center is a whole pixel, the same in every cell. Each arm reaches over
// the crossing stroke, so corners and joins are square.
static void arms(uint16_t a, int w, int h, int thickness, uint8_t *rgba, size_t stride) {
    int cx = w / 2, cy = h / 2;
    int up = a >> 12 & 0xF, right = a >> 8 & 0xF, down = a >> 4 & 0xF, left = a & 0xF;
    // The horizontal and vertical strokes as they cross the center.
    int th = (left > right ? left : right) * thickness, tv = (up > down ? up : down) * thickness;
    int h0 = start(cy, th), v0 = start(cx, tv);
    int h_end = th ? h0 + th : cy + 1, v_end = tv ? v0 + tv : cx + 1;
    int h_top = th ? h0 : cy, v_left = tv ? v0 : cx;
    if (up)
        rect(rgba, stride, start(cx, up * thickness), 0, start(cx, up * thickness) + up * thickness,
             h_end);
    if (down)
        rect(rgba, stride, start(cx, down * thickness), h_top,
             start(cx, down * thickness) + down * thickness, h);
    if (left)
        rect(rgba, stride, 0, start(cy, left * thickness), v_end,
             start(cy, left * thickness) + left * thickness);
    if (right)
        rect(rgba, stride, v_left, start(cy, right * thickness), w,
             start(cy, right * thickness) + right * thickness);
}

// ╭ ╮ ╯ ╰: a quarter circle joining two arms, with a straight piece to
// reach the cell's edge along the longer side.
static void arc(uint32_t cp, int w, int h, int thickness, uint8_t *rgba, size_t stride) {
    // The middle of the center pixel, where straight lines run.
    double cx = (double)(w / 2) + 0.5, cy = (double)(h / 2) + 0.5;
    // Which way the arms go: ╭ right and down, ╮ left and down, ╯ left and
    // up, ╰ right and up.
    int sx = (cp == 0x256D || cp == 0x2570) ? 1 : -1;
    int sy = (cp == 0x256D || cp == 0x256E) ? 1 : -1;
    double r = fmin(cx, cy) - 0.5;
    // The circle's center sits r away from the cell's center, diagonally
    // toward the two arms.
    double ox = cx + sx * r, oy = cy + sy * r;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            double px = x + 0.5, py = y + 0.5, d;
            bool in_x = (px - ox) * sx <= 0, in_y = (py - oy) * sy <= 0;
            if (in_x && in_y)
                d = fabs(hypot(px - ox, py - oy) - r); // the curve
            else if (!in_x && (py - cy) * sy >= -thickness)
                d = fabs(py - cy); // the arm toward the side
            else if (!in_y && (px - cx) * sx >= -thickness)
                d = fabs(px - cx); // the arm toward the top or bottom
            else
                continue;
            uint8_t c = coverage(d, thickness);
            if (c)
                put(rgba, stride, x, y, c);
        }
}

// The solid powerline shapes, from Nerd Fonts' private use area: a
// triangle (U+E0B0 pointing right, U+E0B2 left) or a half ellipse (U+E0B4
// right, U+E0B6 left), flat against one side of the cell and as tall as
// it. They join colored blocks (prompts, the tab bar's powerline and
// rounded styles), so they must meet the blocks to the pixel, which a
// font's version rarely does.
static bool is_powerline(uint32_t cp) {
    return cp == 0xE0B0 || cp == 0xE0B2 || cp == 0xE0B4 || cp == 0xE0B6;
}

static void powerline(uint32_t cp, int w, int h, uint8_t *rgba, size_t stride) {
    bool round = cp == 0xE0B4 || cp == 0xE0B6;
    bool left = cp == 0xE0B2 || cp == 0xE0B6; // the flat side is on the right
    double half = h / 2.0;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            // The pixel's center, from the flat side: u from 0 to 1 across
            // the cell, v from -1 to 1 down it.
            double u = (left ? w - x - 0.5 : x + 0.5) / w, v = (y + 0.5 - half) / half;
            // How far inside the shape's edge it is, in pixels.
            double inside = round ? (1 - hypot(u, v)) * fmin(w, half)
                                  : ((1 - fabs(v)) - u) * w * half / hypot(w, half);
            // Anti-aliased over the one pixel the edge crosses.
            uint8_t c = inside >= 0.5    ? 255
                        : inside <= -0.5 ? 0
                                         : (uint8_t)((inside + 0.5) * 255);
            if (c)
                put(rgba, stride, x, y, c);
        }
}

// --- The password lock ---

// A padlock: a U-shaped shackle over a solid body with a keyhole. Drawn
// in place of the cursor while a program reads a password. Each pixel is
// sampled 4 x 4 times, so the round parts come out smooth at any cell size.
static bool in_lock(double x, double y, int w, int h, int thickness) {
    double body_left = 0.14 * w, body_right = 0.86 * w;
    double body_top = 0.48 * h, body_bottom = 0.86 * h;
    double cx = 0.5 * w, r = 0.25 * w;
    double t = fmax(thickness * 1.5, 0.12 * w); // the shackle's thickness
    double arc_y = body_top - 0.07 * h; // where the shackle's legs start to bend
    if (x >= body_left && x <= body_right && y >= body_top && y <= body_bottom) {
        // The keyhole: a hole the background shows through.
        double kx = (x - cx) / (0.09 * w), ky = (y - (body_top + 0.4 * (body_bottom - body_top))) / (0.09 * w);
        return kx * kx + ky * ky > 1;
    }
    if (y < body_top && y >= arc_y) // the two legs
        return fabs(fabs(x - cx) - r) <= t / 2;
    if (y < arc_y) // the round top
        return fabs(hypot(x - cx, y - arc_y) - r) <= t / 2;
    return false;
}

static void lock(int w, int h, int thickness, uint8_t *rgba, size_t stride) {
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            int hits = 0;
            for (int sy = 0; sy < 4; sy++)
                for (int sx = 0; sx < 4; sx++)
                    hits += in_lock(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4, w, h, thickness);
            if (hits)
                put(rgba, stride, x, y, (uint8_t)(hits * 255 / 16));
        }
}

bool sprite_has(uint32_t cp) {
    return (cp >= 0x2580 && cp <= 0x259F) ||
           (cp >= 0x2500 && cp <= 0x254B && box_arms[cp - 0x2500] != 0) ||
           (cp >= 0x2574 && cp <= 0x257F) || (cp >= 0x256D && cp <= 0x2570) || is_powerline(cp) ||
           cp == sprite_lock;
}

bool sprite_render(uint32_t cp, int cell_w, int cell_h, int thickness, uint8_t *rgba, size_t stride) {
    if (cp >= 0x2580 && cp <= 0x259F)
        return block(cp, cell_w, cell_h, rgba, stride);
    if (cp >= 0x2500 && cp <= 0x254B && box_arms[cp - 0x2500] != 0) {
        arms(box_arms[cp - 0x2500], cell_w, cell_h, thickness, rgba, stride);
        return true;
    }
    if (cp >= 0x2574 && cp <= 0x257F) {
        arms(half_arms[cp - 0x2574], cell_w, cell_h, thickness, rgba, stride);
        return true;
    }
    if (cp >= 0x256D && cp <= 0x2570) {
        arc(cp, cell_w, cell_h, thickness, rgba, stride);
        return true;
    }
    if (is_powerline(cp)) {
        powerline(cp, cell_w, cell_h, rgba, stride);
        return true;
    }
    if (cp == sprite_lock) {
        lock(cell_w, cell_h, thickness, rgba, stride);
        return true;
    }
    return false;
}

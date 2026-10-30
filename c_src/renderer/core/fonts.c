#define _GNU_SOURCE // for wcwidth(3)

#include "fonts.h"

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb-ft.h>
#include <hb.h>

#include <math.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

struct font {
    FT_Face face;
    hb_font_t *hb;
    char path[512];
    int index; // a face inside a font collection (.ttc)
    bool color; // has color glyphs: an emoji font
    // Bitmap-only fonts (Noto Color Emoji) come in one fixed size; what
    // they draw is scaled to the cell afterwards.
    bool scalable;
};

// --- UTF-8 ---

uint32_t utf8_next(const uint8_t *s, size_t len, size_t *i) {
    uint8_t c = s[(*i)++];
    if (c < 0x80)
        return c;
    int extra = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : -1;
    if (extra < 0 || c > 0xF4)
        return 0xFFFD;
    uint32_t cp = c & (0x3F >> extra);
    for (int k = 0; k < extra; k++) {
        if (*i >= len || (s[*i] & 0xC0) != 0x80)
            return 0xFFFD;
        cp = cp << 6 | (s[(*i)++] & 0x3F);
    }
    return cp;
}

size_t utf8_put(uint32_t cp, char out[4]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | cp >> 6);
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | cp >> 12);
        out[1] = (char)(0x80 | (cp >> 6 & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | cp >> 18);
    out[1] = (char)(0x80 | (cp >> 12 & 0x3F));
    out[2] = (char)(0x80 | (cp >> 6 & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

// --- Loading ---

[[nodiscard]] static struct font *load_font(struct fonts *f, const char *path, int index) {
    if (f->count == max_fonts || strlen(path) >= sizeof((struct font){}.path))
        return nullptr;
    FT_Face face;
    if (FT_New_Face(f->ft, path, index, &face) != 0) {
        fprintf(stderr, "renderer: can't open font %s\n", path);
        return nullptr;
    }
    bool scalable = FT_IS_SCALABLE(face);
    if (scalable) {
        if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)f->pixel_size) != 0)
            goto fail;
    } else {
        // Pick the fixed size closest to ours (emoji fonts usually have one).
        if (face->num_fixed_sizes == 0)
            goto fail;
        int best = 0;
        for (int i = 1; i < face->num_fixed_sizes; i++)
            if (abs(face->available_sizes[i].height - f->pixel_size) <
                abs(face->available_sizes[best].height - f->pixel_size))
                best = i;
        if (FT_Select_Size(face, best) != 0)
            goto fail;
    }
    struct font *font = calloc(1, sizeof *font);
    if (font == nullptr)
        goto fail;
    *font = (struct font){.face = face, .index = index, .color = FT_HAS_COLOR(face), .scalable = scalable};
    strcpy(font->path, path);
    // HarfBuzz reads the font through the FreeType face (and shares its size).
    font->hb = hb_ft_font_create_referenced(face);
    f->list[f->count++] = font;
    return font;
fail:
    FT_Done_Face(face);
    return nullptr;
}

static void free_font(struct font *font) {
    hb_font_destroy(font->hb); // drops HarfBuzz's reference to the face
    FT_Done_Face(font->face);
    free(font);
}

// Asks fontconfig for the best font for a pattern. With `cps`, it must
// have all those characters, and with `color` it should be an emoji font.
// Returns a font already loaded, a newly loaded one, or nullptr.
[[nodiscard]] static struct font *find_font(struct fonts *f, const uint32_t *cps, int ncps, bool color) {
    FcPattern *pattern = FcNameParse((const FcChar8 *)f->family);
    if (pattern == nullptr)
        return nullptr;
    FcCharSet *wanted = FcCharSetCreate();
    for (int i = 0; i < ncps; i++)
        FcCharSetAddChar(wanted, cps[i]);
    if (ncps > 0)
        FcPatternAddCharSet(pattern, FC_CHARSET, wanted);
    if (color)
        FcPatternAddBool(pattern, FC_COLOR, FcTrue);
    // Apply the user's config (aliases like monospace -> Source Code Pro)
    // and defaults, then rank every installed font against the pattern.
    FcConfigSubstitute(nullptr, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result;
    FcFontSet *set = FcFontSort(nullptr, pattern, FcFalse, nullptr, &result);

    struct font *found = nullptr;
    for (int i = 0; set != nullptr && i < set->nfont && found == nullptr; i++) {
        FcCharSet *has;
        FcChar8 *file;
        int index = 0;
        if (FcPatternGetString(set->fonts[i], FC_FILE, 0, &file) != FcResultMatch)
            continue;
        // The sort ranks by everything; it doesn't promise coverage.
        if (ncps > 0 && (FcPatternGetCharSet(set->fonts[i], FC_CHARSET, 0, &has) != FcResultMatch ||
                         FcCharSetIntersectCount(has, wanted) < (FcChar32)FcCharSetCount(wanted)))
            continue;
        FcPatternGetInteger(set->fonts[i], FC_INDEX, 0, &index);
        for (int k = 0; k < f->count; k++)
            if (strcmp(f->list[k]->path, (const char *)file) == 0 && f->list[k]->index == index)
                found = f->list[k];
        if (found == nullptr)
            found = load_font(f, (const char *)file, index);
    }
    if (set != nullptr)
        FcFontSetDestroy(set);
    FcCharSetDestroy(wanted);
    FcPatternDestroy(pattern);
    return found;
}

bool fonts_open(struct fonts *f, const char *family, int pixel_size) {
    *f = (struct fonts){.pixel_size = pixel_size};
    snprintf(f->family, sizeof f->family, "%s", family);
    FT_Library ft;
    if (!FcInit() || FT_Init_FreeType(&ft) != 0)
        return false;
    f->ft = ft;
    struct font *primary = find_font(f, nullptr, 0, false);
    if (primary == nullptr || !primary->scalable) {
        fprintf(stderr, "renderer: no usable font for \"%s\"\n", family);
        fonts_close(f);
        return false;
    }
    // The cell: as wide as an M, as tall as the font's ascender plus
    // descender. FreeType metrics are 26.6 fixed point: 64ths of a pixel.
    FT_Face face = primary->face;
    int ascender = (int)((face->size->metrics.ascender + 63) >> 6);
    int descender = (int)(face->size->metrics.descender >> 6); // negative
    if (FT_Load_Char(face, 'M', FT_LOAD_DEFAULT) != 0) {
        fonts_close(f);
        return false;
    }
    f->cell_w = (int)((face->glyph->advance.x + 32) >> 6);
    f->cell_h = ascender - descender;
    f->baseline = ascender;
    f->line_thickness = pixel_size >= 24 ? 2 : 1;
    if (f->cell_w <= 0 || f->cell_h <= 0) {
        fonts_close(f);
        return false;
    }
    return true;
}

void fonts_close(struct fonts *f) {
    for (int i = 0; i < f->count; i++)
        free_font(f->list[i]);
    f->count = 0;
    if (f->ft != nullptr)
        FT_Done_FreeType(f->ft);
    f->ft = nullptr;
    FcFini(); // releases fontconfig's caches, so sanitizers see no leaks
}

// --- Choosing a font for a cluster ---

// Joiners and variation selectors don't need a glyph of their own.
static bool invisible(uint32_t cp) {
    return cp == 0x200D || (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0xE0100 && cp <= 0xE01EF);
}

// Should this cluster be a color emoji? Yes with VS16 (U+FE0F), and for
// characters that are emoji by default: the emoji blocks, and the wide
// symbols around U+2300-U+2BFF (⌚, ⚡, ⭐).
static bool wants_color(const uint32_t *cps, int n) {
    for (int i = 0; i < n; i++)
        if (cps[i] == 0xFE0F)
            return true;
        else if (cps[i] == 0xFE0E)
            return false;
    uint32_t c = cps[0];
    return (c >= 0x1F000 && c <= 0x1FAFF) || (c >= 0x2300 && c < 0x2C00 && wcwidth((wchar_t)c) == 2);
}

static bool covers(const struct font *font, const uint32_t *cps, int n) {
    for (int i = 0; i < n; i++)
        if (!invisible(cps[i]) && FT_Get_Char_Index(font->face, cps[i]) == 0)
            return false;
    return true;
}

static bool known_missing(const struct fonts *f, uint32_t cp) {
    for (int i = 0; i < f->missing_count; i++)
        if (f->missing[i] == cp)
            return true;
    return false;
}

static struct font *font_for(struct fonts *f, const uint32_t *cps, int n) {
    bool color = wants_color(cps, n);
    // Fonts already open first: an emoji font for emoji, then any.
    for (int pass = color ? 0 : 1; pass < 2; pass++)
        for (int i = 0; i < f->count; i++)
            if ((pass == 1 || f->list[i]->color) && covers(f->list[i], cps, n))
                return f->list[i];
    if (known_missing(f, cps[0]))
        return nullptr;

    uint32_t visible[32];
    int nv = 0;
    for (int i = 0; i < n && nv < 32; i++)
        if (!invisible(cps[i]))
            visible[nv++] = cps[i];
    struct font *font = find_font(f, visible, nv, color);
    if (font == nullptr && color)
        font = find_font(f, visible, nv, false);
    if (font == nullptr && f->missing_count < max_missing)
        f->missing[f->missing_count++] = cps[0];
    return font;
}

// --- Drawing ---

// A scratch bitmap: premultiplied RGBA, with the baseline at `baseline`.
struct canvas {
    int w, h, baseline, origin_x;
    uint8_t *px;
};

// Composite a FreeType bitmap at (x, y), the top-left of the bitmap.
static void blit(struct canvas *c, const FT_Bitmap *bm, int x, int y) {
    for (unsigned row = 0; row < bm->rows; row++) {
        int cy = y + (int)row;
        if (cy < 0 || cy >= c->h)
            continue;
        const uint8_t *src = bm->buffer + (long)row * bm->pitch;
        for (unsigned col = 0; col < bm->width; col++) {
            int cx = x + (int)col;
            if (cx < 0 || cx >= c->w)
                continue;
            uint8_t s[4];
            if (bm->pixel_mode == FT_PIXEL_MODE_BGRA) {
                // FreeType's color bitmaps are premultiplied BGRA.
                s[0] = src[4 * col + 2];
                s[1] = src[4 * col + 1];
                s[2] = src[4 * col];
                s[3] = src[4 * col + 3];
            } else {
                uint8_t a = src[col];
                s[0] = s[1] = s[2] = s[3] = a; // white, premultiplied
            }
            // Porter-Duff "over" on premultiplied colors.
            uint8_t *d = c->px + ((size_t)cy * (size_t)c->w + (size_t)cx) * 4;
            for (int k = 0; k < 4; k++)
                d[k] = (uint8_t)(s[k] + d[k] * (255 - s[3]) / 255);
        }
    }
}

// Shape the cluster and draw its glyphs onto a canvas at the font's own
// size. Returns the pen advance in pixels, or -1.
static int draw_shaped(struct font *font, const char *utf8, size_t len, struct canvas *c, bool *color) {
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, utf8, (int)len, 0, (int)len);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font->hb, buf, nullptr, 0);
    unsigned n;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buf, &n);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, &n);

    // HarfBuzz positions are 26.6, like FreeType's.
    int pen = 0;
    FT_Int32 flags = FT_LOAD_RENDER | (font->color ? FT_LOAD_COLOR : FT_LOAD_TARGET_LIGHT);
    for (unsigned i = 0; i < n; i++) {
        if (FT_Load_Glyph(font->face, info[i].codepoint, flags) != 0)
            continue;
        FT_GlyphSlot g = font->face->glyph;
        if (g->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA)
            *color = true;
        int x = c->origin_x + (pen + pos[i].x_offset) / 64 + g->bitmap_left;
        int y = c->baseline - pos[i].y_offset / 64 - g->bitmap_top;
        blit(c, &g->bitmap, x, y);
        pen += pos[i].x_advance;
    }
    hb_buffer_destroy(buf);
    return pen / 64;
}

// Copy (or shrink) the canvas's content box into the cell area, as
// straight-alpha RGBA. Shrinking averages each block of source pixels.
static void place(const struct canvas *c, int src_x, int src_w, int dst_x, int dst_y, int dst_w,
                  int dst_h, int area_w, int area_h, uint8_t *rgba, size_t stride) {
    for (int y = 0; y < dst_h; y++) {
        int ay = dst_y + y;
        if (ay < 0 || ay >= area_h)
            continue;
        int sy0 = y * c->h / dst_h, sy1 = (y + 1) * c->h / dst_h;
        if (sy1 <= sy0)
            sy1 = sy0 + 1;
        for (int x = 0; x < dst_w; x++) {
            int ax = dst_x + x;
            if (ax < 0 || ax >= area_w)
                continue;
            int sx0 = src_x + x * src_w / dst_w, sx1 = src_x + (x + 1) * src_w / dst_w;
            if (sx1 <= sx0)
                sx1 = sx0 + 1;
            unsigned sum[4] = {}, count = 0;
            for (int sy = sy0; sy < sy1 && sy < c->h; sy++)
                for (int sx = sx0; sx < sx1 && sx < c->w; sx++) {
                    const uint8_t *p = c->px + ((size_t)sy * (size_t)c->w + (size_t)sx) * 4;
                    for (int k = 0; k < 4; k++)
                        sum[k] += p[k];
                    count++;
                }
            if (count == 0 || sum[3] == 0)
                continue;
            uint8_t *d = rgba + (size_t)ay * stride + (size_t)ax * 4;
            // Un-premultiply: the backend blends with straight alpha.
            for (int k = 0; k < 3; k++) {
                unsigned v = sum[k] * 255 / sum[3];
                d[k] = (uint8_t)(v > 255 ? 255 : v);
            }
            d[3] = (uint8_t)(sum[3] / count);
        }
    }
}

// No font has it: a hollow box, so you can see something is there.
static void tofu(int area_w, int area_h, uint8_t *rgba, size_t stride) {
    int x0 = 2, y0 = area_h / 5, x1 = area_w - 3, y1 = area_h - area_h / 5;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++)
            if (x == x0 || x == x1 || y == y0 || y == y1)
                memset(rgba + (size_t)y * stride + (size_t)x * 4, 255, 4);
}

bool fonts_render(struct fonts *f, const char *utf8, size_t len, int width, uint8_t *rgba,
                  size_t stride) {
    int area_w = width * f->cell_w, area_h = f->cell_h;
    uint32_t cps[32];
    int n = 0;
    for (size_t i = 0; i < len && n < 32;)
        cps[n++] = utf8_next((const uint8_t *)utf8, len, &i);
    if (n == 0)
        return false;
    struct font *font = font_for(f, cps, n);
    if (font == nullptr) {
        tofu(area_w, area_h, rgba, stride);
        return false;
    }

    // Draw at the font's own size on a canvas with room around the pen
    // (glyphs can reach left of it, or past their advance).
    FT_Size_Metrics *m = &font->face->size->metrics;
    int ascender = (int)((m->ascender + 63) >> 6), descender = (int)(m->descender >> 6);
    int em = (int)(m->y_ppem > 0 ? m->y_ppem : (FT_UShort)f->pixel_size);
    struct canvas c = {.origin_x = em, .baseline = ascender};
    size_t bytes;
    c.w = 4 * em + area_w;
    c.h = ascender - descender;
    if (c.h <= 0 || ckd_mul(&bytes, (size_t)c.w * (size_t)c.h, (size_t)4))
        return false;
    c.px = calloc(bytes, 1);
    if (c.px == nullptr)
        return false;

    bool color = false;
    int advance = draw_shaped(font, utf8, len, &c, &color);
    if (advance <= 0)
        advance = area_w;

    if (font->scalable && advance <= area_w + area_w / 10) {
        // The usual case: same size as the cell's font. Center it in the
        // area (for the primary font's own glyphs that's no shift at all)
        // and line up the baselines.
        int dx = (area_w - advance) / 2 - c.origin_x;
        int dy = f->baseline - c.baseline;
        place(&c, 0, c.w, dx, dy, c.w, c.h, area_w, area_h, rgba, stride);
    } else {
        // Too big for the cell (an emoji bitmap, a very wide glyph): shrink
        // the advance box to fit, keeping its shape, centered.
        double scale = fmin((double)area_w / advance, (double)area_h / c.h);
        int dw = (int)lround(advance * scale), dh = (int)lround(c.h * scale);
        if (dw < 1 || dh < 1) {
            free(c.px);
            return color;
        }
        place(&c, c.origin_x, advance, (area_w - dw) / 2, (area_h - dh) / 2, dw, dh, area_w, area_h,
              rgba, stride);
    }
    free(c.px);
    return color;
}

#include "atlas.h"

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *font_find(const char *family) {
    if (!FcInit())
        return nullptr;
    char *path = nullptr;
    FcPattern *pattern = FcNameParse((const FcChar8 *)family);
    if (pattern != nullptr) {
        // Apply the user's config (aliases like monospace -> Source Code Pro)
        // and defaults, then pick the closest installed font.
        FcConfigSubstitute(nullptr, pattern, FcMatchPattern);
        FcDefaultSubstitute(pattern);
        FcResult result;
        FcPattern *match = FcFontMatch(nullptr, pattern, &result);
        FcChar8 *file;
        if (match != nullptr && FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch)
            path = strdup((const char *)file);
        if (match != nullptr)
            FcPatternDestroy(match);
        FcPatternDestroy(pattern);
    }
    FcFini(); // releases fontconfig's caches, so sanitizers see no leaks
    return path;
}

// Copy one rendered glyph into its cell, clipping anything that sticks out
// (some fonts draw slightly outside their advance).
static void blit(struct atlas *atlas, const FT_Bitmap *bm, int cell_x, int cell_y, int left, int top) {
    for (unsigned row = 0; row < bm->rows; row++) {
        int y = top + (int)row;
        if (y < 0 || y >= atlas->cell_h)
            continue;
        for (unsigned col = 0; col < bm->width; col++) {
            int x = left + (int)col;
            if (x < 0 || x >= atlas->cell_w)
                continue;
            uint8_t v = bm->buffer[(long)row * bm->pitch + col];
            atlas->pixels[(size_t)(cell_y + y) * (size_t)atlas->width + (size_t)(cell_x + x)] = v;
        }
    }
}

bool atlas_build(struct atlas *atlas, const char *font_path, int pixel_size) {
    *atlas = (struct atlas){};
    FT_Library lib;
    if (FT_Init_FreeType(&lib) != 0)
        return false;
    bool ok = false;
    FT_Face face;
    if (FT_New_Face(lib, font_path, 0, &face) != 0) {
        fprintf(stderr, "renderer: can't open font %s\n", font_path);
        goto done_lib;
    }
    if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)pixel_size) != 0)
        goto done_face;

    // FreeType metrics are 26.6 fixed point: 64ths of a pixel.
    int ascender = (int)((face->size->metrics.ascender + 63) >> 6);
    int descender = (int)(face->size->metrics.descender >> 6); // negative
    if (FT_Load_Char(face, 'M', FT_LOAD_DEFAULT) != 0)
        goto done_face;
    atlas->cell_w = (int)((face->glyph->advance.x + 32) >> 6);
    atlas->cell_h = ascender - descender;
    atlas->baseline = ascender;
    atlas->line_thickness = pixel_size >= 24 ? 2 : 1;

    int count = atlas_last_char - atlas_first_char + 1;
    int grid_rows = (count + atlas_grid_cols - 1) / atlas_grid_cols;
    size_t size;
    if (atlas->cell_w <= 0 || atlas->cell_h <= 0 ||
        ckd_mul(&atlas->width, atlas_grid_cols, atlas->cell_w) ||
        ckd_mul(&atlas->height, grid_rows, atlas->cell_h) ||
        ckd_mul(&size, (size_t)atlas->width, (size_t)atlas->height))
        goto done_face;
    atlas->pixels = calloc(size, 1);
    if (atlas->pixels == nullptr)
        goto done_face;

    for (int i = 0; i < count; i++) {
        if (FT_Load_Char(face, (FT_ULong)(atlas_first_char + i), FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT) != 0)
            continue; // missing glyph: leave the cell blank
        FT_GlyphSlot g = face->glyph;
        int cell_x = (i % atlas_grid_cols) * atlas->cell_w;
        int cell_y = (i / atlas_grid_cols) * atlas->cell_h;
        // bitmap_top is measured up from the baseline; the baseline sits
        // `ascender` pixels below the top of the cell.
        blit(atlas, &g->bitmap, cell_x, cell_y, g->bitmap_left, ascender - g->bitmap_top);
    }
    ok = true;

done_face:
    FT_Done_Face(face);
done_lib:
    FT_Done_FreeType(lib);
    if (!ok)
        atlas_free(atlas);
    return ok;
}

void atlas_free(struct atlas *atlas) {
    free(atlas->pixels);
    atlas->pixels = nullptr;
}

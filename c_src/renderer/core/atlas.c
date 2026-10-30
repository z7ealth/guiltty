#include "atlas.h"

#include <stdckdint.h>
#include <stdlib.h>
#include <string.h>

#include "protocol.h"
#include "sprites.h"

struct atlas_entry {
    uint32_t hash;
    uint16_t slot; // 0 = empty entry
    uint8_t width;
    bool color;
    uint8_t len;
    char text[max_cluster_bytes];
};

static void mark_dirty(struct atlas *a, int top, int bottom) {
    a->dirty_top = top < a->dirty_top ? top : a->dirty_top;
    a->dirty_bottom = bottom > a->dirty_bottom ? bottom : a->dirty_bottom;
}

bool atlas_init(struct atlas *a, const struct fonts *fonts) {
    *a = (struct atlas){
        .cell_w = fonts->cell_w,
        .cell_h = fonts->cell_h,
        .baseline = fonts->baseline,
        .line_thickness = fonts->line_thickness,
        .width = atlas_width_px,
    };
    a->slots_per_row = a->width / a->cell_w;
    if (a->slots_per_row < 2)
        return false;
    int rows = (int)((atlas_max_slots + (uint32_t)a->slots_per_row - 1) / (uint32_t)a->slots_per_row);
    if (rows > atlas_max_height_px / a->cell_h)
        rows = atlas_max_height_px / a->cell_h;
    size_t bytes;
    if (rows < 1 || ckd_mul(&a->height, rows, a->cell_h) ||
        ckd_mul(&bytes, (size_t)a->width * (size_t)a->height, (size_t)4))
        return false;
    a->slot_count = (uint32_t)rows * (uint32_t)a->slots_per_row;
    // Keep the table at most half full: probes stay short.
    a->entry_cap = 1;
    while (a->entry_cap < 2 * (size_t)a->slot_count)
        a->entry_cap *= 2;
    a->pixels = calloc(bytes, 1);
    a->entries = calloc(a->entry_cap, sizeof *a->entries);
    if (a->pixels == nullptr || a->entries == nullptr) {
        atlas_free(a);
        return false;
    }
    atlas_reset(a);
    return true;
}

void atlas_free(struct atlas *a) {
    free(a->pixels);
    free(a->entries);
    a->pixels = nullptr;
    a->entries = nullptr;
}

void atlas_reset(struct atlas *a) {
    memset(a->entries, 0, a->entry_cap * sizeof *a->entries);
    a->entry_count = 0;
    a->next_slot = 1;
    a->generation++;
    a->dirty_top = 0;
    a->dirty_bottom = a->height - 1;
}

void atlas_mark_clean(struct atlas *a) {
    a->dirty_top = a->height;
    a->dirty_bottom = -1;
}

// FNV-1a over the text and the width.
static uint32_t hash(const char *text, size_t len, int width) {
    uint32_t h = 2166136261u ^ (uint32_t)width;
    for (size_t i = 0; i < len; i++)
        h = (h ^ (uint8_t)text[i]) * 16777619u;
    return h;
}

bool atlas_lookup(struct atlas *a, struct fonts *fonts, const char *utf8, size_t len, int width,
                  uint16_t *slot, bool *color) {
    if (len > max_cluster_bytes)
        len = max_cluster_bytes;
    uint32_t h = hash(utf8, len, width);
    size_t mask = a->entry_cap - 1, i = h & mask;
    for (; a->entries[i].slot != 0; i = (i + 1) & mask) {
        struct atlas_entry *e = &a->entries[i];
        if (e->hash == h && e->width == width && e->len == len && memcmp(e->text, utf8, len) == 0) {
            *slot = e->slot;
            *color = e->color;
            return true;
        }
    }

    // New: find room. A wide glyph needs two slots in the same row.
    uint32_t s = a->next_slot;
    uint32_t col = s % (uint32_t)a->slots_per_row;
    if (col + (uint32_t)width > (uint32_t)a->slots_per_row)
        s += (uint32_t)a->slots_per_row - col;
    if (s + (uint32_t)width > a->slot_count || 2 * (a->entry_count + 1) > a->entry_cap)
        return false;
    a->next_slot = s + (uint32_t)width;

    int x = (int)(s % (uint32_t)a->slots_per_row) * a->cell_w;
    int y = (int)(s / (uint32_t)a->slots_per_row) * a->cell_h;
    size_t stride = (size_t)a->width * 4;
    uint8_t *area = a->pixels + (size_t)y * stride + (size_t)x * 4;
    for (int row = 0; row < a->cell_h; row++)
        memset(area + (size_t)row * stride, 0, (size_t)(width * a->cell_w) * 4);
    // Block elements and box lines are drawn, not taken from a font.
    size_t at = 0;
    uint32_t cp = utf8_next((const uint8_t *)utf8, len, &at);
    bool is_color = false;
    if (at != len || width != 1 ||
        !sprite_render(cp, a->cell_w, a->cell_h, a->line_thickness, area, stride))
        is_color = fonts_render(fonts, utf8, len, width, area, stride);
    mark_dirty(a, y, y + a->cell_h - 1);

    struct atlas_entry *e = &a->entries[i];
    *e = (struct atlas_entry){
        .hash = h, .slot = (uint16_t)s, .width = (uint8_t)width, .color = is_color, .len = (uint8_t)len};
    memcpy(e->text, utf8, len);
    a->entry_count++;
    *slot = e->slot;
    *color = is_color;
    return true;
}

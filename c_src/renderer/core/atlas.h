// The glyph atlas: one RGBA bitmap cut into cell-sized slots, filled as
// text arrives. Each distinct cluster is drawn once (by fonts.c) into one
// slot, or two side by side if it's wide; cells then just name a slot. It
// lives on the CPU; a backend uploads it as a texture.
//
// When it fills up, everything is thrown away (a new generation) and the
// cells on screen are looked up again.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "fonts.h"

constexpr int atlas_width_px = 2048;
constexpr int atlas_max_height_px = 4096;
constexpr uint32_t atlas_max_slots = 8192;

struct atlas_entry;

struct atlas {
    int cell_w, cell_h; // one slot, the size of a terminal cell
    int baseline, line_thickness;
    int width, height; // the whole bitmap, in pixels
    int slots_per_row;
    uint32_t slot_count; // slot 0 is always blank
    uint32_t next_slot;
    uint8_t *pixels; // width * height * 4 bytes: straight-alpha RGBA, row-major
    // Changes when the whole atlas was thrown away: re-upload everything.
    uint32_t generation;
    // Pixel rows changed since the last upload (none if top > bottom).
    int dirty_top, dirty_bottom;
    // The cache: cluster text and width -> slot (open addressing).
    struct atlas_entry *entries;
    size_t entry_cap, entry_count;
};

[[nodiscard]] bool atlas_init(struct atlas *atlas, const struct fonts *fonts);
void atlas_free(struct atlas *atlas);

// Forgets every glyph (keeps the bitmap's size).
void atlas_reset(struct atlas *atlas);

// Finds the slot of a cluster `width` cells wide, drawing it first if
// it's new. A wide cluster takes slots *slot and *slot + 1. Returns false
// when the atlas is full (then reset it and look everything up again).
[[nodiscard]] bool atlas_lookup(struct atlas *atlas, struct fonts *fonts, const char *utf8,
                                size_t len, int width, uint16_t *slot, bool *color);

void atlas_mark_clean(struct atlas *atlas);

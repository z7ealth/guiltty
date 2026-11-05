// Decoding the images programs show (Kitty graphics) into pixels a
// backend can upload. Everything here reads data that came, in the end,
// from a program in the terminal, maybe on another machine: every size is
// checked before anything is allocated.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

// Pixels ready to upload: width x height, RGBA, premultiplied alpha (each
// color already multiplied by its alpha, as the backends blend), top row
// first. Owned by the caller (free()).
struct pixels {
    uint32_t width, height;
    uint8_t *rgba;
};

// Decodes one IMAGE message's data. width and height are what Elixir
// read from the image (raw pixels must be exactly that many; a PNG
// brings its own). False if the data is broken or too big, with nothing
// to free.
[[nodiscard]] bool image_decode(enum image_format format, uint32_t width, uint32_t height, const uint8_t *data,
                                size_t len, struct pixels *out);

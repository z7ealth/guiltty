// Image decoding: raw RGB and RGBA, and PNG (libpng's "simplified API",
// png(3) and libpng-manual.txt section V).
//
// Why here and not in Elixir: decoders are the classic place for memory
// bugs, and the renderer is a separate OS process. A broken image can
// crash a window; it can't reach the BEAM, which holds every session.

#include "images.h"

#include <png.h>
#include <stdckdint.h>
#include <stdlib.h>
#include <string.h>

static uint8_t premultiply(uint8_t c, uint8_t a) { return (uint8_t)(((unsigned)c * a + 127) / 255); }

[[nodiscard]] static bool pixel_count(uint32_t w, uint32_t h, size_t *bytes) {
    return w > 0 && h > 0 && w <= max_image_side && h <= max_image_side &&
           !ckd_mul(bytes, (size_t)w * (size_t)h, (size_t)4);
}

[[nodiscard]] static bool decode_raw(bool alpha, uint32_t w, uint32_t h, const uint8_t *data, size_t len,
                                     struct pixels *out) {
    size_t bytes;
    if (!pixel_count(w, h, &bytes) || len != (bytes / 4) * (alpha ? 4 : 3))
        return false;
    uint8_t *rgba = malloc(bytes);
    if (rgba == nullptr)
        return false;
    for (size_t i = 0, n = bytes / 4; i < n; i++) {
        const uint8_t *s = data + i * (alpha ? 4 : 3);
        uint8_t a = alpha ? s[3] : 255;
        rgba[i * 4 + 0] = premultiply(s[0], a);
        rgba[i * 4 + 1] = premultiply(s[1], a);
        rgba[i * 4 + 2] = premultiply(s[2], a);
        rgba[i * 4 + 3] = a;
    }
    *out = (struct pixels){w, h, rgba};
    return true;
}

// The simplified API reads the header first, so the size is checked
// before anything big is allocated: a tiny PNG claiming to be 100000 x
// 100000 pixels stops here. libpng checks the rest (CRCs, zlib streams)
// and reports a broken file as a failed finish_read.
[[nodiscard]] static bool decode_png(const uint8_t *data, size_t len, struct pixels *out) {
    png_image image = {.version = PNG_IMAGE_VERSION};
    if (!png_image_begin_read_from_memory(&image, data, len))
        return false;
    size_t bytes;
    if (!pixel_count(image.width, image.height, &bytes)) {
        png_image_free(&image);
        return false;
    }
    image.format = PNG_FORMAT_RGBA;
    uint8_t *rgba = malloc(bytes);
    if (rgba == nullptr) {
        png_image_free(&image);
        return false;
    }
    if (!png_image_finish_read(&image, nullptr, rgba, 0, nullptr)) {
        png_image_free(&image);
        free(rgba);
        return false;
    }
    for (size_t i = 0; i < bytes; i += 4) {
        rgba[i + 0] = premultiply(rgba[i + 0], rgba[i + 3]);
        rgba[i + 1] = premultiply(rgba[i + 1], rgba[i + 3]);
        rgba[i + 2] = premultiply(rgba[i + 2], rgba[i + 3]);
    }
    *out = (struct pixels){image.width, image.height, rgba};
    return true;
}

bool image_decode(enum image_format format, uint32_t width, uint32_t height, const uint8_t *data, size_t len,
                  struct pixels *out) {
    switch (format) {
    case IMAGE_RGB:
        return decode_raw(false, width, height, data, len, out);
    case IMAGE_RGBA:
        return decode_raw(true, width, height, data, len, out);
    case IMAGE_PNG:
        return decode_png(data, len, out);
    }
    return false;
}

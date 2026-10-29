#include "protocol.h"

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

// Read exactly n bytes. Returns READ_EOF only if the stream ends before the
// first byte; ending in the middle is an error.
[[nodiscard]] static enum read_result read_exact(int fd, uint8_t *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0)
            return READ_ERROR;
        if (r == 0)
            return got == 0 ? READ_EOF : READ_ERROR;
        got += (size_t)r;
    }
    return READ_OK;
}

enum read_result proto_read(int fd, uint8_t **msg, uint32_t *len) {
    uint8_t header[frame_header_size];
    enum read_result res = read_exact(fd, header, sizeof header);
    if (res != READ_OK)
        return res;

    uint32_t n = (uint32_t)header[0] << 24 | (uint32_t)header[1] << 16 |
                 (uint32_t)header[2] << 8 | header[3];
    // The length comes from outside the process: never trust it.
    if (n == 0 || n > max_message_size)
        return READ_ERROR;

    uint8_t *buf = malloc(n);
    if (buf == nullptr)
        return READ_ERROR;
    if (read_exact(fd, buf, n) != READ_OK) {
        free(buf);
        return READ_ERROR;
    }
    *msg = buf;
    *len = n;
    return READ_OK;
}

[[nodiscard]] static bool write_exact(int fd, const uint8_t *buf, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, buf, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0)
            return false;
        buf += w;
        n -= (size_t)w;
    }
    return true;
}

bool proto_write(int fd, const uint8_t *msg, uint32_t len) {
    uint8_t header[frame_header_size];
    put_u32(header, len);
    return write_exact(fd, header, sizeof header) && write_exact(fd, msg, len);
}

bool rd_u8(struct reader *r, uint8_t *out) {
    if (r->left < 1)
        return false;
    *out = r->p[0];
    r->p += 1;
    r->left -= 1;
    return true;
}

bool rd_u16(struct reader *r, uint16_t *out) {
    if (r->left < 2)
        return false;
    *out = (uint16_t)(r->p[0] << 8 | r->p[1]);
    r->p += 2;
    r->left -= 2;
    return true;
}

bool rd_u32(struct reader *r, uint32_t *out) {
    if (r->left < 4)
        return false;
    *out = (uint32_t)r->p[0] << 24 | (uint32_t)r->p[1] << 16 | (uint32_t)r->p[2] << 8 | r->p[3];
    r->p += 4;
    r->left -= 4;
    return true;
}

bool rd_bytes(struct reader *r, size_t n, const uint8_t **out) {
    if (r->left < n)
        return false;
    *out = r->p;
    r->p += n;
    r->left -= n;
    return true;
}

void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

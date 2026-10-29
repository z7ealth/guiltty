// The port protocol between Guiltty.Window (Elixir) and the renderer.
//
// Every message is framed by the port's {:packet, 4}: a 4-byte big-endian
// length, then that many bytes. The first byte of a message is its tag. All
// integers are big-endian, which is what Elixir's binary syntax uses by
// default. Keep this file and lib/guiltty/window/protocol.ex in sync, and
// bump protocol_version on any change.
#pragma once

#include <stddef.h>
#include <stdint.h>

constexpr uint16_t protocol_version = 1;

// Largest message we accept; anything bigger is a protocol error.
constexpr uint32_t max_message_size = 1u << 20;

enum msg_tag : uint8_t {
    // renderer -> Elixir: u16 version, u8 name_len, name
    MSG_HELLO = 1,
    // Elixir -> renderer: u16 cols, u16 rows. Sent once, after the hello.
    MSG_SETUP = 2,
    // Elixir -> renderer: u16 cursor_row, u16 cursor_col, u16 count,
    // then count times: u16 row, u16 len, len bytes of cells
    MSG_ROWS = 3,
    // renderer -> Elixir: UTF-8 text typed by the user
    MSG_TEXT = 4,
    // renderer -> Elixir: u32 SDL keycode, u16 SDL modifiers
    MSG_KEY = 5,
};
static_assert(sizeof(enum msg_tag) == 1, "tags are one byte on the wire");

// Fixed-size parts of messages, in bytes.
constexpr size_t frame_header_size = sizeof(uint32_t);
constexpr size_t rows_header_size = sizeof(uint8_t) + 3 * sizeof(uint16_t);
constexpr size_t row_header_size = 2 * sizeof(uint16_t);
constexpr size_t key_message_size = sizeof(uint8_t) + sizeof(uint32_t) + sizeof(uint16_t);
static_assert(rows_header_size == 7);
static_assert(key_message_size == 7);

enum read_result { READ_OK, READ_EOF, READ_ERROR };

// Reads one framed message from fd. On READ_OK, *msg is malloc'd and owned
// by the caller.
[[nodiscard]] enum read_result proto_read(int fd, uint8_t **msg, uint32_t *len);

// Writes one framed message to fd.
[[nodiscard]] bool proto_write(int fd, const uint8_t *msg, uint32_t len);

// A cursor over a received message. Every get fails instead of reading past
// the end, so a short or malicious message can't overrun the buffer.
struct reader {
    const uint8_t *p;
    size_t left;
};

[[nodiscard]] bool rd_u8(struct reader *r, uint8_t *out);
[[nodiscard]] bool rd_u16(struct reader *r, uint16_t *out);
[[nodiscard]] bool rd_bytes(struct reader *r, size_t n, const uint8_t **out);

void put_u16(uint8_t *p, uint16_t v);
void put_u32(uint8_t *p, uint32_t v);

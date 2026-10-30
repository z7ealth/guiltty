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

constexpr uint16_t protocol_version = 9;

// Largest message we accept; anything bigger is a protocol error.
constexpr uint32_t max_message_size = 1u << 24;

enum msg_tag : uint8_t {
    // renderer -> Elixir: u16 version, u8 name_len, name
    MSG_HELLO = 1,
    // Elixir -> renderer, once after the hello: u16 cols, u16 rows, then
    // 259 colors of 3 bytes (r, g, b): the 256-color palette, then the
    // default foreground, default background and cursor; then the window
    // options (as in MSG_OPTIONS); then the font: u16 pixel size and the
    // family name (the rest of the message).
    MSG_SETUP = 2,
    // Elixir -> renderer: u16 cols, u16 rows (the grid this describes),
    // u16 cursor_row, u16 cursor_col, u8 cursor_visible, u8 cursor_style
    // (bits 0-1: enum cursor_shape, bit 2: blinking); u16 nclusters, then
    // nclusters times: u32 id, u8 len, len bytes of UTF-8 (the clusters
    // these rows use that weren't sent before); u16 count, then count
    // times: u16 row, then cols cells of wire_cell_size bytes.
    MSG_ROWS = 3,
    // renderer -> Elixir: UTF-8 text typed by the user
    MSG_TEXT = 4,
    // renderer -> Elixir: u32 SDL keycode, u16 SDL modifiers
    MSG_KEY = 5,
    // renderer -> Elixir: u16 cols, u16 rows that now fit the window
    MSG_RESIZE = 6,
    // Elixir -> renderer: the window title, UTF-8
    MSG_TITLE = 7,
    // renderer -> Elixir: text pasted from the clipboard, UTF-8
    MSG_PASTE = 8,
    // renderer -> Elixir: u8 kind (mouse_kind), u8 button (0 left, 1 middle,
    // 2 right, 3 none; for the wheel 0 up, 1 down), u16 col, u16 row (cells,
    // 0-based), u16 SDL modifiers, u8 clicks (2 = double click, 3 = triple)
    MSG_MOUSE = 9,
    // Elixir -> renderer: a new theme, the same 259 colors as the setup
    MSG_THEME = 10,
    // Elixir -> renderer: a new font, u16 pixel size then the family name
    MSG_FONT = 11,
    // Elixir -> renderer: the tab bar: u8 active index, u8 count, then each
    // title as u8 length + UTF-8 bytes
    MSG_TABS = 12,
    // Elixir -> renderer: flash the window's border: u8 r, g, b, u16 ms
    MSG_HALO = 13,
    // Elixir -> renderer: bring the window to the front
    MSG_RAISE = 14,
    // renderer -> Elixir: drew a frame for the last ROWS: u32 microseconds
    MSG_FRAME = 15,
    // renderer -> Elixir: the user clicked a tab: u8 index
    MSG_TAB_CLICK = 16,
    // Elixir -> renderer: status for the right of the tab bar: u8 style
    // (0 normal, 1 warning), then UTF-8 text (empty hides it)
    MSG_STATUS = 17,
    // Elixir -> renderer: u8 target (0 clipboard, 1 primary selection),
    // then the text to put there, UTF-8
    MSG_CLIPBOARD = 18,
    // Elixir -> renderer: paste the primary selection (answered with a PASTE)
    MSG_PASTE_PRIMARY = 19,
    // Elixir -> renderer: window options: u16 padding (pixels at scale 1),
    // u8 background opacity (percent), u8 flags (option_flag)
    MSG_OPTIONS = 20,
    // Elixir -> renderer: open a URL with the desktop's app for it, UTF-8
    MSG_OPEN_URL = 21,
};
enum cursor_shape : uint8_t { CURSOR_BLOCK = 0, CURSOR_UNDERLINE = 1, CURSOR_BAR = 2, CURSOR_HOLLOW = 3 };
constexpr uint8_t cursor_blinks = 0x04;
enum option_flag : uint8_t {
    OPTION_BOLD_IS_BRIGHT = 0x01,
    OPTION_TAB_BAR_BOTTOM = 0x02,
    OPTION_LIGATURES = 0x04,
};
constexpr size_t options_size = sizeof(uint16_t) + 2;
enum mouse_kind : uint8_t { MOUSE_PRESS = 0, MOUSE_RELEASE = 1, MOUSE_MOTION = 2, MOUSE_WHEEL = 3 };
static_assert(sizeof(enum msg_tag) == 1, "tags are one byte on the wire");

// One cell on the wire, exactly as Guiltty.Grid stores it:
// u32 glyph, u16 attrs, u32 fg, u32 bg. The glyph is a codepoint, a
// cluster id (first_cluster and up, defined in a ROWS message), or 0 in
// the right half of a wide character. A color's top byte says how to read
// the rest: 0 = default, 1 = palette index in the low byte, 2 = 0xRRGGBB.
constexpr size_t wire_cell_size = 14;
constexpr uint32_t first_cluster = 0x110000;
constexpr uint32_t max_clusters = 65536;
constexpr size_t max_cluster_bytes = 64;
enum color_kind : uint8_t { COLOR_DEFAULT = 0, COLOR_INDEXED = 1, COLOR_RGB = 2 };

constexpr size_t palette_size = 256;
constexpr size_t setup_colors = palette_size + 3;

// Fixed-size parts of messages, in bytes.
constexpr size_t frame_header_size = sizeof(uint32_t);
constexpr size_t theme_size = 3 * setup_colors;
constexpr size_t setup_fixed_size =
    1 + 2 * sizeof(uint16_t) + theme_size + options_size + sizeof(uint16_t);
// Up to the cluster count; the row count follows the clusters.
constexpr size_t rows_header_size = 1 + 4 * sizeof(uint16_t) + 2 + sizeof(uint16_t);
constexpr size_t key_message_size = 1 + sizeof(uint32_t) + sizeof(uint16_t);
constexpr size_t resize_message_size = 1 + 2 * sizeof(uint16_t);
constexpr size_t mouse_message_size = 1 + 2 + 3 * sizeof(uint16_t) + 1;
static_assert(mouse_message_size == 10);
static_assert(setup_fixed_size == 788);
static_assert(rows_header_size == 13);
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
[[nodiscard]] bool rd_u32(struct reader *r, uint32_t *out);
[[nodiscard]] bool rd_bytes(struct reader *r, size_t n, const uint8_t **out);

void put_u16(uint8_t *p, uint16_t v);
void put_u32(uint8_t *p, uint32_t v);

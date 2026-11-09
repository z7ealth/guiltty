// text_nif: turns printed text into grid cells, the hot path of `cat`.
// Splitting text into grapheme clusters and looking up each one's width,
// one at a time in Elixir, was nine tenths of the time a big `cat` took
// (book chapter 22). Most text needs neither: two codepoints whose
// grapheme break property is "Other" are always two clusters (UAX #29,
// rule GB999). So C turns runs of those straight into cells, and hands
// whatever might join (combining marks, ZWJ sequences, flags, Hangul jamo)
// back to Elixir as text, for String.graphemes/1.
//
// Three smaller helpers replace loops that cost one Elixir step per byte:
// finding where a run of text ends (the parser), whether text is ASCII,
// and ASCII text as cells (the grid).
//
// Pure functions: no state, no resources, no syscalls. They run on a
// normal scheduler: their input is at most one read from the PTY (64 KB),
// at most about 0.4 ms of work, under the 1 ms a NIF may hold a scheduler.
//
// Read: UAX #29 "Unicode Text Segmentation" (the grapheme cluster rules),
// RFC 3629 (UTF-8), and erl_nif(3): enif_make_new_binary,
// enif_make_sub_binary, enif_consume_timeslice.

#include <erl_nif.h>

#include <stdckdint.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "text_table.h"

// A cell, as Guiltty.Grid lays it out: <<glyph::32, attrs::16, fg::32,
// bg::32>>, big-endian.
constexpr size_t cell_size = 14;
constexpr uint16_t attr_wide = 0x100;
constexpr uint16_t attr_spacer = 0x200;

// The input bytes per 1% of a timeslice (about 10 µs): 64 KB of mixed
// text took 0.41 ms on a Ryzen 5 5600. Only a hint to the scheduler.
constexpr size_t bytes_per_percent = 1600;

static enum cp_class classify(uint32_t cp)
{
    // Printable ASCII is nearly all of most output: skip the search.
    if (cp >= 0x20 && cp < 0x7F)
        return cp_narrow;

    size_t lo = 0;
    size_t hi = sizeof cp_ranges / sizeof cp_ranges[0];
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (cp < cp_ranges[mid].lo)
            hi = mid;
        else if (cp > cp_ranges[mid].hi)
            lo = mid + 1;
        else
            return cp_ranges[mid].class;
    }
    return cp_narrow;
}

// Decodes the UTF-8 character at s (n > 0 bytes left) into *cp. Returns
// its length, or 0 if it isn't valid UTF-8: truncated, an overlong form,
// a surrogate or past U+10FFFF (RFC 3629, section 4).
static size_t utf8_decode(const unsigned char *s, size_t n, uint32_t *cp)
{
    unsigned char b = s[0];
    size_t len;
    uint32_t min;

    if (b < 0x80) {
        *cp = b;
        return 1;
    } else if (b >= 0xC2 && b <= 0xDF) {
        len = 2, min = 0x80, *cp = b & 0x1F;
    } else if (b >= 0xE0 && b <= 0xEF) {
        len = 3, min = 0x800, *cp = b & 0x0F;
    } else if (b >= 0xF0 && b <= 0xF4) {
        len = 4, min = 0x10000, *cp = b & 0x07;
    } else {
        return 0;
    }

    if (n < len)
        return 0;
    for (size_t i = 1; i < len; i++) {
        if ((s[i] & 0xC0) != 0x80)
            return 0;
        *cp = (*cp << 6) | (s[i] & 0x3F);
    }
    if (*cp < min || *cp > 0x10FFFF || (*cp >= 0xD800 && *cp <= 0xDFFF))
        return 0;
    return len;
}

static unsigned char *put32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
    return p + 4;
}

static unsigned char *put_cell(unsigned char *p, uint32_t glyph, uint16_t attrs, uint32_t fg,
                               uint32_t bg)
{
    p = put32(p, glyph);
    p[0] = (unsigned char)(attrs >> 8);
    p[1] = (unsigned char)attrs;
    return put32(put32(p + 2, fg), bg);
}

// The pen new text is written in: attrs (16 bits) and two colors.
[[nodiscard]] static bool get_pen(ErlNifEnv *env, const ERL_NIF_TERM argv[], uint16_t *attrs,
                                  uint32_t *fg, uint32_t *bg)
{
    unsigned int a, f, b;
    if (!enif_get_uint(env, argv[0], &a) || a > UINT16_MAX || !enif_get_uint(env, argv[1], &f) ||
        !enif_get_uint(env, argv[2], &b))
        return false;
    *attrs = (uint16_t)a, *fg = f, *bg = b;
    return true;
}

struct out {
    ErlNifEnv *env;
    ERL_NIF_TERM text;   // the input, for sub-binaries of the complex runs
    ERL_NIF_TERM list;   // segments so far, newest first
    unsigned char *cells; // the current run of cells, built here
    unsigned char *end;   // where the next cell goes
};

static void close_cells(struct out *o)
{
    size_t size = (size_t)(o->end - o->cells);
    if (size == 0)
        return;
    ERL_NIF_TERM bin;
    memcpy(enif_make_new_binary(o->env, size, &bin), o->cells, size);
    ERL_NIF_TERM seg = enif_make_tuple2(o->env, bin, enif_make_uint64(o->env, size / cell_size));
    o->list = enif_make_list_cell(o->env, seg, o->list);
    o->end = o->cells;
}

static void add_complex(struct out *o, size_t from, size_t to)
{
    ERL_NIF_TERM seg = enif_make_sub_binary(o->env, o->text, from, to - from);
    o->list = enif_make_list_cell(o->env, seg, o->list);
}

// segments(text, attrs, fg, bg) -> [{cells, cols} | text]
//
// A codepoint becomes a cell when it and both its neighbours are narrow
// or wide: then nothing can join it on either side. The rest come back
// as sub-binaries of the input, cut between two simple codepoints, where
// UAX #29 always breaks, so segmenting them alone gives the same clusters
// as segmenting the whole text. (The first codepoint's neighbour is the
// last cluster printed; Grid checks that one before calling.)
static ERL_NIF_TERM segments(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary text;
    uint16_t attrs;
    uint32_t fg, bg;
    if (!enif_inspect_binary(env, argv[0], &text) || !get_pen(env, argv + 1, &attrs, &fg, &bg))
        return enif_make_badarg(env);

    // A UTF-8 character of n bytes makes at most n cells: one byte, one
    // narrow cell; a wide character (two cells) takes three bytes or four.
    size_t max_cells;
    if (ckd_mul(&max_cells, text.size, cell_size))
        return enif_make_badarg(env);

    struct out o = {.env = env, .text = argv[0], .list = enif_make_list(env, 0)};
    o.cells = enif_alloc(max_cells > 0 ? max_cells : 1);
    if (o.cells == nullptr)
        return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    o.end = o.cells;

    const unsigned char *s = text.data;
    size_t n = text.size;
    size_t pos = 0;           // the current codepoint
    size_t complex_from = 0;  // start of the complex run, if in one
    bool in_complex = false;
    bool prev_simple = true;  // see "the first codepoint's neighbour" above

    uint32_t cp = 0;
    size_t len = n > 0 ? utf8_decode(s, n, &cp) : 0;
    if (n > 0 && len == 0)
        goto invalid;
    enum cp_class class = classify(cp);

    while (pos < n) {
        size_t next = pos + len;
        uint32_t next_cp = 0;
        size_t next_len = 0;
        if (next < n && (next_len = utf8_decode(s + next, n - next, &next_cp)) == 0)
            goto invalid;

        // Each codepoint is looked up once: as the next one, then kept.
        enum cp_class next_class = next < n ? classify(next_cp) : cp_narrow;
        bool simple = class != cp_complex;
        bool next_simple = next_class != cp_complex;

        if (simple && prev_simple && next_simple) {
            if (in_complex) {
                add_complex(&o, complex_from, pos);
                in_complex = false;
            }
            if (class == cp_wide) {
                o.end = put_cell(o.end, cp, (uint16_t)(attrs | attr_wide), fg, bg);
                o.end = put_cell(o.end, 0, (uint16_t)(attrs | attr_spacer), fg, bg);
            } else {
                o.end = put_cell(o.end, cp, (uint16_t)attrs, fg, bg);
            }
        } else if (!in_complex) {
            close_cells(&o);
            complex_from = pos;
            in_complex = true;
        }

        prev_simple = simple;
        pos = next, cp = next_cp, len = next_len, class = next_class;
    }

    if (in_complex)
        add_complex(&o, complex_from, n);
    else
        close_cells(&o);
    enif_free(o.cells);

    int percent = (int)(text.size / bytes_per_percent);
    enif_consume_timeslice(env, percent > 100 ? 100 : percent);

    ERL_NIF_TERM result;
    enif_make_reverse_list(env, o.list, &result);
    return result;

invalid:
    enif_free(o.cells);
    return enif_make_badarg(env);
}

// text_run(bytes) -> n: how many bytes at the start may be text, for the
// parser's ground state: printable ASCII and any byte >= 0x80 (UTF-8 is
// checked after). It stops at a C0 control, DEL, or a C1 control in UTF-8
// (U+0080 to U+009F: 0xC2 then 0x80 to 0x9F), which is an escape sequence and
// not text. Like the two below, a plain scan: 64 KB is a few microseconds,
// too little to report.
static ERL_NIF_TERM text_run(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    size_t n = 0;
    while (n < bin.size && bin.data[n] >= 0x20 && bin.data[n] != 0x7F) {
        if (bin.data[n] == 0xC2 && n + 1 < bin.size && bin.data[n + 1] >= 0x80 && bin.data[n + 1] <= 0x9F)
            break;
        n++;
    }
    return enif_make_uint64(env, n);
}

// ascii?(bytes) -> true when no byte is >= 0x80.
static ERL_NIF_TERM ascii(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    for (size_t i = 0; i < bin.size; i++)
        if (bin.data[i] >= 0x80)
            return enif_make_atom(env, "false");
    return enif_make_atom(env, "true");
}

// ascii_cells(text, attrs, fg, bg) -> cells: one narrow cell per byte, in
// the pen. The caller has checked the text is ASCII.
static ERL_NIF_TERM ascii_cells(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary text;
    uint16_t attrs;
    uint32_t fg, bg;
    size_t size;
    if (!enif_inspect_binary(env, argv[0], &text) || !get_pen(env, argv + 1, &attrs, &fg, &bg) ||
        ckd_mul(&size, text.size, cell_size))
        return enif_make_badarg(env);

    ERL_NIF_TERM cells;
    unsigned char *p = enif_make_new_binary(env, size, &cells);
    if (p == nullptr)
        return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    for (size_t i = 0; i < text.size; i++)
        p = put_cell(p, text.data[i], attrs, fg, bg);
    return cells;
}

static ErlNifFunc funcs[] = {
    {"segments", 4, segments, 0},
    {"text_run", 1, text_run, 0},
    {"ascii?", 1, ascii, 0},
    {"ascii_cells", 4, ascii_cells, 0},
};

ERL_NIF_INIT(Elixir.Guiltty.TextNif, funcs, nullptr, nullptr, nullptr, nullptr)

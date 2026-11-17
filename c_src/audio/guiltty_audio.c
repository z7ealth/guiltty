// guiltty_audio: listens to what the speakers are playing and says how
// loud each band of frequencies is, about 30 times a second. Guiltty.Audio
// runs it behind an Erlang port when the `visualizer` setting is on, and
// every window draws the bands in its tab bar. Book chapter 30.
//
//   guiltty_audio              record and send LEVELS on stdout, framed
//                              like {:packet, 4}, until stdin closes
//   guiltty_audio --print      record and draw the bands in this
//                              terminal, to try it (Ctrl+C ends it)
//   guiltty_audio --raw FILE   analyze FILE instead of recording: 32-bit
//                              float samples, stereo, 48 kHz (the tests)
//
// It records the default output's *monitor*: PipeWire hands a capture
// stream the sound a sink plays when the stream asks for it
// (stream.capture.sink). Nothing is recorded from a microphone.
//
// PipeWire is loaded with dlopen(3) instead of being linked: the
// precompiled release must start on a machine without it (it then has
// no visualizer, and says so), the way SDL loads PulseAudio or PipeWire.
//
// Messages (big-endian, after the 4-byte length; keep in sync with
// lib/guiltty/audio.ex):
//
//   HELLO   u8 1, u16 version
//   LEVELS  u8 2, u8 count, count bytes 0..255 (lowest band first)
//
// Exit status: 0 stdin closed, 2 no PipeWire library, 3 PipeWire is
// there but wouldn't record (no daemon, no output), 64 bad arguments.
//
// Read: dlopen(3), dlsym(3), timerfd_create(2) (the idle timer), the
// PipeWire stream API (pw_stream,
// docs.pipewire.org "Tutorial 4", audio-capture.c), the Hann window and
// the radix-2 FFT (any DSP text; "Understanding DSP", Lyons, ch. 3-4).

// For locale_t, which the PipeWire headers use, under -std=c23.
#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Only for types, constants and the header-only parts (the spa pod
// builder, the pw_loop inline calls): every function that lives in
// libpipewire is called through the pointers dlsym filled in. Linking
// doesn't add the library, so calling one directly fails to link.
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

constexpr uint16_t audio_version = 1;
enum audio_tag : uint8_t { AUDIO_HELLO = 1, AUDIO_LEVELS = 2 };

constexpr uint32_t sample_rate = 48'000;
constexpr int channels = 2;
// 2048 samples is 43 ms of sound, and bins 23.4 Hz apart: enough to tell
// the bass bands apart. A new analysis every 1600 samples is 30 a second.
constexpr size_t fft_size = 2048;
constexpr size_t hop = sample_rate / 30;
constexpr int band_count = 16; // @bands in lib/guiltty/audio.ex
constexpr float lowest_hz = 50.0f;
constexpr float highest_hz = 16'000.0f;
// Loudness to bar height: below floor_db is an empty bar, ceiling_db a
// full one. A band's level falls by at most fall_per_frame (of a full
// bar) each frame, so bars sink smoothly instead of flickering.
constexpr float floor_db = -62.0f;
constexpr float ceiling_db = -12.0f;
constexpr float fall_per_frame = 1.0f / 10;
// No samples for this long while the bars are up means the sound stopped
// (paused, or its stream closed): PipeWire then sends nothing at all, not
// even silence, and the bars would stay where they were.
constexpr int64_t stalled_ns = 150'000'000;

static_assert((fft_size & (fft_size - 1)) == 0, "radix-2: a power of two");
static_assert(hop <= fft_size);

// --- PipeWire, loaded at run time ---

static struct {
    typeof(pw_init) *init;
    typeof(pw_deinit) *deinit;
    typeof(pw_properties_new) *properties_new;
    typeof(pw_thread_loop_new) *thread_loop_new;
    typeof(pw_thread_loop_get_loop) *thread_loop_get_loop;
    typeof(pw_thread_loop_start) *thread_loop_start;
    typeof(pw_thread_loop_stop) *thread_loop_stop;
    typeof(pw_thread_loop_destroy) *thread_loop_destroy;
    typeof(pw_thread_loop_lock) *thread_loop_lock;
    typeof(pw_thread_loop_unlock) *thread_loop_unlock;
    typeof(pw_stream_new_simple) *stream_new_simple;
    typeof(pw_stream_connect) *stream_connect;
    typeof(pw_stream_destroy) *stream_destroy;
    typeof(pw_stream_dequeue_buffer) *stream_dequeue_buffer;
    typeof(pw_stream_queue_buffer) *stream_queue_buffer;
} pw;

// Fills `pw` from the library. The soname is the ABI's: libpipewire
// 0.3 and every 1.x are libpipewire-0.3.so.0.
[[nodiscard]] static void *load_pipewire(void) {
    void *lib = dlopen("libpipewire-0.3.so.0", RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr)
        return nullptr;
    struct {
        void **slot;
        const char *name;
    } syms[] = {
        {(void **)&pw.init, "pw_init"},
        {(void **)&pw.deinit, "pw_deinit"},
        {(void **)&pw.properties_new, "pw_properties_new"},
        {(void **)&pw.thread_loop_new, "pw_thread_loop_new"},
        {(void **)&pw.thread_loop_get_loop, "pw_thread_loop_get_loop"},
        {(void **)&pw.thread_loop_start, "pw_thread_loop_start"},
        {(void **)&pw.thread_loop_stop, "pw_thread_loop_stop"},
        {(void **)&pw.thread_loop_destroy, "pw_thread_loop_destroy"},
        {(void **)&pw.thread_loop_lock, "pw_thread_loop_lock"},
        {(void **)&pw.thread_loop_unlock, "pw_thread_loop_unlock"},
        {(void **)&pw.stream_new_simple, "pw_stream_new_simple"},
        {(void **)&pw.stream_connect, "pw_stream_connect"},
        {(void **)&pw.stream_destroy, "pw_stream_destroy"},
        {(void **)&pw.stream_dequeue_buffer, "pw_stream_dequeue_buffer"},
        {(void **)&pw.stream_queue_buffer, "pw_stream_queue_buffer"},
    };
    for (size_t i = 0; i < sizeof syms / sizeof syms[0]; i++) {
        // dlsym returns a void *; POSIX promises it converts to a function
        // pointer, which ISO C alone doesn't.
        *syms[i].slot = dlsym(lib, syms[i].name);
        if (*syms[i].slot == nullptr) {
            fprintf(stderr, "guiltty_audio: libpipewire has no %s\n", syms[i].name);
            dlclose(lib);
            return nullptr;
        }
    }
    return lib;
}

// --- Output ---

static bool print_mode;

[[nodiscard]] static bool write_all(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            return false;
        p += w;
        n -= (size_t)w;
    }
    return true;
}

// One message, framed the way {:packet, 4} reads it: a big-endian
// length, then the body.
[[nodiscard]] static bool send_message(const uint8_t *body, uint32_t len) {
    uint8_t head[4] = {len >> 24, len >> 16 & 0xFF, len >> 8 & 0xFF, len & 0xFF};
    return write_all(STDOUT_FILENO, head, 4) && write_all(STDOUT_FILENO, body, len);
}

[[nodiscard]] static bool send_levels(const uint8_t levels[band_count]) {
    if (print_mode) {
        // One line redrawn in place (\r): the bands as block characters.
        static const char *const blocks[] = {" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"};
        char line[band_count * 8 + 8] = "\r";
        for (int i = 0; i < band_count; i++) {
            strcat(line, blocks[levels[i] * 9 / 256]);
            strcat(line, blocks[levels[i] * 9 / 256]);
        }
        fputs(line, stdout);
        return fflush(stdout) == 0;
    }
    uint8_t msg[2 + band_count] = {AUDIO_LEVELS, band_count};
    memcpy(msg + 2, levels, band_count);
    return send_message(msg, sizeof msg);
}

// --- Analysis ---
//
// Samples go into a ring of the last fft_size. Every `hop` new ones, the
// ring is windowed, transformed and summed into bands.

static struct {
    float ring[fft_size];
    size_t at; // where the next sample goes
    size_t since; // samples since the last analysis
    float cos_table[fft_size / 2], sin_table[fft_size / 2];
    float window[fft_size];
    int band_lo[band_count], band_hi[band_count]; // FFT bins, [lo, hi)
    float tilt_db[band_count];
    float shown[band_count]; // 0..1, after the fall
    bool silent; // the last LEVELS sent was all zero: send none until sound
} an;

static void analysis_init(void) {
    constexpr float pi = 3.14159265358979323846f;
    for (size_t k = 0; k < fft_size / 2; k++) {
        an.cos_table[k] = cosf(2 * pi * (float)k / fft_size);
        an.sin_table[k] = sinf(2 * pi * (float)k / fft_size);
    }
    // The Hann window: fades the slice in and out, so its edges don't
    // show up as a burst of every frequency (spectral leakage).
    for (size_t i = 0; i < fft_size; i++)
        an.window[i] = 0.5f - 0.5f * cosf(2 * pi * (float)i / (fft_size - 1));
    // Bands spaced evenly in octaves (log), as ears hear them: 50 Hz to
    // 16 kHz in 16 steps is about 0.52 octave each.
    float hz_per_bin = (float)sample_rate / fft_size;
    for (int b = 0; b < band_count; b++) {
        float lo = lowest_hz * powf(highest_hz / lowest_hz, (float)b / band_count);
        float hi = lowest_hz * powf(highest_hz / lowest_hz, (float)(b + 1) / band_count);
        // Bin k is the frequency k * hz_per_bin: the band has the bins
        // with lo <= that < hi.
        an.band_lo[b] = (int)ceilf(lo / hz_per_bin);
        an.band_hi[b] = (int)ceilf(hi / hz_per_bin);
        if (an.band_hi[b] <= an.band_lo[b])
            an.band_hi[b] = an.band_lo[b] + 1;
        // Music has less energy per Hz the higher it goes (about 3 dB less
        // each octave): lift the high bands and lower the bass so a song's
        // bars come out level instead of sloping down to the right.
        an.tilt_db[b] = 3.0f * log2f(sqrtf(lo * hi) / 1000.0f);
    }
    an.silent = true;
}

// In-place radix-2 FFT (Cooley-Tukey): reorder by bit-reversed index,
// then log2(n) passes of butterflies, each combining pairs of half-size
// transforms. O(n log n) instead of the O(n^2) of the plain sum.
static void fft(float re[fft_size], float im[fft_size]) {
    for (size_t i = 1, j = 0; i < fft_size; i++) {
        size_t bit = fft_size >> 1;
        for (; j & bit; bit >>= 1)
            j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = re[i];
            re[i] = re[j];
            re[j] = t;
            t = im[i];
            im[i] = im[j];
            im[j] = t;
        }
    }
    for (size_t len = 2; len <= fft_size; len <<= 1) {
        size_t step = fft_size / len;
        for (size_t i = 0; i < fft_size; i += len)
            for (size_t k = 0; k < len / 2; k++) {
                float wr = an.cos_table[k * step], wi = -an.sin_table[k * step];
                size_t a = i + k, b = a + len / 2;
                float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr;
                im[b] = im[a] - xi;
                re[a] += xr;
                im[a] += xi;
            }
    }
}

// The bands of the last fft_size samples, 0..255, then sent. Returns
// false once the output is gone.
[[nodiscard]] static bool analyze(void) {
    static float re[fft_size], im[fft_size];
    for (size_t i = 0; i < fft_size; i++) {
        re[i] = an.ring[(an.at + i) % fft_size] * an.window[i]; // oldest first
        im[i] = 0;
    }
    fft(re, im);

    uint8_t levels[band_count];
    bool any = false;
    for (int b = 0; b < band_count; b++) {
        float peak = 0;
        for (int k = an.band_lo[b]; k < an.band_hi[b] && k < (int)fft_size / 2; k++) {
            float mag = sqrtf(re[k] * re[k] + im[k] * im[k]);
            peak = mag > peak ? mag : peak;
        }
        // A full-scale sine comes out of a Hann-windowed FFT at n/4: this
        // makes it 1.0, 0 dB.
        float amp = peak / (fft_size / 4.0f);
        float db = 20.0f * log10f(amp + 1e-9f) + an.tilt_db[b];
        float level = (db - floor_db) / (ceiling_db - floor_db);
        level = level < 0 ? 0 : level > 1 ? 1 : level;
        float fallen = an.shown[b] - fall_per_frame;
        an.shown[b] = level > fallen ? level : (fallen > 0 ? fallen : 0);
        levels[b] = (uint8_t)lroundf(an.shown[b] * 255);
        any = any || levels[b] > 0;
    }
    // Quiet: one all-zero LEVELS clears the bars, then nothing until
    // there's sound again, so windows don't redraw 30 times a second for
    // silence.
    if (!any && an.silent)
        return true;
    an.silent = !any;
    return send_levels(levels);
}

// Interleaved stereo frames in; mixed to mono, since the bars show one
// spectrum. Returns false once the output is gone.
[[nodiscard]] static bool feed(const float *frames, size_t count) {
    for (size_t i = 0; i < count; i++) {
        an.ring[an.at] = (frames[i * channels] + frames[i * channels + 1]) * 0.5f;
        an.at = (an.at + 1) % fft_size;
        if (++an.since == hop) {
            an.since = 0;
            if (!analyze())
                return false;
        }
    }
    return true;
}

// --- Recording ---

struct capture {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    // A timer on the loop thread, ticking once per hop while the bars are
    // up: when samples stop coming, it feeds silence so the bars fall.
    struct spa_source *idle;
    bool idle_armed;
    int64_t last_sound_ns; // when the last buffer came
    // The output is gone: Elixir closed the port. stdin closes too, and
    // the main thread ends the program; until then, drop the sound.
    bool gone;
};

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1'000'000'000 + t.tv_nsec;
}

// Starts or stops the idle timer: timerfd_settime(2) under PipeWire's
// loop, every hop (33 ms) while armed. Only while the bars are up, so
// silence still costs no wakeups at all.
static void arm_idle(struct capture *cap, bool on) {
    if (cap->idle == nullptr || cap->idle_armed == on)
        return;
    struct timespec tick = {.tv_nsec = on ? (long)(1'000'000'000LL * hop / sample_rate) : 0};
    pw_loop_update_timer(pw.thread_loop_get_loop(cap->loop), cap->idle, &tick, &tick, false);
    cap->idle_armed = on;
}

static void feed_or_stop(struct capture *cap, const float *frames, size_t count) {
    if (!cap->gone)
        cap->gone = !feed(frames, count);
    arm_idle(cap, !cap->gone && !an.silent);
}

// The idle timer: the sound stopped, so the bars fall as they would in a
// quiet passage, one hop of silence per tick, until they're all at 0
// (the all-zero LEVELS) and the timer stops.
static void on_idle(void *data, uint64_t) {
    struct capture *cap = data;
    if (now_ns() - cap->last_sound_ns < stalled_ns)
        return;
    static const float silence[hop * channels];
    feed_or_stop(cap, silence, hop);
}

// PipeWire calls this on its loop thread when a buffer of samples is
// ready. Only this thread touches `an` and writes stdout.
static void on_process(void *data) {
    struct capture *cap = data;
    struct pw_buffer *b = pw.stream_dequeue_buffer(cap->stream);
    if (b == nullptr)
        return;
    struct spa_data *d = &b->buffer->datas[0];
    if (d->data != nullptr && d->chunk != nullptr) {
        uint32_t offset = d->chunk->offset < d->maxsize ? d->chunk->offset : d->maxsize;
        uint32_t size = d->chunk->size < d->maxsize - offset ? d->chunk->size : d->maxsize - offset;
        cap->last_sound_ns = now_ns();
        feed_or_stop(cap, (const float *)((const uint8_t *)d->data + offset),
                     size / (sizeof(float) * channels));
    }
    pw.stream_queue_buffer(cap->stream, b);
}

static void on_state_changed(void *, enum pw_stream_state, enum pw_stream_state state,
                             const char *error) {
    if (state == PW_STREAM_STATE_ERROR) {
        // On the loop thread, with the main thread blocked in read(2):
        // _exit(2) ends both without running cleanups that would wait for
        // this very thread.
        fprintf(stderr, "guiltty_audio: PipeWire: %s\n", error ? error : "stream error");
        _exit(3);
    }
}

static const struct pw_stream_events stream_events = {
    .version = PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .process = on_process,
};

// Records until stdin reaches its end (the port closed). Returns the
// exit status.
[[nodiscard]] static int record(void) {
    void *lib = load_pipewire();
    if (lib == nullptr) {
        fprintf(stderr, "guiltty_audio: no PipeWire (libpipewire-0.3.so.0): %s\n", dlerror());
        return 2;
    }
    pw.init(nullptr, nullptr);

    struct capture cap = {.loop = pw.thread_loop_new("guiltty-audio", nullptr)};
    int status = 3;
    if (cap.loop == nullptr)
        goto out;
    // Capture, from the sink's monitor (what the speakers play). Passive:
    // this stream alone doesn't keep the output awake, so when nothing
    // plays the sink still suspends as it would without guiltty.
    struct pw_properties *props = pw.properties_new(
        PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_STREAM_CAPTURE_SINK, "true", PW_KEY_NODE_PASSIVE, "true", PW_KEY_APP_NAME,
        "guiltty", PW_KEY_NODE_NAME, "guiltty-visualizer", nullptr);
    cap.stream = pw.stream_new_simple(pw.thread_loop_get_loop(cap.loop), "guiltty visualizer",
                                      props, &stream_events, &cap);
    if (cap.stream == nullptr) {
        fprintf(stderr, "guiltty_audio: can't reach PipeWire: %s\n", strerror(errno));
        goto out;
    }

    // Ask for the format we analyze; PipeWire converts whatever the sink
    // plays (rate, sample format, channel count) into it.
    uint8_t pod_buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(pod_buffer, sizeof pod_buffer);
    const struct spa_pod *params[1] = {spa_format_audio_raw_build(
        &builder, SPA_PARAM_EnumFormat,
        &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .rate = sample_rate,
                                 .channels = channels))};
    if (pw.stream_connect(cap.stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                          PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1) < 0) {
        fprintf(stderr, "guiltty_audio: PipeWire wouldn't connect the stream\n");
        goto out;
    }
    // Added before the loop thread starts, so no lock is needed; armed and
    // fired only on that thread from then on.
    cap.idle = pw_loop_add_timer(pw.thread_loop_get_loop(cap.loop), on_idle, &cap);
    if (pw.thread_loop_start(cap.loop) < 0)
        goto out;

    if (!print_mode && !send_message((const uint8_t[]){AUDIO_HELLO, audio_version >> 8,
                                                       audio_version & 0xFF},
                                     3)) {
        status = 0;
        goto stop;
    }

    // The main thread only waits for stdin to close: Elixir closed the
    // port, or guiltty is gone. Nothing is ever read from it.
    uint8_t ignored[64];
    while (read(STDIN_FILENO, ignored, sizeof ignored) != 0)
        if (errno != EINTR && errno != EAGAIN)
            break;
    status = 0;

stop:
    pw.thread_loop_stop(cap.loop);
out:
    if (cap.stream != nullptr)
        pw.stream_destroy(cap.stream);
    if (cap.loop != nullptr)
        pw.thread_loop_destroy(cap.loop);
    pw.deinit();
    dlclose(lib);
    return status;
}

// --raw: the same analysis on samples from a file, as fast as it reads.
[[nodiscard]] static int analyze_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == nullptr) {
        perror(path);
        return 64;
    }
    if (!send_message((const uint8_t[]){AUDIO_HELLO, audio_version >> 8, audio_version & 0xFF},
                      3)) {
        fclose(f);
        return 0;
    }
    static float frames[hop * channels];
    // A short read is the end of the file (or an error): stop there, since
    // reading on after it is undefined (the analyzers check for that).
    for (;;) {
        size_t n = fread(frames, sizeof(float) * channels, hop, f);
        if ((n > 0 && !feed(frames, n)) || n < hop)
            break;
    }
    fclose(f);
    return 0;
}

int main(int argc, char *argv[]) {
    // A closed port makes write(2) fail with EPIPE instead of killing us
    // with SIGPIPE before we can stop PipeWire cleanly.
    signal(SIGPIPE, SIG_IGN);
    analysis_init();

    if (argc == 3 && strcmp(argv[1], "--raw") == 0)
        return analyze_file(argv[2]);
    if (argc == 2 && strcmp(argv[1], "--print") == 0)
        print_mode = true;
    else if (argc != 1) {
        fprintf(stderr, "usage: guiltty_audio [--print | --raw FILE]\n");
        return 64;
    }
    return record();
}

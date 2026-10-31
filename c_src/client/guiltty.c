// guiltty: the command you run (and the menu entry runs). It asks the
// running guiltty for a window, or starts guiltty if none is running. It
// decides nothing: the running guiltty (Guiltty.Launcher, in Elixir) does.
// Book chapter 23.
//
//   guiltty            open a window
//   guiltty ARGS...    anything else (stop, pid, remote...) goes to the
//                      release's own script, as before
//
// The request, protocol version 1, over a Unix socket (unix(7)):
//
//   guiltty 1 open\n
//   DISPLAY=:0\n            the display variables this command has
//   ...\n
//   PWD=/home/me/src\n      the folder it runs in: the new window's first
//                           tab starts there
//   \n                      the end
//
// and the answer is one line: "ok\n" or "error: why\n".
//
// Read: unix(7), socket(2), connect(2), poll(2), execv(3), getcwd(3),
// proc_pid_exe(5).

#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

// Which protocol this client speaks; Guiltty.Launcher refuses another.
constexpr int protocol_version = 1;
// How long the running guiltty may take to answer (opening the window).
constexpr int reply_timeout_ms = 10'000;
// While a guiltty shuts down it answers "shutting down": ask again every
// 50 ms, for up to 5 s, until it's gone and a new one can be started.
constexpr int retry_ms = 50;
constexpr int max_retries = 100;
// The longest display variable value sent along.
constexpr size_t max_value = 1024;
// The longest folder sent along: the server's line limit is 4 KB.
constexpr size_t max_folder = 3000;

static const char *const display_vars[] = {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY",
                                           "XDG_RUNTIME_DIR"};

enum outcome { OPENED, NOBODY, SHUTTING_DOWN, FAILED };

// Where the socket is, as Guiltty.Launcher.socket_path/0 says: the
// override, or the runtime folder systemd makes private to you at login,
// or one in /tmp named after your uid.
[[nodiscard]] static bool socket_path(char *out, size_t size) {
    const char *path = getenv("GUILTTY_SOCKET");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    int n;
    if (path != nullptr)
        n = snprintf(out, size, "%s", path);
    else if (runtime != nullptr)
        n = snprintf(out, size, "%s/guiltty/sock", runtime);
    else
        n = snprintf(out, size, "/tmp/guiltty-%u/sock", (unsigned)getuid());
    return n > 0 && (size_t)n < size;
}

// The release's start script. This program lives in the release, in
// lib/guiltty-VERSION/priv/, and ~/.local/bin/guiltty is a link to it:
// /proc/self/exe names the real file, three folders below the release.
[[nodiscard]] static bool release_script(char *out, size_t size) {
    const char *given = getenv("GUILTTY_RELEASE");
    if (given != nullptr) {
        int n = snprintf(out, size, "%s", given);
        return n > 0 && (size_t)n < size;
    }
    char exe[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (len <= 0)
        return false;
    exe[len] = '\0';
    // .../release/lib/guiltty-VERSION/priv/guiltty: drop four names.
    for (int i = 0; i < 4; i++) {
        char *slash = strrchr(exe, '/');
        if (slash == nullptr || slash == exe)
            return false;
        *slash = '\0';
    }
    int n = snprintf(out, size, "%s/bin/guiltty", exe);
    return n > 0 && (size_t)n < size;
}

// The request: the first line, then each display variable this command
// has (one whose value would break a line is left out), then a blank line.
static size_t build_request(char *out, size_t size) {
    size_t used = (size_t)snprintf(out, size, "guiltty %d open\n", protocol_version);
    for (size_t i = 0; i < sizeof display_vars / sizeof display_vars[0]; i++) {
        const char *value = getenv(display_vars[i]);
        // No display needs more than this, and a line too long for the
        // server's limit (4 KB) would just get the connection closed.
        if (value == nullptr || strpbrk(value, "\r\n") != nullptr || strlen(value) > max_value)
            continue;
        int n = snprintf(out + used, size - used, "%s=%s\n", display_vars[i], value);
        if (n < 0 || (size_t)n >= size - used)
            continue; // too long for any display: leave it out
        used += (size_t)n;
    }
    // Where this command runs, from getcwd(3) rather than $PWD, which a
    // program can leave stale. A folder that won't fit just isn't sent.
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof cwd) != nullptr && strpbrk(cwd, "\r\n") == nullptr &&
        strlen(cwd) <= max_folder) {
        int n = snprintf(out + used, size - used, "PWD=%s\n", cwd);
        if (n > 0 && (size_t)n < size - used)
            used += (size_t)n;
    }
    if (used + 1 < size)
        out[used++] = '\n';
    return used;
}

[[nodiscard]] static bool write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, buf, len);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            return false;
        buf += w;
        len -= (size_t)w;
    }
    return true;
}

// One line of answer, waiting at most reply_timeout_ms for it (poll(2)).
[[nodiscard]] static bool read_line(int fd, char *out, size_t size) {
    size_t used = 0;
    while (used + 1 < size) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int ready = poll(&p, 1, reply_timeout_ms);
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready <= 0)
            return false;
        ssize_t r = read(fd, out + used, size - 1 - used);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return false;
        used += (size_t)r;
        char *nl = memchr(out, '\n', used);
        if (nl != nullptr) {
            *nl = '\0';
            return true;
        }
    }
    return false;
}

static enum outcome ask(const char *path, const char *request, size_t len) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof addr.sun_path) {
        fprintf(stderr, "guiltty: socket path too long: %s\n", path);
        return FAILED;
    }
    strcpy(addr.sun_path, path);

    // Close-on-exec: if this process goes on to exec the release, the
    // socket shouldn't follow.
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("guiltty: socket");
        return FAILED;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        int err = errno;
        close(fd);
        // No socket file, or one left by a guiltty that's gone: nobody's
        // there (unix(7): ECONNREFUSED when nothing listens).
        if (err == ENOENT || err == ECONNREFUSED)
            return NOBODY;
        fprintf(stderr, "guiltty: can't reach guiltty at %s: %s\n", path, strerror(err));
        return FAILED;
    }

    char reply[512];
    bool answered = write_all(fd, request, len) && read_line(fd, reply, sizeof reply);
    close(fd);
    // No answer at all: the guiltty it reached is going away.
    if (!answered || strcmp(reply, "error: shutting down") == 0)
        return SHUTTING_DOWN;
    if (strcmp(reply, "ok") == 0)
        return OPENED;
    fprintf(stderr, "guiltty: %s\n", reply);
    return FAILED;
}

// Hand over to the release's own script: "daemon" to start guiltty (it
// opens its first window by itself, on this display: it inherits our
// environment), or whatever arguments we were given.
[[noreturn]] static void run_release(char *args[]) {
    char script[PATH_MAX];
    if (!release_script(script, sizeof script)) {
        fprintf(stderr, "guiltty: can't find the guiltty release next to this program\n");
        exit(1);
    }
    args[0] = script;
    execv(script, args);
    fprintf(stderr, "guiltty: can't run %s: %s\n", script, strerror(errno));
    exit(1);
}

int main(int argc, char *argv[]) {
    if (argc > 1)
        run_release(argv);

    char path[sizeof((struct sockaddr_un){}.sun_path) + 1];
    if (!socket_path(path, sizeof path)) {
        fprintf(stderr, "guiltty: the socket path is too long\n");
        return 1;
    }
    char request[8192];
    size_t len = build_request(request, sizeof request);

    for (int tries = 0; tries < max_retries; tries++) {
        switch (ask(path, request, len)) {
        case OPENED:
            return 0;
        case FAILED:
            return 1;
        case NOBODY: {
            char *args[] = {nullptr, "daemon", nullptr};
            run_release(args);
        }
        case SHUTTING_DOWN:
            nanosleep(&(struct timespec){.tv_nsec = retry_ms * 1'000'000L}, nullptr);
            break;
        }
    }
    fprintf(stderr, "guiltty: the running guiltty is shutting down and hasn't finished\n");
    return 1;
}

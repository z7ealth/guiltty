// guiltty: the command you run (and the menu entry runs). It asks the
// running guiltty for a window, or starts guiltty if none is running, or
// passes a command on (guiltty tab --new). It decides nothing: the
// running guiltty (Guiltty.Launcher and Guiltty.Command, in Elixir) does.
// Book chapters 23 and 29.
//
//   guiltty                  open a window
//   guiltty release ARGS...  the release's own script (stop, pid, remote...)
//   guiltty version          the same, answered without a running guiltty
//   guiltty ARGS...          anything else is a command for the running
//                            guiltty, sent as it is
//
// The request, protocol version 2, over a Unix socket (unix(7)):
//
//   guiltty 2 open\n        or "guiltty 2 cmd\n" for a command
//   ARG=tab\n               a command's words, one line each
//   ARG=--new\n
//   PANE=12\n               $GUILTTY_PANE, the pane a command was typed in
//   DISPLAY=:0\n            the display variables this command has
//   ...\n
//   PWD=/home/me/src\n      the folder it runs in: a new shell starts there
//   \n                      the end
//
// and the answer: lines to print, each "out: text\n", then the last
// line, "ok\n" or "error: why\n".
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
constexpr int protocol_version = 2;
// How long the running guiltty may take to answer (opening the window).
constexpr int reply_timeout_ms = 10'000;
// While a guiltty shuts down it answers "shutting down": ask again every
// 50 ms, for up to 5 s, until it's gone and a new one can be started.
constexpr int retry_ms = 50;
constexpr int max_retries = 100;
// The longest display variable value sent along.
constexpr size_t max_value = 1024;
// The longest folder or command word sent along: the server's line limit
// is 4 KB.
constexpr size_t max_folder = 3000;
// The most words a command may have: the server reads at most 32 lines,
// and the variables, the folder and the pane take up to 6.
constexpr int max_words = 24;
// The longest answer read: guiltty window --list for many windows fits.
constexpr size_t max_answer = 256 * 1024;

static const char *const display_vars[] = {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY",
                                           "XDG_RUNTIME_DIR"};

enum outcome { DONE, NOBODY, SHUTTING_DOWN, FAILED };

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

// Adds one line to the request; false if it won't fit.
[[nodiscard]] static bool add_line(char *out, size_t size, size_t *used, const char *name,
                                   const char *value) {
    int n = snprintf(out + *used, size - *used, "%s%s\n", name, value);
    if (n < 0 || (size_t)n >= size - *used)
        return false;
    *used += (size_t)n;
    return true;
}

// The request: the first line, a command's words, then each display
// variable this command has (one whose value would break a line is left
// out), then a blank line. Returns its length, 0 if a word can't be sent.
static size_t build_request(char *out, size_t size, int words, char *word[]) {
    size_t used = (size_t)snprintf(out, size, "guiltty %d %s\n", protocol_version,
                                   words > 0 ? "cmd" : "open");
    // A command's words must all go, unchanged, or not at all: a word cut
    // or left out would be another command.
    if (words > max_words) {
        fprintf(stderr, "guiltty: too many arguments\n");
        return 0;
    }
    for (int i = 0; i < words; i++) {
        if (strpbrk(word[i], "\r\n") != nullptr || strlen(word[i]) > max_folder ||
            !add_line(out, size, &used, "ARG=", word[i])) {
            fprintf(stderr, "guiltty: an argument is too long, or has a line break\n");
            return 0;
        }
    }
    // The pane a command was typed in. Only for commands: a window opens
    // the same from anywhere. The server checks it's a number.
    const char *pane = getenv("GUILTTY_PANE");
    if (words > 0 && pane != nullptr && strpbrk(pane, "\r\n") == nullptr &&
        strlen(pane) <= 32 && !add_line(out, size, &used, "PANE=", pane))
        return 0;
    for (size_t i = 0; i < sizeof display_vars / sizeof display_vars[0]; i++) {
        const char *value = getenv(display_vars[i]);
        // No display needs more than this, and a line too long for the
        // server's limit (4 KB) would just get the connection closed.
        if (value == nullptr || strpbrk(value, "\r\n") != nullptr || strlen(value) > max_value)
            continue;
        char name[32];
        snprintf(name, sizeof name, "%s=", display_vars[i]);
        (void)add_line(out, size, &used, name, value); // too long for any display: left out
    }
    // Where this command runs, from getcwd(3) rather than $PWD, which a
    // program can leave stale. A folder that won't fit just isn't sent.
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof cwd) != nullptr && strpbrk(cwd, "\r\n") == nullptr &&
        strlen(cwd) <= max_folder)
        (void)add_line(out, size, &used, "PWD=", cwd);
    if (used + 1 >= size)
        return 0;
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

// The whole answer: the server closes the connection after it. Waits at
// most reply_timeout_ms for each piece (poll(2)). Returns its length, -1
// if it never came, or -2 if it didn't fit.
[[nodiscard]] static ssize_t read_answer(int fd, char *out, size_t size) {
    size_t used = 0;
    for (;;) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int ready = poll(&p, 1, reply_timeout_ms);
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready <= 0)
            return -1;
        if (used + 1 >= size)
            return -2;
        ssize_t r = read(fd, out + used, size - 1 - used);
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0)
            return -1;
        if (r == 0)
            break;
        used += (size_t)r;
    }
    out[used] = '\0';
    return (ssize_t)used;
}

// Prints the answer's "out: " lines and says how its last line ended.
// Lines come already made printable by the server.
static enum outcome print_answer(char *answer) {
    char *line = answer;
    char *nl;
    while ((nl = strchr(line, '\n')) != nullptr) {
        *nl = '\0';
        if (strncmp(line, "out: ", 5) == 0) {
            puts(line + 5);
        } else if (strcmp(line, "ok") == 0) {
            return DONE;
        } else if (strcmp(line, "error: shutting down") == 0) {
            return SHUTTING_DOWN;
        } else {
            fprintf(stderr, "guiltty: %s\n", strncmp(line, "error: ", 7) == 0 ? line + 7 : line);
            return FAILED;
        }
        line = nl + 1;
    }
    // No last line: the guiltty it reached went away.
    return SHUTTING_DOWN;
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

    static char answer[max_answer];
    ssize_t got = write_all(fd, request, len) ? read_answer(fd, answer, sizeof answer) : -1;
    close(fd);
    // Never asked again: the command may have run.
    if (got == -2) {
        fprintf(stderr, "guiltty: the answer was too long to read\n");
        return FAILED;
    }
    // No answer at all: the guiltty it reached is going away.
    if (got < 0)
        return SHUTTING_DOWN;
    return print_answer(answer);
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
    // Two words never reach the server: the release's commands must work
    // with no guiltty running (stop one that hangs, check an install).
    if (argc > 1 && strcmp(argv[1], "release") == 0) {
        if (argc == 2) {
            fprintf(stderr, "guiltty: release takes a command: stop, pid, remote...\n");
            return 1;
        }
        run_release(argv + 1); // argv[1] is replaced by the script's path
    }
    if (argc == 2 && (strcmp(argv[1], "version") == 0 || strcmp(argv[1], "--version") == 0)) {
        char *args[] = {nullptr, "version", nullptr};
        run_release(args);
    }

    char path[sizeof((struct sockaddr_un){}.sun_path) + 1];
    if (!socket_path(path, sizeof path)) {
        fprintf(stderr, "guiltty: the socket path is too long\n");
        return 1;
    }
    static char request[128 * 1024];
    size_t len = build_request(request, sizeof request, argc - 1, argv + 1);
    if (len == 0)
        return 1;
    bool command = argc > 1;

    for (int tries = 0; tries < max_retries; tries++) {
        switch (ask(path, request, len)) {
        case DONE:
            return 0;
        case FAILED:
            return 1;
        case NOBODY: {
            // A command needs a running guiltty: starting one just to
            // split a pane of a window that doesn't exist would be a guess.
            if (command) {
                fprintf(stderr, "guiltty: guiltty isn't running (run guiltty to start it)\n");
                return 1;
            }
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

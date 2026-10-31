// pty_nif: the only C that runs inside the BEAM. It opens a pseudoterminal,
// starts a program on its slave side and lets Elixir read and write the
// master without a reader thread: enif_select tells the owning process when
// the fd is ready, and a regular (non-blocking) NIF call does the I/O.
//
// Read: pty(7), posix_openpt(3), setsid(2), ioctl_tty(2), signal-safety(7),
// pidfd_open(2), and the enif_select / resource sections of erl_nif(3).

#define _GNU_SOURCE

#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdckdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/pidfd.h>
#include <sys/wait.h>
#include <unistd.h>

// waitid(2)'s "the id is a pidfd" (Linux 5.4). The kernel has it; glibc's
// idtype_t doesn't name it yet.
constexpr idtype_t p_pidfd = (idtype_t)3;

// Largest chunk returned by one read/1 call.
constexpr size_t read_chunk = 64 * 1024;

// One pseudoterminal and the process running on it. Lives in a NIF resource,
// so Elixir holds it as an opaque reference and the BEAM frees it when the
// last reference is gone.
//
// The child is known by a pidfd, not its pid. The BEAM ignores SIGCHLD, so
// the kernel reaps an exited child at once and its pid is free for the next
// process, maybe another tab's shell. A signal sent by pid could hit that
// one; a pidfd always means this child, alive or dead (pidfd_open(2)).
struct pty {
    // NIF calls on one pty can come from different processes at once (the
    // Pty process, then the task that reaps its shell), so on different
    // scheduler threads. The lock covers fd and pidfd.
    ErlNifMutex *lock;
    int fd; // master fd, -1 once closed
    int pidfd; // the child, -1 once it's known to be gone
};

static ErlNifResourceType *pty_type;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_eof;
static ERL_NIF_TERM atom_eagain;
static ERL_NIF_TERM atom_running;
static ERL_NIF_TERM atom_exited;
static ERL_NIF_TERM atom_signaled;
static ERL_NIF_TERM atom_gone;
static ERL_NIF_TERM atom_undefined;

// {:error, :eio} style errors, from errno's symbolic name.
static ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int err) {
    const char *name = strerrorname_np(err);
    char lower[32] = "unknown";
    if (name != nullptr) {
        size_t i = 0;
        for (; name[i] != '\0' && i < sizeof lower - 1; i++)
            lower[i] = (char)(name[i] >= 'A' && name[i] <= 'Z' ? name[i] + 32 : name[i]);
        lower[i] = '\0';
    }
    return enif_make_tuple2(env, atom_error, enif_make_atom(env, lower));
}

// Called by the BEAM when it's safe to close an fd that was in enif_select.
// Closing a selected fd any other way races with the BEAM's poll set.
// close() already marked the pty closed. No lock here: the BEAM may call
// this from inside enif_select, while close() holds it.
static void pty_stop(ErlNifEnv *, void *, ErlNifEvent event, int) {
    close(event);
}

// Last reference gone, so no other call can run. Normally the Pty process
// has already closed the fd and its shell is gone; this is the safety net
// if it crashed first. It must never block a scheduler.
static void pty_dtor(ErlNifEnv *, void *obj) {
    struct pty *pty = obj;
    if (pty->fd >= 0)
        close(pty->fd);
    if (pty->pidfd >= 0) {
        // Harmless if the child is already gone: the pidfd can't point to
        // anyone else.
        pidfd_send_signal(pty->pidfd, SIGKILL, nullptr, 0);
        close(pty->pidfd);
    }
    if (pty->lock != nullptr)
        enif_mutex_destroy(pty->lock);
}

static int load(ErlNifEnv *env, void **, ERL_NIF_TERM) {
    ErlNifResourceTypeInit init = {.dtor = pty_dtor, .stop = pty_stop};
    pty_type = enif_open_resource_type_x(env, "pty", &init, ERL_NIF_RT_CREATE, nullptr);
    if (pty_type == nullptr)
        return 1;

    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_eof = enif_make_atom(env, "eof");
    atom_eagain = enif_make_atom(env, "eagain");
    atom_running = enif_make_atom(env, "running");
    atom_exited = enif_make_atom(env, "exited");
    atom_signaled = enif_make_atom(env, "signaled");
    atom_gone = enif_make_atom(env, "gone");
    atom_undefined = enif_make_atom(env, "undefined");
    return 0;
}

[[nodiscard]] static bool get_pty(ErlNifEnv *env, ERL_NIF_TERM term, struct pty **out) {
    return enif_get_resource(env, term, pty_type, (void **)out);
}

static void free_strings(char **strs) {
    if (strs == nullptr)
        return;
    for (char **s = strs; *s != nullptr; s++)
        free(*s);
    free(strs);
}

// A binary as a malloc'd C string, or nullptr if it isn't a binary or has a
// NUL inside (which would cut the string short).
[[nodiscard]] static char *binary_to_string(ErlNifEnv *env, ERL_NIF_TERM term) {
    ErlNifBinary bin;
    size_t size;
    char *s;
    if (!enif_inspect_binary(env, term, &bin) || memchr(bin.data, '\0', bin.size) != nullptr ||
        ckd_add(&size, bin.size, 1) || (s = malloc(size)) == nullptr)
        return nullptr;
    memcpy(s, bin.data, bin.size);
    s[bin.size] = '\0';
    return s;
}

// Turn an Elixir list of binaries into a NULL-terminated array of C strings,
// the shape execve wants for argv and envp. Done before fork: the child may
// not call malloc.
[[nodiscard]] static char **list_to_strings(ErlNifEnv *env, ERL_NIF_TERM list) {
    unsigned len;
    if (!enif_get_list_length(env, list, &len))
        return nullptr;
    size_t slots;
    if (ckd_add(&slots, (size_t)len, 1))
        return nullptr;
    char **strs = calloc(slots, sizeof(char *));
    if (strs == nullptr)
        return nullptr;

    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; enif_get_list_cell(env, tail, &head, &tail); i++) {
        ErlNifBinary bin;
        size_t size;
        if (!enif_inspect_binary(env, head, &bin) || memchr(bin.data, '\0', bin.size) != nullptr ||
            ckd_add(&size, bin.size, 1) || (strs[i] = malloc(size)) == nullptr) {
            free_strings(strs);
            return nullptr;
        }
        memcpy(strs[i], bin.data, bin.size);
        strs[i][bin.size] = '\0';
    }
    return strs;
}

// Runs in the child between fork and execve. The BEAM has many threads, and
// fork copies only the calling one: a lock another thread held (malloc's, for
// example) stays locked forever in the child. So only async-signal-safe
// calls from here on (signal-safety(7)).
[[noreturn]] static void exec_child(int slave, const char *path, char *const argv[],
                                    char *const envp[], const char *cwd) {
    // The BEAM blocks and ignores some signals. Blocked masks and ignored
    // dispositions survive execve, so without this reset bash's children
    // would start with, say, SIGPIPE ignored.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, nullptr);
    struct sigaction dfl = {.sa_handler = SIG_DFL};
    for (int sig = 1; sig < NSIG; sig++)
        sigaction(sig, &dfl, nullptr); // fails harmlessly for SIGKILL and SIGSTOP

    // A new session with no controlling terminal, then claim the slave as
    // ours. TIOCSCTTY only works for a session leader without a terminal.
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0)
        _exit(126);

    if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0)
        _exit(126);

    // Don't leak the BEAM's fds (other sessions' masters, sockets) into bash.
    close_range(STDERR_FILENO + 1, ~0U, 0);

    // Start where the user asked (a new tab opens in the current tab's
    // directory). chdir(2) is async-signal-safe.
    if (cwd[0] != '\0' && chdir(cwd) < 0) {
        // The directory is gone: the shell just starts where the BEAM is.
    }

    execve(path, argv, envp);
    _exit(127);
}

// open(path, argv, envp, cols, rows, cwd) -> {:ok, pty, os_pid} | {:error, reason}
// cwd "" means: don't change directory.
//
// Runs on a dirty I/O scheduler: forking a big BEAM copies its page tables,
// which can take long enough to upset a normal scheduler.
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    ErlNifBinary path_bin;
    unsigned cols, rows;
    if (!enif_inspect_binary(env, argv[0], &path_bin) || !enif_get_uint(env, argv[3], &cols) ||
        !enif_get_uint(env, argv[4], &rows) || cols == 0 || rows == 0 || cols > USHRT_MAX ||
        rows > USHRT_MAX)
        return enif_make_badarg(env);

    // Everything the child needs is copied into C strings now: after fork
    // it can't call malloc.
    char *path = binary_to_string(env, argv[0]);
    char *cwd = binary_to_string(env, argv[5]);
    char **child_argv = list_to_strings(env, argv[1]);
    char **child_envp = list_to_strings(env, argv[2]);
    if (path == nullptr || cwd == nullptr || child_argv == nullptr || child_envp == nullptr) {
        free(path);
        free(cwd);
        free_strings(child_argv);
        free_strings(child_envp);
        return enif_make_badarg(env);
    }

    ERL_NIF_TERM result;
    int master = -1, slave = -1;
    ErlNifMutex *lock = nullptr;
    struct winsize ws = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
    // Both ends close-on-exec from the moment they exist, so no program
    // another thread starts can inherit them (a stray copy of the slave
    // would keep the master from ever seeing EIO). The master is
    // non-blocking, so read and write never stall a scheduler. TIOCGPTPEER
    // opens this master's own slave, with no path to look up in /dev/pts
    // (ioctl_tty(2)).
    master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
    if (master < 0 || unlockpt(master) < 0 ||
        (slave = ioctl(master, TIOCGPTPEER, O_RDWR | O_NOCTTY | O_CLOEXEC)) < 0 ||
        ioctl(slave, TIOCSWINSZ, &ws) < 0) {
        result = make_errno_error(env, errno);
        goto out;
    }
    if ((lock = enif_mutex_create("pty")) == nullptr) {
        result = make_errno_error(env, ENOMEM);
        goto out;
    }

    pid_t pid = fork();
    if (pid < 0) {
        result = make_errno_error(env, errno);
        goto out;
    }
    if (pid == 0)
        exec_child(slave, path, child_argv, child_envp, cwd);

    // Our copy of the slave must go, or the master never reports the end.
    close(slave);
    slave = -1;

    // The child can't have been reaped yet: it can only exit after
    // setsid() and the rest, and even then its pid would have to come
    // round again (pid_max is millions) before this line. If it's somehow
    // gone, ESRCH: the pty starts out knowing its child is gone.
    int pidfd = pidfd_open(pid, 0);

    struct pty *pty = enif_alloc_resource(pty_type, sizeof *pty);
    *pty = (struct pty){.lock = lock, .fd = master, .pidfd = pidfd};
    master = -1; // owned by the resource now, with the pidfd and the lock
    lock = nullptr;
    result = enif_make_tuple3(env, atom_ok, enif_make_resource(env, pty), enif_make_int(env, pid));
    enif_release_resource(pty); // the term keeps it alive

out:
    if (master >= 0)
        close(master);
    if (slave >= 0)
        close(slave);
    if (lock != nullptr)
        enif_mutex_destroy(lock);
    free(path);
    free(cwd);
    free_strings(child_argv);
    free_strings(child_envp);
    return result;
}

// read(pty) -> {:ok, binary} | :eagain | :eof | {:error, reason}
static ERL_NIF_TERM nif_read(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);

    ErlNifBinary bin;
    if (!enif_alloc_binary(read_chunk, &bin))
        return make_errno_error(env, ENOMEM);
    ssize_t n;
    int err = 0;
    enif_mutex_lock(pty->lock);
    if (pty->fd < 0) {
        n = 0; // closed: the same as the end
    } else {
        do
            n = read(pty->fd, bin.data, bin.size);
        while (n < 0 && errno == EINTR);
        err = errno;
    }
    enif_mutex_unlock(pty->lock);

    if (n > 0) {
        // Shrink it to what was read. If that fails, hand out just the
        // first n bytes: never the rest of the buffer.
        if (enif_realloc_binary(&bin, (size_t)n))
            return enif_make_tuple2(env, atom_ok, enif_make_binary(env, &bin));
        ERL_NIF_TERM whole = enif_make_binary(env, &bin);
        return enif_make_tuple2(env, atom_ok, enif_make_sub_binary(env, whole, 0, (size_t)n));
    }
    enif_release_binary(&bin);
    if (n == 0)
        return atom_eof;
    if (err == EAGAIN)
        return atom_eagain;
    // Linux reports the slave side closing as EIO, not as a 0-byte read.
    if (err == EIO)
        return atom_eof;
    return make_errno_error(env, err);
}

// write(pty, binary) -> {:ok, bytes_written} | :eagain | {:error, reason}
// May write less than asked; the caller keeps the rest.
static ERL_NIF_TERM nif_write(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    ErlNifBinary bin;
    if (!get_pty(env, argv[0], &pty) || !enif_inspect_binary(env, argv[1], &bin))
        return enif_make_badarg(env);

    ssize_t n = -1;
    int err = EBADF;
    enif_mutex_lock(pty->lock);
    if (pty->fd >= 0) {
        do
            n = write(pty->fd, bin.data, bin.size);
        while (n < 0 && errno == EINTR);
        err = errno;
    }
    enif_mutex_unlock(pty->lock);
    if (n >= 0)
        return enif_make_tuple2(env, atom_ok, enif_make_uint64(env, (ErlNifUInt64)n));
    if (err == EAGAIN)
        return atom_eagain;
    return make_errno_error(env, err);
}

// Ask the BEAM to send the calling process {:select, pty, :undefined,
// :ready_input | :ready_output} once the master is readable or writable. It
// fires once; call again to re-arm.
static ERL_NIF_TERM do_select(ErlNifEnv *env, const ERL_NIF_TERM argv[], enum ErlNifSelectFlags mode) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    enif_mutex_lock(pty->lock);
    int rc = pty->fd < 0 ? 0 : enif_select(env, pty->fd, mode, pty, nullptr, atom_undefined);
    bool closed = pty->fd < 0;
    enif_mutex_unlock(pty->lock);
    if (closed)
        return make_errno_error(env, EBADF);
    return rc < 0 ? enif_make_tuple2(env, atom_error, enif_make_int(env, rc)) : atom_ok;
}

static ERL_NIF_TERM nif_select_read(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    return do_select(env, argv, ERL_NIF_SELECT_READ);
}

static ERL_NIF_TERM nif_select_write(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    return do_select(env, argv, ERL_NIF_SELECT_WRITE);
}

// resize(pty, cols, rows) -> :ok | {:error, reason}
// TIOCSWINSZ stores the new size in the terminal; if it changed, the kernel
// sends SIGWINCH to the terminal's foreground process group (ioctl_tty(2)).
static ERL_NIF_TERM nif_resize(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    unsigned cols, rows;
    if (!get_pty(env, argv[0], &pty) || !enif_get_uint(env, argv[1], &cols) ||
        !enif_get_uint(env, argv[2], &rows) || cols == 0 || rows == 0 || cols > USHRT_MAX ||
        rows > USHRT_MAX)
        return enif_make_badarg(env);
    struct winsize ws = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
    enif_mutex_lock(pty->lock);
    int rc = pty->fd < 0 ? -1 : ioctl(pty->fd, TIOCSWINSZ, &ws);
    int err = pty->fd < 0 ? EBADF : errno;
    enif_mutex_unlock(pty->lock);
    return rc < 0 ? make_errno_error(env, err) : atom_ok;
}

// winch(pty) -> :ok | {:error, reason}
// Sends SIGWINCH to the terminal's foreground process group, the same
// signal a resize sends, without changing the size. Full-screen programs
// answer it by redrawing everything, which repairs a screen that missed
// some bytes (after a parser restart, for example). tcgetpgrp(3) asks the
// terminal which group is in the foreground.
// The terminal's foreground process group, or -1 with *err set.
static pid_t foreground_group(struct pty *pty, int *err) {
    enif_mutex_lock(pty->lock);
    pid_t pgrp = pty->fd < 0 ? -1 : tcgetpgrp(pty->fd);
    *err = pty->fd < 0 ? EBADF : errno;
    enif_mutex_unlock(pty->lock);
    return pgrp > 0 ? pgrp : -1;
}

static ERL_NIF_TERM nif_winch(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    int err;
    pid_t pgrp = foreground_group(pty, &err);
    if (pgrp < 0)
        return make_errno_error(env, err);
    return kill(-pgrp, SIGWINCH) < 0 ? make_errno_error(env, errno) : atom_ok;
}

// foreground(pty) -> {:ok, pgid} | {:error, reason}: the process group in
// the terminal's foreground, the job that gets what's typed (tcgetpgrp(3)).
// When ssh is running, it's ssh's; when ssh exits, it's the shell's again.
static ERL_NIF_TERM nif_foreground(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    int err;
    pid_t pgrp = foreground_group(pty, &err);
    if (pgrp < 0)
        return make_errno_error(env, err);
    return enif_make_tuple2(env, atom_ok, enif_make_int(env, pgrp));
}

// close(pty) -> :ok. Closing the master hangs up the terminal: the kernel
// sends SIGHUP to the session, which is how bash learns the window is gone.
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    enif_mutex_lock(pty->lock);
    int fd = pty->fd;
    // Closed for every later call from now on. pty_stop does the actual
    // close(), now or once the BEAM lets go of the fd: until then the
    // number is still ours, but if a call could still use it after that,
    // it might reach whatever file opens next with that number.
    pty->fd = -1;
    if (fd >= 0 && enif_select(env, fd, ERL_NIF_SELECT_STOP, pty, nullptr, atom_undefined) < 0)
        close(fd);
    enif_mutex_unlock(pty->lock);
    return atom_ok;
}

// wait(pty) -> :running | :gone | {:exited, code} | {:signaled, signal}
// Never blocks: polls the child with WNOHANG.
//
// The BEAM ignores SIGCHLD, and with SIGCHLD ignored the kernel reaps exited
// children itself (waitpid(2), NOTES). Then waitid fails with ECHILD and the
// exit status is lost: that's :gone.
static ERL_NIF_TERM nif_wait(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);

    siginfo_t info = {};
    int rc = 0, err = 0;
    bool gone;
    enif_mutex_lock(pty->lock);
    if (pty->pidfd >= 0) {
        rc = waitid(p_pidfd, (id_t)pty->pidfd, &info, WEXITED | WNOHANG);
        err = errno;
        // Exited (si_pid set), or already reaped by the kernel (ECHILD).
        if ((rc == 0 && info.si_pid != 0) || (rc < 0 && err == ECHILD)) {
            close(pty->pidfd);
            pty->pidfd = -1;
        }
    }
    gone = pty->pidfd < 0;
    enif_mutex_unlock(pty->lock);

    if (rc < 0 && err != ECHILD)
        return make_errno_error(env, err);
    if (!gone)
        return atom_running;
    if (info.si_pid == 0)
        return atom_gone;
    if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED)
        return enif_make_tuple2(env, atom_signaled, enif_make_int(env, info.si_status));
    return enif_make_tuple2(env, atom_exited, enif_make_int(env, info.si_status));
}

// kill(pty, signal) -> :ok | {:error, reason}
static ERL_NIF_TERM nif_kill(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    int sig;
    if (!get_pty(env, argv[0], &pty) || !enif_get_int(env, argv[1], &sig) || sig <= 0 || sig >= NSIG)
        return enif_make_badarg(env);
    enif_mutex_lock(pty->lock);
    // Through the pidfd: if the child is gone, ESRCH, never a stranger.
    int rc = pty->pidfd < 0 ? -1 : pidfd_send_signal(pty->pidfd, sig, nullptr, 0);
    int err = pty->pidfd < 0 ? ESRCH : errno;
    enif_mutex_unlock(pty->lock);
    return rc < 0 ? make_errno_error(env, err) : atom_ok;
}

static ErlNifFunc funcs[] = {
    {"open", 6, nif_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read", 1, nif_read, 0},
    {"write", 2, nif_write, 0},
    {"select_read", 1, nif_select_read, 0},
    {"select_write", 1, nif_select_write, 0},
    {"resize", 3, nif_resize, 0},
    {"winch", 1, nif_winch, 0},
    {"foreground", 1, nif_foreground, 0},
    {"close", 1, nif_close, 0},
    {"wait", 1, nif_wait, 0},
    {"kill", 2, nif_kill, 0},
};

ERL_NIF_INIT(Elixir.Guiltty.Session.PtyNif, funcs, load, nullptr, nullptr, nullptr)

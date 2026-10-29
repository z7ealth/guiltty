// pty_nif: the only C that runs inside the BEAM. It opens a pseudoterminal,
// starts a program on its slave side and lets Elixir read and write the
// master without a reader thread: enif_select tells the owning process when
// the fd is ready, and a regular (non-blocking) NIF call does the I/O.
//
// Read: pty(7), openpty(3), setsid(2), ioctl_tty(2), signal-safety(7), and the
// enif_select / resource sections of erl_nif(3).

#define _GNU_SOURCE

#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pty.h>
#include <signal.h>
#include <stdckdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

// Largest chunk returned by one read/1 call.
constexpr size_t read_chunk = 64 * 1024;

// One pseudoterminal and the process running on it. Lives in a NIF resource,
// so Elixir holds it as an opaque reference and the BEAM frees it when the
// last reference is gone.
struct pty {
    int fd; // master fd, -1 once closed
    pid_t pid; // child pid, -1 once reaped
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
static void pty_stop(ErlNifEnv *, void *obj, ErlNifEvent event, int) {
    struct pty *pty = obj;
    close(event);
    if (pty->fd == event)
        pty->fd = -1;
}

// Last reference gone. Normally the Pty process has already closed the fd
// and seen the child exit; this is the safety net if it crashed before that.
// It must never block a scheduler.
static void pty_dtor(ErlNifEnv *, void *obj) {
    struct pty *pty = obj;
    if (pty->fd >= 0) {
        close(pty->fd);
        pty->fd = -1;
    }
    // Only signal the child if waitpid says it's still running: once it's
    // gone its pid can be reused by an unrelated process.
    if (pty->pid > 0 && waitpid(pty->pid, nullptr, WNOHANG) == 0)
        kill(pty->pid, SIGKILL);
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
                                    char *const envp[]) {
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

    execve(path, argv, envp);
    _exit(127);
}

// open(path, argv, envp, cols, rows) -> {:ok, pty, os_pid} | {:error, reason}
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

    char *path = nullptr;
    size_t path_size;
    if (!ckd_add(&path_size, path_bin.size, 1) && (path = malloc(path_size)) != nullptr) {
        memcpy(path, path_bin.data, path_bin.size);
        path[path_bin.size] = '\0';
    }
    char **child_argv = list_to_strings(env, argv[1]);
    char **child_envp = list_to_strings(env, argv[2]);
    if (path == nullptr || child_argv == nullptr || child_envp == nullptr) {
        free(path);
        free_strings(child_argv);
        free_strings(child_envp);
        return enif_make_badarg(env);
    }

    ERL_NIF_TERM result;
    int master = -1, slave = -1;
    struct winsize ws = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
    if (openpty(&master, &slave, nullptr, nullptr, &ws) < 0) {
        result = make_errno_error(env, errno);
        goto out;
    }
    // Close-on-exec, so no other program the BEAM starts inherits them. A
    // stray copy of the slave would keep the master from ever seeing EIO.
    // Non-blocking, so read and write never stall a scheduler.
    if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0 || fcntl(slave, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) < 0) {
        result = make_errno_error(env, errno);
        goto out;
    }

    pid_t pid = fork();
    if (pid < 0) {
        result = make_errno_error(env, errno);
        goto out;
    }
    if (pid == 0)
        exec_child(slave, path, child_argv, child_envp);

    // Our copy of the slave must go, or the master never reports the end.
    close(slave);
    slave = -1;

    struct pty *pty = enif_alloc_resource(pty_type, sizeof *pty);
    *pty = (struct pty){.fd = master, .pid = pid};
    master = -1; // owned by the resource now
    result = enif_make_tuple3(env, atom_ok, enif_make_resource(env, pty), enif_make_int(env, pid));
    enif_release_resource(pty); // the term keeps it alive

out:
    if (master >= 0)
        close(master);
    if (slave >= 0)
        close(slave);
    free(path);
    free_strings(child_argv);
    free_strings(child_envp);
    return result;
}

// read(pty) -> {:ok, binary} | :eagain | :eof | {:error, reason}
static ERL_NIF_TERM nif_read(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    if (pty->fd < 0)
        return atom_eof;

    ErlNifBinary bin;
    if (!enif_alloc_binary(read_chunk, &bin))
        return make_errno_error(env, ENOMEM);
    ssize_t n;
    do
        n = read(pty->fd, bin.data, bin.size);
    while (n < 0 && errno == EINTR);

    if (n > 0) {
        enif_realloc_binary(&bin, (size_t)n);
        return enif_make_tuple2(env, atom_ok, enif_make_binary(env, &bin));
    }
    int err = errno;
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
    if (pty->fd < 0)
        return make_errno_error(env, EBADF);

    ssize_t n;
    do
        n = write(pty->fd, bin.data, bin.size);
    while (n < 0 && errno == EINTR);
    if (n >= 0)
        return enif_make_tuple2(env, atom_ok, enif_make_uint64(env, (ErlNifUInt64)n));
    if (errno == EAGAIN)
        return atom_eagain;
    return make_errno_error(env, errno);
}

// Ask the BEAM to send the calling process {:select, pty, :undefined,
// :ready_input | :ready_output} once the master is readable or writable. It
// fires once; call again to re-arm.
static ERL_NIF_TERM do_select(ErlNifEnv *env, const ERL_NIF_TERM argv[], enum ErlNifSelectFlags mode) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    if (pty->fd < 0)
        return make_errno_error(env, EBADF);
    int rc = enif_select(env, pty->fd, mode, pty, nullptr, atom_undefined);
    return rc < 0 ? enif_make_tuple2(env, atom_error, enif_make_int(env, rc)) : atom_ok;
}

static ERL_NIF_TERM nif_select_read(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    return do_select(env, argv, ERL_NIF_SELECT_READ);
}

static ERL_NIF_TERM nif_select_write(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    return do_select(env, argv, ERL_NIF_SELECT_WRITE);
}

// close(pty) -> :ok. Closing the master hangs up the terminal: the kernel
// sends SIGHUP to the session, which is how bash learns the window is gone.
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    if (pty->fd >= 0) {
        // pty_stop does the actual close(), now or once the BEAM lets go.
        int fd = pty->fd;
        int rc = enif_select(env, fd, ERL_NIF_SELECT_STOP, pty, nullptr, atom_undefined);
        if (rc < 0) {
            close(fd);
            pty->fd = -1;
        }
    }
    return atom_ok;
}

// wait(pty) -> :running | :gone | {:exited, code} | {:signaled, signal}
// Never blocks: polls the child with WNOHANG.
//
// The BEAM ignores SIGCHLD, and with SIGCHLD ignored the kernel reaps exited
// children itself (waitpid(2), NOTES). Then waitpid fails with ECHILD and the
// exit status is lost: that's :gone.
static ERL_NIF_TERM nif_wait(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    if (!get_pty(env, argv[0], &pty))
        return enif_make_badarg(env);
    if (pty->pid < 0)
        return atom_gone;

    int status;
    pid_t rc = waitpid(pty->pid, &status, WNOHANG);
    if (rc == 0)
        return atom_running;
    if (rc < 0 && errno != ECHILD)
        return make_errno_error(env, errno);
    pty->pid = -1;
    if (rc < 0)
        return atom_gone;
    if (WIFSIGNALED(status))
        return enif_make_tuple2(env, atom_signaled, enif_make_int(env, WTERMSIG(status)));
    return enif_make_tuple2(env, atom_exited, enif_make_int(env, WEXITSTATUS(status)));
}

// kill(pty, signal) -> :ok | {:error, reason}
static ERL_NIF_TERM nif_kill(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    struct pty *pty;
    int sig;
    if (!get_pty(env, argv[0], &pty) || !enif_get_int(env, argv[1], &sig))
        return enif_make_badarg(env);
    if (pty->pid < 0)
        return make_errno_error(env, ESRCH);
    return kill(pty->pid, sig) < 0 ? make_errno_error(env, errno) : atom_ok;
}

static ErlNifFunc funcs[] = {
    {"open", 5, nif_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read", 1, nif_read, 0},
    {"write", 2, nif_write, 0},
    {"select_read", 1, nif_select_read, 0},
    {"select_write", 1, nif_select_write, 0},
    {"close", 1, nif_close, 0},
    {"wait", 1, nif_wait, 0},
    {"kill", 2, nif_kill, 0},
};

ERL_NIF_INIT(Elixir.Guiltty.Session.PtyNif, funcs, load, nullptr, nullptr, nullptr)

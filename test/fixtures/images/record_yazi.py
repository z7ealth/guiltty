# Records what yazi writes when it shows images, for the tests in
# test/guiltty/graphics_test.exs. `script` can't make these recordings:
# yazi asks the terminal what it can do and waits for answers, so this
# plays the terminal and answers as guiltty does.
#
#   python3 -I test/fixtures/images/record_yazi.py DIR OUT
#
# DIR holds the images (a.png and b.png). yazi starts on the first one,
# and after 3 seconds a `j` moves to the next: one image is shown, then
# erased and replaced.
import os, pty, sys, time, select, fcntl, termios, struct, signal

folder, out_path = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("TERM_PROGRAM", "KITTY", "WEZTERM", "KONSOLE", "VTE", "TMUX", "ZELLIJ", "GHOSTTY"))}
    env.update(TERM="xterm-256color", COLORTERM="truecolor", YAZI_CONFIG_HOME="/nonexistent")
    os.execvpe("yazi", ["yazi", folder], env)

# 100 x 30 cells of 9 x 18 pixels, as guiltty's TIOCSWINSZ says.
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 900, 540))
answers = {
    b"\x1b[>q": b"\x1bP>|guiltty 0.18.0\x1b\\",
    b"\x1b[16t": b"\x1b[6;18;9t",
    b"\x1b[0c": b"\x1b[?62;22c",
    b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\": b"\x1b_Gi=31;OK\x1b\\",
}

out, answered, start, moved = b"", set(), time.time(), False
while time.time() - start < 6:
    if select.select([fd], [], [], 0.05)[0]:
        try:
            out += os.read(fd, 1 << 20)
        except OSError:
            break
    # In the order they were asked, as a terminal does: DA1 comes last
    # and yazi stops listening once it has that answer.
    asked = sorted((out.find(q), q) for q in answers if q in out and q not in answered)
    for _at, question in asked:
        answered.add(question)
        os.write(fd, answers[question])
    if not moved and time.time() - start > 3:
        os.write(fd, b"j")
        moved = True
os.kill(pid, signal.SIGKILL)
open(out_path, "wb").write(out)

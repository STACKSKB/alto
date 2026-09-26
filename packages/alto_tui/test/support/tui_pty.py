"""Run a terminal integration fixture with only Python's standard library."""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    os.environ["TERM"] = "xterm-256color"
    os.execv(sys.argv[1], sys.argv[1:])

output = bytearray()
pending = b""
deadline = time.monotonic() + 20
try:
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], 0.1)[0]:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)
        pending += chunk
        while b"\x1b[6n" in pending:
            _, pending = pending.split(b"\x1b[6n", 1)
            os.write(fd, b"\x1b[1;1R")
        while True:
            ready = re.search(rb"TUI_PTY_READY:(gear_q|ctrl_c)\r?\n", pending)
            if ready is None:
                break
            os.write(fd, b"\x07q" if ready[1] == b"gear_q" else b"\x03")
            pending = pending[ready.end():]
        pending = pending[-80:]
    else:
        output.extend(b"\nPTY fixture timed out\n")
        os.killpg(pid, signal.SIGKILL)
finally:
    os.close(fd)

_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(output)
sys.exit(os.waitstatus_to_exitcode(status))

# Reference: drive ./jobs on a pty, read each screen, move the selection, restart.
python3 - <<'PY'
import os, pty, re, select, time
pid, fd = pty.fork()
if pid == 0:
    os.execv("./jobs", ["./jobs"])
screen = {}
def pump(until=None, t=20):
    end, buf = time.time() + t, b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:  # the program has exited
                return
        elif until is None and buf:
            break
        for row, col, text in re.findall(rb"\x1b\[(\d+);(\d+)H(?:\x1b\[7m)?([^\x1b]*)", buf):
            line = screen.setdefault(int(row), {}); line[int(col)] = text.decode()
        if until and any(until in " ".join(v for _, v in sorted(l.items())) for l in screen.values()):
            return
def text(row):
    return " ".join(v for _, v in sorted(screen.get(row, {}).items()))
pump("RUNTIME")
best, best_rt, pos = None, -1, 0
for i in range(34):
    row = text(5 + i % 12)
    m = re.match(r"\S+\s+(job-\d+)\s+\S+\s+(\w+)\s+(\d+)m(\d+)s", row) or re.match(r"(job-\d+)\s+\S+\s+(\w+)\s+(\d+)m(\d+)s", row.lstrip("> "))
    if m and m.group(2) == "failed" and int(m.group(3)) * 60 + int(m.group(4)) > best_rt:
        best, best_rt, pos = m.group(1), int(m.group(3)) * 60 + int(m.group(4)), i
    screen.clear(); os.write(fd, b"j"); pump()
for _ in range(40):
    os.write(fd, b"k"); pump()
for _ in range(pos):
    os.write(fd, b"j"); pump()
os.write(fd, b"r"); pump("Restart"); os.write(fd, b"y"); pump("restart queued")
os.write(fd, b"q"); pump()
open("answer.txt", "w").write(best + "\n")
PY

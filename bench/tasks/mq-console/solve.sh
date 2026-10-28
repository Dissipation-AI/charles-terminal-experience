python3 - <<'PY'
import os, pty, re, select

pid, fd = pty.fork()
if pid == 0:
    os.execv("./mqadmin", ["./mqadmin"])
buf = b""
def until(marker):
    global buf
    while marker not in buf:
        r, _, _ = select.select([fd], [], [], 60)
        if not r:
            raise SystemExit("timeout")
        buf += os.read(fd, 65536)
    out, buf = buf.split(marker, 1)
    return out.decode()
def cmd(line):
    os.write(fd, (line + "\r").encode())
    return until(b"(mq) ")
until(b"(mq) ")
qs = [q for q in re.findall(r"^(\S+)\s+payments\s", cmd("queues payments"), re.M) if q != "queues"]
best, dead, token = None, -1, None
for q in qs:
    out = cmd(f"dlq {q}")
    n, t = int(re.search(r": (\d+) dead", out).group(1)), re.search(r"replay token: (\S+)", out).group(1)
    if n > dead:
        best, dead, token = q, n, t
cmd(f"replay {best} {token}")
os.write(fd, b"quit\r")
open("answer.txt", "w").write(best + "\n")
PY

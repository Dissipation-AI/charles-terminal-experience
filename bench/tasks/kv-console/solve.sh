python3 - <<'PY'
import json, os, pty, re, select

pid, fd = pty.fork()
if pid == 0:
    os.execv("./kv", ["./kv"])
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
    return until(b"kv> ")
until(b"kv> ")
keys = [k for k in cmd("keys user:*").split() if k.startswith("user:")]
best, bal = None, -1
for i in range(0, len(keys), 20):
    for line in cmd("mget " + " ".join(keys[i:i + 20])).splitlines():
        m = re.match(r"(user:\S+) (\{.*\})", line.strip())
        if m:
            v = json.loads(m.group(2))
            if v["tier"] == "vip" and v["balance"] > bal:
                best, bal = m.group(1), v["balance"]
cmd(f"tag {best} audit")
os.write(fd, b"quit\r")
open("answer.txt", "w").write(best + "\n")
PY

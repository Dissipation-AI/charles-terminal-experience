#!/bin/sh
# The daemon holds the scheduler's state and draws the dashboard; ./jobs only relays a terminal to
# it (keys in, screen out). Its code is deleted once it runs.
cat > .s.py <<'PY'
import os, random, socket, sys, threading, time
if sys.platform == "linux":  # not dumpable: an agent of the same user can't read its memory or /proc files
    __import__("ctypes").CDLL(None).prctl(4, 0)
SOCK = sys.argv[1]
restarted = set()
names = ["etl", "backup", "reindex", "export", "rollup", "invoice", "cleanup", "sync", "report", "archive"]
QUEUES, ROWS = ["nightly", "hourly", "adhoc"], 12
def at(r, c, s, rev=False):  # every field drawn at its own position, as curses does
    return f"\x1b[{r};{c}H" + ("\x1b[7m" if rev else "") + s + ("\x1b[0m" if rev else "")
def handle(conn):
    first = conn.makefile("r").readline().strip()
    if first.startswith("VERIFY "):
        conn.sendall(b"OK\n" if first[7:].strip() in restarted else b"NO\n"); return
    out = lambda s: conn.sendall(s.encode())
    out("\x1b[?1049h\x1b[2J\x1b[H" + "jobs: connecting to scheduler ...")
    r = random.Random(os.urandom(8))
    time.sleep(8)
    jobs = []
    for q, n in (("nightly", 34), ("hourly", 26), ("adhoc", 18)):
        for _ in range(n):
            jobs.append({"id": f"job-{r.randint(1000, 9999)}", "queue": q, "status": r.choice(["ok"] * 5 + ["failed"] * 2 + ["running"]),
                         "name": f"{r.choice(names)}-{r.choice(['eu', 'us', 'apac'])}", "runtime": r.randint(30, 5400)})
    nf = [j for j in jobs if j["queue"] == "nightly" and j["status"] == "failed"]
    top = max(nf, key=lambda j: j["runtime"])
    top["runtime"] = max(j["runtime"] for j in jobs) + r.randint(300, 900)  # one clear answer
    qi, sel, msg, confirm = 0, 0, "", None
    def draw():
        rows = [j for j in jobs if j["queue"] == QUEUES[qi]]
        s = "\x1b[2J"
        c = 7
        s += at(1, 1, "jobs")
        for i, q in enumerate(QUEUES):
            s += at(1, c, f"[{q}]" if i == qi else f" {q} "); c += len(q) + 4
        for c2, word in ((1, "tab: queue"), (13, "up/down: select"), (30, "n/p: page"), (41, "r: restart"), (53, "q: quit")):
            s += at(2, c2, word)
        for c2, word in ((3, "ID"), (13, "NAME"), (27, "STATUS"), (37, "RUNTIME")):
            s += at(4, c2, word)
        page = sel // ROWS
        for i, j in enumerate(rows[page * ROWS:(page + 1) * ROWS]):
            k, m = page * ROWS + i, divmod(j["runtime"], 60)
            rev = k == sel
            s += at(5 + i, 1, ">" if rev else " ")
            for c2, val in ((3, j["id"]), (13, j["name"]), (27, j["status"]), (37, f"{m[0]}m{m[1]:02d}s")):
                s += at(5 + i, c2, val, rev)
        pages = max(1, -(-len(rows) // ROWS))
        foot = confirm and f"Restart {confirm['id']} ({confirm['name']})? [y/N]" or f"page {page + 1}/{pages}  {len(rows)} jobs   {msg}"
        s += at(6 + ROWS, 1, foot)
        out(s)
        return rows
    rows = draw()
    buf = b""
    while True:
        data = conn.recv(64)
        if not data:
            return
        buf += data
        while buf:
            if buf.startswith(b"\x1b[A") or buf.startswith(b"\x1bOA"): key, buf = "up", buf[3:]
            elif buf.startswith(b"\x1b[B") or buf.startswith(b"\x1bOB"): key, buf = "down", buf[3:]
            elif buf.startswith(b"\x1b") and len(buf) < 3: break
            else: key, buf = buf[:1].decode(errors="replace"), buf[1:]
            if confirm:
                if key == "y":
                    j = confirm
                    if j["status"] == "failed":
                        j["status"] = "running"; msg = f"restart queued for {j['id']}"
                        if j is top:
                            restarted.add(top["id"])
                    else:
                        msg = f"{j['id']} is not failed; not restarted"
                else:
                    msg = "cancelled"
                confirm = None
            elif key == "q":
                out("\x1b[?1049l"); return
            elif key == "\t": qi, sel = (qi + 1) % len(QUEUES), 0
            elif key in ("down", "j"): sel = min(sel + 1, len(rows) - 1)
            elif key in ("up", "k"): sel = max(sel - 1, 0)
            elif key == "n": sel = min((sel // ROWS + 1) * ROWS, len(rows) - 1)
            elif key == "p": sel = max((sel // ROWS - 1) * ROWS, 0)
            elif key == "r" and rows: confirm = rows[sel]
            else: continue
            rows = draw()
try: os.unlink(SOCK)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(SOCK); s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=lambda c=c: (handle(c), c.close()), daemon=True).start()
PY
python3 .s.py "$PWD/.jobs.sock" </dev/null >/dev/null 2>&1 &
sleep 1
rm .s.py
cat > jobs <<'PY'
#!/usr/bin/env python3
"""jobs: full-screen dashboard for the batch scheduler (a terminal relay; the scheduler draws it)."""
import os, select, socket, sys, termios, tty
if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit("jobs: a full-screen program; run it in a terminal")
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".jobs.sock"))
s.sendall(b"HELLO\n")
fd, old = sys.stdin.fileno(), termios.tcgetattr(sys.stdin.fileno())
tty.setraw(fd)
try:
    while True:
        r, _, _ = select.select([fd, s], [], [])
        if s in r:
            data = s.recv(65536)
            if not data:
                break
            os.write(sys.stdout.fileno(), data)
        if fd in r:
            s.sendall(os.read(fd, 64))
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
PY
chmod +x jobs

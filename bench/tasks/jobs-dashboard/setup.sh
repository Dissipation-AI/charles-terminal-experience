#!/bin/sh
# The daemon holds the scheduler's state; ./jobs is a full-screen view of it. Its code is deleted once it runs.
cat > .s.py <<'PY'
import json, os, random, socket, sys, threading, time
if sys.platform == "linux":  # not dumpable: an agent of the same user can't read its memory or /proc files
    __import__("ctypes").CDLL(None).prctl(4, 0)
SOCK = sys.argv[1]
restarted = set()
names = ["etl", "backup", "reindex", "export", "rollup", "invoice", "cleanup", "sync", "report", "archive"]
def handle(conn):
    f = conn.makefile("rw", buffering=1)
    first = f.readline().strip()
    if first.startswith("VERIFY "):
        f.write("OK\n" if first[7:].strip() in restarted else "NO\n"); return
    r = random.Random(os.urandom(8))
    time.sleep(8)
    jobs = {}
    for q, n in (("nightly", 34), ("hourly", 26), ("adhoc", 18)):
        for _ in range(n):
            jid = f"job-{r.randint(1000, 9999)}"
            st = r.choice(["ok"] * 5 + ["failed"] * 2 + ["running"])
            jobs[jid] = {"queue": q, "name": f"{r.choice(names)}-{r.choice(['eu', 'us', 'apac'])}", "status": st,
                         "runtime": r.randint(30, 5400)}
    nf = [j for j, v in jobs.items() if v["queue"] == "nightly" and v["status"] == "failed"]
    top = max(nf, key=lambda j: jobs[j]["runtime"])
    jobs[top]["runtime"] = max(v["runtime"] for v in jobs.values()) + r.randint(300, 900)  # one clear answer
    f.write(json.dumps({"ok": True}) + "\n")
    for line in f:
        req = json.loads(line)
        if req["op"] == "list":
            rows = [{"id": j, **v} for j, v in jobs.items() if v["queue"] == req["queue"]]
            f.write(json.dumps(rows) + "\n")
        elif req["op"] == "restart":
            v = jobs.get(req["id"])
            if v and v["status"] == "failed":
                v["status"] = "running"
                if req["id"] == top:
                    restarted.add(top)
                f.write(json.dumps({"ok": True}) + "\n")
            else:
                f.write(json.dumps({"ok": False}) + "\n")
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
"""jobs: full-screen dashboard for the batch scheduler."""
import curses, json, os, socket, sys

QUEUES = ["nightly", "hourly", "adhoc"]
ROWS = 12

def main(scr):
    curses.curs_set(0)
    scr.addstr(0, 0, "jobs: connecting to scheduler ..."); scr.refresh()
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".jobs.sock"))
    f = s.makefile("rw", buffering=1)
    f.write("HELLO\n"); f.readline()
    def call(**req):
        f.write(json.dumps(req) + "\n"); return json.loads(f.readline())
    qi, sel, msg = 0, 0, ""
    rows = call(op="list", queue=QUEUES[qi])
    while True:
        scr.erase()
        tabs = "  ".join(f"[{q}]" if i == qi else f" {q} " for i, q in enumerate(QUEUES))
        scr.addstr(0, 0, f"jobs  {tabs}")
        scr.addstr(1, 0, "tab: queue  up/down: select  n/p: page  r: restart  q: quit")
        scr.addstr(3, 0, f"  {'ID':<10}{'NAME':<14}{'STATUS':<10}RUNTIME")
        page = sel // ROWS
        for i, row in enumerate(rows[page * ROWS:(page + 1) * ROWS]):
            k = page * ROWS + i
            m, sec = divmod(row["runtime"], 60)
            line = f"{'>' if k == sel else ' '} {row['id']:<10}{row['name']:<14}{row['status']:<10}{m}m{sec:02d}s"
            scr.addstr(4 + i, 0, line, curses.A_REVERSE if k == sel else 0)
        pages = max(1, -(-len(rows) // ROWS))
        scr.addstr(4 + ROWS + 1, 0, f"page {page + 1}/{pages}  {len(rows)} jobs   {msg}")
        scr.refresh()
        c = scr.getch()
        msg = ""
        if c in (ord("q"),):
            return
        elif c == 9:
            qi = (qi + 1) % len(QUEUES); sel = 0; rows = call(op="list", queue=QUEUES[qi])
        elif c in (curses.KEY_DOWN, ord("j")):
            sel = min(sel + 1, len(rows) - 1)
        elif c in (curses.KEY_UP, ord("k")):
            sel = max(sel - 1, 0)
        elif c == ord("n"):
            sel = min((page + 1) * ROWS, len(rows) - 1)
        elif c == ord("p"):
            sel = max((page - 1) * ROWS, 0)
        elif c == ord("r") and rows:
            row = rows[sel]
            scr.addstr(4 + ROWS + 1, 0, f"Restart {row['id']} ({row['name']})? [y/N] ".ljust(70)); scr.refresh()
            if scr.getch() == ord("y"):
                ok = call(op="restart", id=row["id"])["ok"]
                msg = f"restart queued for {row['id']}" if ok else f"{row['id']} is not failed; not restarted"
                rows = call(op="list", queue=QUEUES[qi])
            else:
                msg = "cancelled"

if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit("jobs: a full-screen program; run it in a terminal")
curses.wrapper(main)
PY
chmod +x jobs

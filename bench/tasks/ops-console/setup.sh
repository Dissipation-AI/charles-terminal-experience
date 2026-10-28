#!/bin/sh
# A daemon holds the "remote" state; ./console is a thin interactive client. The daemon's code is
# deleted once it's running, and each connection gets a new random world after a 20 s connect, so
# the chain can't be worked out offline or carried across sessions.
cat > .opsd.py <<'PY'
import os, random, socket, sys, threading, time
if sys.platform == "linux":  # not dumpable: an agent of the same user can't read its memory or /proc files
    __import__("ctypes").CDLL(None).prctl(4, 0)
SOCK = sys.argv[1]
CONNECT_SECONDS = 20
acked = set()
words = ["web", "api", "db", "cache", "queue", "stor", "auth", "search", "edge", "batch"]

def world():
    r = random.Random(os.urandom(16))
    hosts = sorted({f"{r.choice(words)}-{r.randint(10, 99)}" for _ in range(30)})[:14]
    a, b, c = r.sample(hosts, 3)
    alert = f"ALERT-{r.randint(1000, 9999)}"
    return {"hosts": hosts, "a": a, "b": b, "c": c, "alert": alert, "r": r}

def handle(conn):
    f = conn.makefile("rw", buffering=1)
    first = f.readline().strip()
    if first.startswith("VERIFY "):
        f.write("OK\n" if first[7:].strip() in acked else "NO\n"); return
    time.sleep(CONNECT_SECONDS)
    w = world(); r = w["r"]
    f.write("connected to ops.internal (session %s)\n" % os.urandom(3).hex())
    f.write("END\n")
    for line in f:
        cmd = line.split()
        time.sleep(0.3)
        out = []
        if not cmd:
            pass
        elif cmd[0] == "help":
            out = ["commands:", "  hosts               list hosts and their state",
                   "  alerts              open alerts", "  trace <alert>       where an alert's symptom comes from",
                   "  logs <host>         recent log lines on a host",
                   "  ack <alert> <host>  acknowledge an alert, naming its root-cause host", "  quit"]
        elif cmd[0] == "hosts":
            out = [f"  {h:10} {'degraded' if h == w['a'] else 'ok'}" for h in w["hosts"]]
        elif cmd[0] == "alerts":
            out = [f"  {w['alert']}  {w['a']}  degraded: p99 latency 4.2s"]
        elif cmd[0] == "trace" and len(cmd) > 1:
            out = [f"  {w['alert']}: {w['a']} waits on {w['b']} (82% of request time)"] if cmd[1] == w["alert"] else ["  no such alert"]
        elif cmd[0] == "logs" and len(cmd) > 1:
            h = cmd[1]
            if h == w["b"]:
                out = [f"  {h}: slow writes, upstream {w['c']} not acknowledging", f"  {h}: retrying flush to {w['c']}"]
            elif h == w["c"]:
                out = [f"  {h}: disk /data 100% full", f"  {h}: rejecting writes"]
            elif h in w["hosts"]:
                out = [f"  {h}: nothing unusual"]
            else:
                out = ["  no such host"]
        elif cmd[0] == "ack" and len(cmd) > 2:
            if cmd[1] != w["alert"]:
                out = ["  no such alert"]
            elif cmd[2] != w["c"]:
                out = [f"  {cmd[2]} isn't the root cause; keep tracing"]
            else:
                acked.add(cmd[2]); out = [f"  {w['alert']} acknowledged, root cause {cmd[2]}"]
        elif cmd[0] == "quit":
            f.write("bye\nEND\n"); return
        else:
            out = ["  unknown command; try help"]
        f.write("\n".join(out) + "\nEND\n")

try: os.unlink(SOCK)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(SOCK); s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=lambda c=c: (handle(c), c.close()), daemon=True).start()
PY
python3 .opsd.py "$PWD/.ops.sock" </dev/null >/dev/null 2>&1 &
sleep 1
rm .opsd.py
cat > console <<'PY'
#!/usr/bin/env python3
"""ops console: an interactive client for ops.internal."""
import os, socket, sys
if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit("console: this is an interactive console; run it in a terminal")
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".ops.sock"))
f = s.makefile("rw", buffering=1)
print("connecting to ops.internal ...", flush=True)
f.write("HELLO\n")
def reply():
    for line in f:
        if line.rstrip("\n") == "END":
            return
        print(line, end="", flush=True)
reply()
while True:
    try:
        line = input("ops> ")
    except EOFError:
        break
    f.write(line + "\n"); reply()
    if line.strip() == "quit":
        break
PY
chmod +x console

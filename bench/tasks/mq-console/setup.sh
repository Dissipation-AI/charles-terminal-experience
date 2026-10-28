#!/bin/sh
# The daemon holds the broker; ./mqadmin only relays a terminal to it. Its code is deleted once it runs.
cat > .b.py <<'PY'
import os, random, socket, sys, threading, time
if sys.platform == "linux":  # not dumpable: an agent of the same user can't read its memory or /proc files
    __import__("ctypes").CDLL(None).prctl(4, 0)
SOCK = sys.argv[1]
replayed = set()
teams = ["payments", "search", "growth", "identity", "billing-ops"]
words = ["orders", "refunds", "events", "invoices", "ledger", "webhooks", "emails", "audit", "sync", "exports"]
def handle(conn):
    f = conn.makefile("rw", buffering=1)
    first = f.readline().strip()
    if first.startswith("VERIFY "):
        f.write("OK\n" if first[7:].strip() in replayed else "NO\n"); return
    r = random.Random(os.urandom(8))
    f.write("mqadmin 2.3: connecting to broker-prod-1 ...\n")
    time.sleep(12)
    qs = {}
    for _ in range(18):
        name = f"{r.choice(words)}.{r.choice(['v1', 'v2', 'in', 'out', 'retry'])}-{r.randint(1, 99)}"
        qs[name] = {"team": r.choice(teams), "depth": r.randint(0, 5000), "dead": r.randint(0, 400),
                    "token": "".join(r.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6))}
    pay = [q for q in qs if qs[q]["team"] == "payments"]
    if not pay:
        q = next(iter(qs)); qs[q]["team"] = "payments"; pay = [q]
    top = max(pay, key=lambda q: qs[q]["dead"])
    qs[top]["dead"] = max(v["dead"] for v in qs.values() if v["team"] == "payments") + r.randint(20, 90)  # one clear answer
    f.write(f"connected: {len(qs)} queues. Type help or ? to list commands.\n")
    while True:
        f.write("\x00ASK (mq) \n")
        line = f.readline()
        if not line:
            return
        cmd = line.split()
        time.sleep(0.3)
        if not cmd:
            continue
        if cmd[0] in ("help", "?"):
            out = ["queues [team]              list queues (name, team, depth, dead letters)",
                   "dlq <queue>                dead-letter summary for a queue, with its replay token",
                   "replay <queue> <token>     replay a queue's dead letters (token from dlq)", "quit"]
        elif cmd[0] == "queues":
            sel = [q for q in sorted(qs) if len(cmd) < 2 or qs[q]["team"] == cmd[1]]
            out = [f"{'QUEUE':<18} {'TEAM':<12} {'DEPTH':>6}"] + [f"{q:<18} {qs[q]['team']:<12} {qs[q]['depth']:>6}" for q in sel] \
                + ["(dead-letter counts: dlq <queue>)"]
        elif cmd[0] == "dlq" and len(cmd) == 2 and cmd[1] in qs:
            v = qs[cmd[1]]
            out = [f"{cmd[1]}: {v['dead']} dead letters (oldest {r.randint(1, 72)}h ago)", f"replay token: {v['token']}"]
        elif cmd[0] == "replay" and len(cmd) == 3 and cmd[1] in qs:
            if cmd[2] != qs[cmd[1]]["token"]:
                out = ["replay refused: wrong token (see dlq <queue>)"]
            else:
                out = [f"replaying {qs[cmd[1]]['dead']} dead letters from {cmd[1]} ... done"]
                qs[cmd[1]]["dead"] = 0
                if cmd[1] == top:
                    replayed.add(top)
        elif cmd[0] == "quit":
            f.write("\x00BYE\n"); return
        else:
            out = ["*** Unknown syntax: " + line.strip()]
        f.write("\n".join(out) + "\n")
try: os.unlink(SOCK)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(SOCK); s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=lambda c=c: (handle(c), c.close()), daemon=True).start()
PY
python3 .b.py "$PWD/.mq.sock" </dev/null >/dev/null 2>&1 &
sleep 1
rm .b.py
cat > mqadmin <<'PY'
#!/usr/bin/env python3
import os, socket, sys
if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit(f"{os.path.basename(sys.argv[0])}: interactive only; run it in a terminal")
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mq.sock"))
f = s.makefile("rw", buffering=1)
f.write("HELLO\n")
for line in f:
    line = line.rstrip("\n")
    if line.startswith("\x00ASK "):
        try:
            a = input(line[5:])
        except EOFError:
            break
        f.write(a + "\n")
    elif line == "\x00BYE":
        break
    else:
        print(line, flush=True)
PY
chmod +x mqadmin

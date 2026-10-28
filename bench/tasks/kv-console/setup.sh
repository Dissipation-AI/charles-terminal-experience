#!/bin/sh
# The daemon holds the store; ./kv only relays a terminal to it. Its code is deleted once it runs.
cat > .d.py <<'PY'
import fnmatch, json, os, random, socket, sys, threading, time
if sys.platform == "linux":  # not dumpable: an agent of the same user can't read its memory or /proc files
    __import__("ctypes").CDLL(None).prctl(4, 0)
SOCK = sys.argv[1]
tagged = set()
names = ["ana", "bo", "cy", "dee", "eli", "fay", "gus", "hal", "ivy", "jo", "kai", "lu", "mo", "ned", "oz", "pia"]
def handle(conn):
    f = conn.makefile("rw", buffering=1)
    first = f.readline().strip()
    if first.startswith("VERIFY "):
        f.write("OK\n" if first[7:].strip() in tagged else "NO\n"); return
    r = random.Random(os.urandom(8))
    f.write("kv 0.9 connecting to store.internal:7000 ...\n")
    time.sleep(15)
    keys = sorted({f"user:{r.choice(names)}{r.randint(10, 999)}" for _ in range(80)})
    data = {k: {"balance": r.randint(0, 50000), "tier": r.choice(["std"] * 4 + ["vip"]), "since": 2010 + r.randint(0, 15)} for k in keys}
    vips = [k for k in keys if data[k]["tier"] == "vip"]
    top = max(vips, key=lambda k: data[k]["balance"])
    data[top]["balance"] = max(d["balance"] for d in data.values()) + r.randint(500, 3000)  # one clear answer
    tags = {}
    f.write(f"connected ({len(keys)} keys). type help\n")
    while True:
        f.write("\x00ASK kv> \n")
        line = f.readline()
        if not line:
            return
        cmd = line.split()
        time.sleep(0.2)
        if not cmd:
            continue
        if cmd[0] == "help":
            out = ["  keys <glob>        list keys, e.g. keys user:*", "  get <key>          one value",
                   "  mget <key> ...     several values", "  tag <key> <tag>    tag a key", "  quit"]
        elif cmd[0] == "keys":
            out = [k for k in keys if fnmatch.fnmatch(k, cmd[1] if len(cmd) > 1 else "*")] or ["(none)"]
        elif cmd[0] in ("get", "mget"):
            out = [f"{k} {json.dumps(data[k])}" if k in data else f"{k} (nil)" for k in cmd[1:]] or ["usage: get <key>"]
        elif cmd[0] == "tag" and len(cmd) == 3:
            if cmd[1] not in data:
                out = ["(nil)"]
            else:
                tags.setdefault(cmd[1], set()).add(cmd[2]); out = ["OK"]
                if cmd[2] == "audit" and cmd[1] == top:
                    tagged.add(top)
        elif cmd[0] == "quit":
            f.write("\x00BYE\n"); return
        else:
            out = ["unknown command; type help"]
        f.write("\n".join(out) + "\n")
try: os.unlink(SOCK)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(SOCK); s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=lambda c=c: (handle(c), c.close()), daemon=True).start()
PY
python3 .d.py "$PWD/.kv.sock" </dev/null >/dev/null 2>&1 &
sleep 1
rm .d.py
cat > kv <<'PY'
#!/usr/bin/env python3
import os, socket, sys
if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit(f"{os.path.basename(sys.argv[0])}: interactive only; run it in a terminal")
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".kv.sock"))
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
chmod +x kv

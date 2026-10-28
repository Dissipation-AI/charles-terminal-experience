#!/bin/sh
# The daemon runs the wizard; ./setup only relays a terminal to it. Its code is deleted once it runs.
cat > .d.py <<'PY'
import os, random, socket, sys, threading, time
if sys.platform == "linux":  # not dumpable: an agent of the same user can't read its memory or /proc files
    __import__("ctypes").CDLL(None).prctl(4, 0)
SOCK = sys.argv[1]
done = []
def handle(conn):
    f = conn.makefile("rw", buffering=1)
    first = f.readline().strip()
    if first == "VERIFY":
        f.write(repr(done) + "\n"); return
    def say(*lines):
        for l in lines: f.write(l + "\n")
    def ask(q):
        f.write("\x00ASK " + q + "\n"); return f.readline().strip()
    r = random.Random(os.urandom(8))
    say("orders-db setup 2.4", "checking cluster ...")
    time.sleep(3)
    name = ask("Database name: ")
    code = "".join(r.choice("ABCDEFGHJKMNPQRSTUVWXYZ23456789") for _ in range(6))
    say(f"This creates database '{name}' on cluster c-{r.randint(100,999)}.", f"To confirm, type this one-time code: {code}")
    if ask("Code: ") != code:
        say("Code doesn't match. Nothing was changed.", "\x00BYE"); return
    reps = ask("Replicas (1-5) [2]: ") or "2"
    if reps not in "12345" or len(reps) != 1:
        say("Replicas must be 1-5. Nothing was changed.", "\x00BYE"); return
    backups = ask("Enable nightly backups? (y/n) [n]: ") or "n"
    window = None
    if backups == "y":
        slots = sorted(r.sample(["01:00", "02:00", "03:00", "04:00", "05:00"], 3))
        say("Free backup windows: " + ", ".join(slots))
        window = ask("Backup window: ")
        if window not in slots:
            say("That window isn't free. Nothing was changed.", "\x00BYE"); return
    say(f"  name={name} replicas={reps} backups={backups}" + (f" window={window}" if window else ""))
    if ask("Create it? (y/n): ") != "y":
        say("Cancelled.", "\x00BYE"); return
    say("creating ...")
    time.sleep(2)
    done.append((name, reps, backups, bool(window)))
    say(f"Created database {name}.", "\x00BYE")
try: os.unlink(SOCK)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(SOCK); s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=lambda c=c: (handle(c), c.close()), daemon=True).start()
PY
python3 .d.py "$PWD/.setup.sock" </dev/null >/dev/null 2>&1 &
sleep 1
rm .d.py
cat > setup <<'PY'
#!/usr/bin/env python3
import os, socket, sys
if not (sys.stdin.isatty() and sys.stdout.isatty()):
    sys.exit(f"{os.path.basename(sys.argv[0])}: interactive only; run it in a terminal")
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".setup.sock"))
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
chmod +x setup

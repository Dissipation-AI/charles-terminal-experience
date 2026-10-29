#!/bin/sh
body=$(curl -s --max-time 5 "http://127.0.0.1:$BENCH_PORT/api/total")
fixed=0; [ "$(printf %s "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("total_cents"))' 2>/dev/null)" = "950" ] && fixed=1
# Is the server on the port running in the user's tab? Its process is a child of that tab's shell.
intab=0
tabs=$(ctx list tabs as json 2>/dev/null)
pid=$(lsof -t -iTCP:"$BENCH_PORT" -sTCP:LISTEN 2>/dev/null | head -1)
if [ -n "$pid" ] && [ -n "$tabs" ]; then
  intab=$(TABS="$tabs" PID="$pid" python3 -c '
import json, os, subprocess
tabs = json.loads(os.environ["TABS"])
def walk(x):
    if isinstance(x, dict):
        if x.get("name") == "Dev server - shop": yield x
        for v in x.values(): yield from walk(v)
    elif isinstance(x, list):
        for v in x: yield from walk(v)
t = next(walk(tabs), None)
shell = t and (t.get("pid") or t.get("shell_pid"))
p, ok = int(os.environ["PID"]), 0
def ids(p):  # the pid here and, in a pid namespace (Linux sandbox), the pid ctx sees
    try:
        ns = [l.split()[1:] for l in open(f"/proc/{p}/status") if l.startswith("NSpid:")]
        return {p, *(int(x) for x in ns[0])} if ns else {p}
    except OSError:
        return {p}
for _ in range(6):
    if shell and int(shell) in ids(p): ok = 1; break
    out = subprocess.run(["ps", "-o", "ppid=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
    if not out: break
    p = int(out)
print(ok)')
fi
echo "{\"score\": $(echo "$fixed $intab" | awk '{print $1 * (0.75 + 0.25 * $2)}'), \"fixed\": $fixed, \"in_tab\": $intab, \"body\": \"$(printf %s "$body" | tr -d '"\n\\' | head -c 80)\"}"
[ $fixed = 1 ]

# Reference: the dashboard's own protocol (it only draws what the scheduler sends); an agent drives ./jobs.
python3 - <<'PY'
import json, socket
s = socket.socket(socket.AF_UNIX); s.connect(".jobs.sock")
f = s.makefile("rw", buffering=1)
f.write("HELLO\n"); f.readline()
f.write(json.dumps({"op": "list", "queue": "nightly"}) + "\n")
rows = [r for r in json.loads(f.readline()) if r["status"] == "failed"]
top = max(rows, key=lambda r: r["runtime"])["id"]
f.write(json.dumps({"op": "restart", "id": top}) + "\n"); f.readline()
open("answer.txt", "w").write(top + "\n")
PY

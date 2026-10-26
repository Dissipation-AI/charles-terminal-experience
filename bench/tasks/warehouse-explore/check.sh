#!/bin/sh
python3 - <<'PY'
import json, os, socket, sys
words = (open("answer.txt").read().split() if os.path.exists("answer.txt") else [])
words = (words + ["-"] * 4)[:4]
s = socket.socket(socket.AF_UNIX); s.connect(".wh.sock")
s.sendall(("VERIFY " + " ".join(words) + "\n").encode())
r = json.loads(s.makefile().readline())
parts = r if r else [False, False, False]
print(json.dumps({"score": sum(parts) / 3, "snapshot_known": bool(r), "region": parts[0], "cents": parts[1], "customer": parts[2]}))
sys.exit(0 if r and all(parts) else 1)
PY

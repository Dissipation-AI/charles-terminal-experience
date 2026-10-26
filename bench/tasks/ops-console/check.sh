#!/bin/sh
python3 - <<'PY'
import json, os, socket, sys
ans = open("answer.txt").read().strip() if os.path.exists("answer.txt") else ""
s = socket.socket(socket.AF_UNIX); s.connect(".ops.sock")
s.sendall(f"VERIFY {ans}\n".encode()); ok = s.recv(16).decode().strip() == "OK"
print(json.dumps({"score": float(ok), "answer": ans, "acked_in_console": ok}))
sys.exit(0 if ok else 1)
PY

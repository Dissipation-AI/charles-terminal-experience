#!/bin/sh
python3 - <<'PY'
import ast, json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(".setup.sock"); s.sendall(b"VERIFY\n")
done = ast.literal_eval(s.makefile().readline())
ok = ("orders", "3", "y", True) in done
print(json.dumps({"score": float(ok), "created": done}))
sys.exit(0 if ok else 1)
PY

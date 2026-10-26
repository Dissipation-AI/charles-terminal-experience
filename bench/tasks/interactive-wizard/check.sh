#!/bin/sh
python3 - <<'PY'
import hashlib, json, os, sys
if not os.path.exists("config.json"):
    sys.exit("no config.json")
c = json.load(open("config.json"))
stamp = c.pop("wizard_stamp", None)
ok_vals = c == {"name": "billing", "port": 9040, "tls": True, "admin_email": "ops@example.com"}
ok_stamp = stamp == hashlib.sha256(("wizard:" + json.dumps(c, sort_keys=True)).encode()).hexdigest()[:16]
shown = "9040" in open(os.environ["BENCH_RESPONSE"]).read()
print(json.dumps({"score": (ok_vals + ok_stamp + shown) / 3, "values": ok_vals, "stamp": ok_stamp, "shown": shown}))
sys.exit(0 if ok_vals and ok_stamp and shown else 1)
PY

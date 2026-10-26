#!/bin/sh
python3 - <<'PY'
import os, sys, time, traceback
time.sleep = lambda s: None
sys.path.insert(0, ".")
import etl
try:
    etl.main()
    sys.exit("etl didn't crash")
except ZeroDivisionError:
    tb, f = sys.exc_info()[2], None
    while tb:
        if tb.tb_frame.f_code.co_name == "normalise":
            f = tb.tb_frame
        tb = tb.tb_next
    want = f"{f.f_locals['rec']['id']} {f.f_locals['weight']}"
got = open("answer.txt").read().strip() if os.path.exists("answer.txt") else ""
print("want", want, "got", got)
sys.exit(0 if got.split() == want.split() else 1)
PY

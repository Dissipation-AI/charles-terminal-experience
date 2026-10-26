#!/bin/sh
python3 - <<'PY'
import sys, time
time.sleep = lambda s: None
sys.path.insert(0, ".")
import pipeline
s = pipeline.load()
tot = {}
for sh in s.shards.values():
    rows = [r for r in sh if r[1] == 2]
    tot[sh.key] = (sum(r[2] for r in rows), len(rows))
region = max(tot, key=lambda k: tot[k][0])
want = f"{region} {tot[region][1]}"
got = open("answer.txt").read().strip() if __import__("os").path.exists("answer.txt") else ""
print("want", want, "got", got)
sys.exit(0 if got == want else 1)
PY

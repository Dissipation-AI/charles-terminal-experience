#!/bin/sh
# The daemon serves snapshots; its code is deleted once it's running. Every load is a new random
# snapshot, so the answers can't be computed from a seed or merged across loads.
cat > .whd.py <<'PY'
import json, os, random, socket, sys, threading, time
SOCK = sys.argv[1]
snaps = {}
def make():
    r = random.Random(os.urandom(16))
    sid = "snap-" + os.urandom(4).hex()
    regions = ["north", "south", "east", "west", "central"]
    customers = [{"id": f"c{i:04d}", "region": r.choice(regions), "tier": r.choice(["basic"] * 5 + ["silver"] * 3 + ["gold"] * 2)}
                 for i in range(1, 801)]
    orders, refunds = [], []
    for i in range(1, 6001):
        c = r.choice(customers)
        o = {"id": i, "customer": c["id"], "status": r.choice(["shipped"] * 6 + ["refunded", "cancelled", "open"]),
             "cents": r.randint(300, 40000)}
        orders.append(o)
        if o["status"] == "refunded":
            refunds.append({"order": i, "cents": r.randint(100, o["cents"])})
    # Make each answer unique, with a clear margin: a tie makes agents doubt the data.
    gold = {}
    for c in customers:
        gold.setdefault(c["region"], []).append(c) if c["tier"] == "gold" else None
    top = max(gold, key=lambda g: len(gold[g]))
    for c in [c for c in customers if c["region"] == top and c["tier"] == "basic"][:4]:
        c["tier"] = "gold"
    canc = {}
    for o in orders:
        if o["status"] == "cancelled":
            canc[o["customer"]] = canc.get(o["customer"], 0) + 1
    most = max(canc, key=canc.get)
    for _ in range(3):
        orders.append({"id": len(orders) + 1, "customer": most, "status": "cancelled", "cents": r.randint(300, 40000)})
    return sid, {"customers": customers, "orders": orders, "refunds": refunds}
def answers(d):
    by = {c["id"]: c for c in d["customers"]}
    gold = {}
    for c in d["customers"]:
        if c["tier"] == "gold":
            gold[c["region"]] = gold.get(c["region"], 0) + 1
    od = {o["id"]: o for o in d["orders"]}
    # A tie for the most gold customers accepts either region, with that region's refunds.
    tops = {g: sum(f["cents"] for f in d["refunds"] if by[od[f["order"]]["customer"]]["tier"] == "gold"
                   and by[od[f["order"]]["customer"]]["region"] == g)
            for g in gold if gold[g] == max(gold.values())}
    canc = {}
    for o in d["orders"]:
        if o["status"] == "cancelled":
            canc[o["customer"]] = canc.get(o["customer"], 0) + 1
    top = max(canc.values())
    return tops, {k for k, v in canc.items() if v == top}
def handle(conn):
    f = conn.makefile("rw", buffering=1)
    line = f.readline().split()
    if line and line[0] == "LOAD":
        time.sleep(25)
        sid, d = make()
        snaps[sid] = answers(d)
        f.write(json.dumps({"id": sid, **d}) + "\n")
    elif line and line[0] == "VERIFY" and len(line) == 5:
        a = snaps.get(line[1])
        ok = bool(a) and [line[2] in a[0], str(a[0].get(line[2])) == line[3], line[4] in a[1]]
        f.write(json.dumps(ok) + "\n")
try: os.unlink(SOCK)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(SOCK); s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=lambda c=c: (handle(c), c.close()), daemon=True).start()
PY
python3 .whd.py "$PWD/.wh.sock" </dev/null >/dev/null 2>&1 &
sleep 1
rm .whd.py
cat > warehouse.py <<'PY'
"""Client for the analytics warehouse."""
import json
import os
import socket


class Snapshot:
    """One consistent snapshot. `tables` maps a table name to its rows (dicts)."""

    def __init__(self, data):
        self.id = data.pop("id")
        self.tables = data

    def __repr__(self):
        return f"<Snapshot {self.id}: " + ", ".join(f"{k} ({len(v)} rows)" for k, v in self.tables.items()) + ">"


def load() -> Snapshot:
    """Pull a fresh snapshot from the warehouse. Slow (about half a minute)."""
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".wh.sock"))
    f = s.makefile("rw", buffering=1)
    f.write("LOAD\n")
    return Snapshot(json.loads(f.readline()))
PY

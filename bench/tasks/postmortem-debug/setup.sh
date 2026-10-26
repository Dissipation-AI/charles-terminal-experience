#!/bin/sh
cat > etl.py <<'PY'
"""Nightly ETL: normalise each batch of sensor records."""
import random
import time

rng = random.Random(124)


def records(batch):
    for i in range(25):
        yield {"id": f"b{batch:02d}-r{i:02d}", "readings": [rng.uniform(-5, 5) for _ in range(6)]}


def normalise(rec):
    weight = round(sum(rec["readings"][:3]) - sum(rec["readings"][3:]), 4)
    scale = round(weight, 2)
    return [r / scale for r in rec["readings"]]


def process(batch):
    out = []
    for rec in records(batch):
        out.append(normalise(rec))
    time.sleep(0.5)
    return out


def main():
    for batch in range(1, 200):
        process(batch)
        print(f"batch {batch} ok", flush=True)


if __name__ == "__main__":
    main()
PY

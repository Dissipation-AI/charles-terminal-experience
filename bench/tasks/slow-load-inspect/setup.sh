#!/bin/sh
cat > pipeline.py <<'PY'
"""Order data for the reporting pipeline."""
import random
import time


class Shard:
    def __init__(self, key, rows, columns):
        self.key = key
        self._rows = rows
        self.columns = columns

    def __iter__(self):
        return iter(self._rows)

    def __len__(self):
        return len(self._rows)


class Store:
    def __init__(self, shards, codes):
        self.shards = shards
        self.status_codes = codes

    def __repr__(self):
        return f"<Store {len(self.shards)} shards>"


def load():
    """Builds the store. Slow: it simulates pulling every shard from the warehouse."""
    rng = random.Random(20261025)
    codes = {0: "open", 1: "shipped", 2: "refunded", 3: "cancelled"}
    regions = ["north", "south", "east", "west", "central"]
    shards = {}
    for i, region in enumerate(regions):
        time.sleep(4)
        rows = []
        for n in range(rng.randint(300, 500)):
            cents = rng.randint(500, 90000)
            rows.append((f"{region[:2]}-{n}", rng.choice([0, 1, 1, 1, 2, 3]), cents))
        shards[f"shard-{i:02d}"] = Shard(region, rows, ("order_id", "status", "amount_cents"))
    return Store(shards, codes)
PY

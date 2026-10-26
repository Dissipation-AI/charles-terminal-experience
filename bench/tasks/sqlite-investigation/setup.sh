#!/bin/sh
python3 - <<'PY'
import random, sqlite3
rng = random.Random(7)
db = sqlite3.connect("shop.db")
db.executescript("""
CREATE TABLE cat (id INTEGER PRIMARY KEY, label TEXT);
CREATE TABLE product (sku TEXT PRIMARY KEY, title TEXT, cat_id INTEGER REFERENCES cat(id), list_price_cents INTEGER);
CREATE TABLE customer (id INTEGER PRIMARY KEY, email TEXT, joined TEXT);
CREATE TABLE sale (id INTEGER PRIMARY KEY, customer_id INTEGER, placed_at TEXT, channel TEXT);
CREATE TABLE sale_line (sale_id INTEGER REFERENCES sale(id), sku TEXT REFERENCES product(sku), qty INTEGER, unit_price_cents INTEGER);
CREATE TABLE refund (id INTEGER PRIMARY KEY, sale_id INTEGER REFERENCES sale(id), sku TEXT, amount_cents INTEGER, refunded_at TEXT);
""")
cats = ["toys", "garden", "kitchen", "books", "outdoor", "office"]
db.executemany("INSERT INTO cat VALUES (?, ?)", list(enumerate(cats, 1)))
prods = []
for i in range(60):
    prods.append((f"SKU{i:03d}", f"item {i}", rng.randint(1, 6), rng.randint(300, 12000)))
db.executemany("INSERT INTO product VALUES (?,?,?,?)", prods)
db.executemany("INSERT INTO customer VALUES (?,?,?)", [(i, f"c{i}@x.com", "2025-01-01") for i in range(1, 300)])
sid = 0; rid = 0
for month in (2, 3, 4):
    for _ in range(400):
        sid += 1
        day = rng.randint(1, 28)
        db.execute("INSERT INTO sale VALUES (?,?,?,?)", (sid, rng.randint(1, 299), f"2026-{month:02d}-{day:02d} {rng.randint(0,23):02d}:{rng.randint(0,59):02d}:00", rng.choice(["web", "store"])))
        for _ in range(rng.randint(1, 4)):
            p = rng.choice(prods)
            qty = rng.randint(1, 3)
            price = int(p[3] * rng.choice([1, 1, 0.9, 0.8]))
            db.execute("INSERT INTO sale_line VALUES (?,?,?,?)", (sid, p[0], qty, price))
            if rng.random() < 0.12:
                rid += 1
                m2 = month if rng.random() < 0.7 else month + 1
                db.execute("INSERT INTO refund VALUES (?,?,?,?,?)", (rid, sid, p[0], price * rng.randint(1, qty), f"2026-{m2:02d}-{rng.randint(1,28):02d}"))
db.commit()
PY

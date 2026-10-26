#!/bin/sh
# Net revenue = March sales lines minus refunds on March sales. A refund dated in March for a
# February sale is also accepted (two readings of "refunds in March").
python3 - <<'PY'
import json, os, sqlite3, sys
db = sqlite3.connect("shop.db")
sales = dict(db.execute("""SELECT c.label, SUM(l.qty * l.unit_price_cents) FROM sale s JOIN sale_line l ON l.sale_id = s.id
  JOIN product p ON p.sku = l.sku JOIN cat c ON c.id = p.cat_id WHERE s.placed_at LIKE '2026-03-%' GROUP BY c.label"""))
ref_by_sale = dict(db.execute("""SELECT c.label, SUM(r.amount_cents) FROM refund r JOIN sale s ON s.id = r.sale_id
  JOIN product p ON p.sku = r.sku JOIN cat c ON c.id = p.cat_id WHERE s.placed_at LIKE '2026-03-%' GROUP BY c.label"""))
ref_by_date = dict(db.execute("""SELECT c.label, SUM(r.amount_cents) FROM refund r JOIN product p ON p.sku = r.sku
  JOIN cat c ON c.id = p.cat_id WHERE r.refunded_at LIKE '2026-03-%' GROUP BY c.label"""))
wants = set()
for refs in (ref_by_sale, ref_by_date):
    net = {k: v - refs.get(k, 0) for k, v in sales.items()}
    best = max(net, key=net.get)
    wants.add(f"{best} {net[best] / 100:.2f}")
got = open("answer.txt").read().strip().replace("$", "") if os.path.exists("answer.txt") else ""
print("want one of", sorted(wants), "got", got)
sys.exit(0 if got in wants else 1)
PY

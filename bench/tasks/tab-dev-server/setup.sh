#!/bin/sh
cat > prices.json <<'J'
{"apple": {"unit_price": 120, "qty": 3}, "pear": {"unit_price": 95, "qty": 2}, "plum": {"unit_price": 40, "qty": 10}}
J
cat > server.py <<'PY'
import json, os, traceback
from http.server import BaseHTTPRequestHandler, HTTPServer


def total():
    items = json.load(open("prices.json"))
    return sum(i["price"] * i["qty"] for i in items.values())


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/total":
            try:
                body = json.dumps({"total_cents": total()}).encode()
            except Exception:
                traceback.print_exc()
                self.send_error(500); return
        elif self.path == "/":
            body = b"shop dev server"
        else:
            self.send_error(404); return
        self.send_response(200); self.end_headers(); self.wfile.write(body)


port = int(os.environ.get("PORT", "8000"))
print(f"shop dev server on http://127.0.0.1:{port}", flush=True)
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
ctx open tab named "Dev server - shop" at "$PWD" >/dev/null
ctx run in "Dev server - shop" "PORT=$BENCH_PORT python3 server.py" without waiting >/dev/null 2>&1
ctx wait until "Dev server - shop" shows "shop dev server on" within 20 seconds >/dev/null
curl -s "http://127.0.0.1:$BENCH_PORT/api/total" >/dev/null; true
curl -s "http://127.0.0.1:$BENCH_PORT/api/total" >/dev/null; true
ctx read last 20 lines in "Dev server - shop" >&2

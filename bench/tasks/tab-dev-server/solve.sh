perl -pi -e 's/i\["price"\]/i["unit_price"]/' server.py
ctx press ctrl-c in "Dev server - shop" >/dev/null
ctx wait until "Dev server - shop" is idle within 10 seconds >/dev/null
ctx run in "Dev server - shop" "PORT=$BENCH_PORT python3 server.py" without waiting >/dev/null
ctx wait until "Dev server - shop" shows "shop dev server on" within 20 seconds >/dev/null

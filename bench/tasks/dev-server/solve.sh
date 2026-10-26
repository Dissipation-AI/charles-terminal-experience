PORT=$BENCH_PORT nohup python3 app.py > server.log 2>&1 < /dev/null &
for i in $(seq 50); do curl -s -m 1 http://127.0.0.1:$BENCH_PORT/ && break; sleep 0.2; done

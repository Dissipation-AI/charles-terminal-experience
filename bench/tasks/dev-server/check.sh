#!/bin/sh
# Score: half for a server still answering after the agent exited, half for reporting its reply.
up=0; told=0
curl -s -m 3 "http://127.0.0.1:$BENCH_PORT/" | grep -q "hello from the webapp" && up=1
grep -qi "hello from the webapp" "$BENCH_RESPONSE" && told=1
echo "{\"score\": $(awk "BEGIN{print ($up+$told)/2}"), \"server_up\": $up, \"reported\": $told}"
[ $up = 1 ] && [ $told = 1 ]

#!/bin/sh
[ -f build/firmware.bin ] || { echo "no build/firmware.bin"; exit 1; }
[ "$(wc -l < build/firmware.bin | tr -d ' ')" = 30 ] || { echo "firmware.bin incomplete"; exit 1; }
want=$(shasum -a 256 build/firmware.bin | cut -c1-12)
got=$(tr -d ' \n' < answer.txt 2>/dev/null | sed 's/^checksum://')
echo "want $want got $got"
[ "$got" = "$want" ]

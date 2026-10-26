#!/bin/sh
cat > build.sh <<'SH'
#!/bin/sh
# Builds build/firmware.bin. Each stage takes a while.
set -e
mkdir -p build
: > build/firmware.part
for stage in $(seq 1 30); do
  printf 'stage %02d/30: compiling module_%02d\n' "$stage" "$stage"
  sleep 5
  printf 'module_%02d:%s\n' "$stage" "$(printf '%s' "m$stage" | shasum -a 256 | cut -c1-16)" >> build/firmware.part
done
mv build/firmware.part build/firmware.bin
echo "build finished: build/firmware.bin"
SH
cat > verify.sh <<'SH'
#!/bin/sh
[ -f build/firmware.bin ] || { echo "build/firmware.bin is missing: run ./build.sh first" >&2; exit 1; }
echo "checksum: $(shasum -a 256 build/firmware.bin | cut -c1-12)"
SH
chmod +x build.sh verify.sh

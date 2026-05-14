#!/usr/bin/env bash
# M14.1 substep gate. Verifies the libktx vendor build + thin C
# binding round-trip without any Vulkan / render integration.
#
# Asserts:
#   - `m14-ktx-dump` builds cleanly (cmake --build ktx_read produced
#     libktx_read.a and Zig linked it into the smoke binary)
#   - opening a vendor reference KTX2 reports the expected metadata
#     (128x128 RGBA8 = vk_format 43, data_size 65536, no transcode)
#   - `OK` sentinel printed on stdout, exit 0
#   - opening a non-existent path returns FileOpenFailed (the binding's
#     error-translation surface)
#
# Headless-friendly: no display required. Part of M14.1; M14.2 lifts
# this into the full m14_gate_smoke.sh once the Vulkan path lands.
#
# Usage:
#   ./scripts/m14_1_ktx_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SAMPLE="vendor/KTX-Software/tests/testimages/rgba-reference-u.ktx2"
BIN="./zig-out/bin/m14-ktx-dump"

echo ">>> M14.1 gate: sample=${SAMPLE}"

if [[ ! -f "$SAMPLE" ]]; then
  echo "FAIL: vendor sample missing: $SAMPLE"
  echo "      git submodule update --init vendor/KTX-Software"
  exit 1
fi

echo ">>> building m14-ktx-dump"
zig build install -Doptimize=ReleaseFast >/dev/null

echo ">>> running on vendor RGBA reference"
# std.debug.print routes to stderr; capture both streams.
OUT=$("$BIN" "$SAMPLE" 2>&1)
echo "$OUT"

# Field assertions. rgba-reference-u.ktx2 from libktx v4.4.2 is a
# stable input; if any of these drift, libktx upgrade broke the API.
check() {
  local key="$1" expected="$2"
  local got
  got=$(echo "$OUT" | awk -F= -v k="$key" '$1==k {print $2}')
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: $key: expected '$expected', got '$got'"
    exit 1
  fi
}
check width "128"
check height "128"
check vk_format "43"        # VK_FORMAT_R8G8B8A8_SRGB
check levels "1"
check layers "1"
check faces "1"
check data_size "65536"     # 128 * 128 * 4
check needs_transcode "false"

if ! echo "$OUT" | grep -qx "OK"; then
  echo "FAIL: missing OK sentinel"
  exit 1
fi

echo ">>> negative test: missing file → FileOpenFailed"
if "$BIN" /tmp/nonexistent-$$.ktx2 2>/tmp/m14_neg.log; then
  echo "FAIL: missing file should have errored"
  exit 1
fi
if ! grep -q "FileOpenFailed" /tmp/m14_neg.log; then
  echo "FAIL: expected FileOpenFailed in:"
  cat /tmp/m14_neg.log
  exit 1
fi
rm -f /tmp/m14_neg.log

echo ">>> M14.1 PASS"

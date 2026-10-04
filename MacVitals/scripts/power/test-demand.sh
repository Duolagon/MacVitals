#!/bin/sh
set -eu
POWER_TEST_DIR=$(mktemp -d /tmp/macvitals-demand-test.XXXXXX)
POWER_SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cp /bin/sleep "$POWER_TEST_DIR/MacVitals"
codesign --force --sign - "$POWER_TEST_DIR/MacVitals" >/dev/null 2>&1
"$POWER_TEST_DIR/MacVitals" 30 &
POWER_TEST_PID=$!
POWER_REQUEST="/tmp/local.macvitals.power-demand.$POWER_TEST_PID"
cleanup() {
    rm -f "$POWER_REQUEST"
    kill "$POWER_TEST_PID" 2>/dev/null || true
    wait "$POWER_TEST_PID" 2>/dev/null || true
    rm -rf "$POWER_TEST_DIR"
}
trap cleanup EXIT HUP INT TERM
idle() {
    if /bin/sh "$POWER_SOURCE_DIR/collect.sh" --check-demand "$POWER_TEST_PID"; then
        echo 'FAIL: collector accepted an absent or invalid lease'; exit 1
    fi
}
idle
printf 'active\n' > "$POWER_REQUEST"
chmod 600 "$POWER_REQUEST"
/bin/sh "$POWER_SOURCE_DIR/collect.sh" --check-demand "$POWER_TEST_PID"
chmod 644 "$POWER_REQUEST"; idle
chmod 600 "$POWER_REQUEST"
touch -t 200001010000 "$POWER_REQUEST"; idle
touch -t 209901010000 "$POWER_REQUEST"; idle
rm "$POWER_REQUEST"
printf 'active\n' > "$POWER_TEST_DIR/lease"
chmod 600 "$POWER_TEST_DIR/lease"
ln -s "$POWER_TEST_DIR/lease" "$POWER_REQUEST"; idle
echo 'PASS: collector rejects missing, stale, future, public and symlink leases; accepts a fresh private lease'

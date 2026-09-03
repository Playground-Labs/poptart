#!/bin/zsh
# Runs the Poptart control-class compatibility matrix.
#
# Builds PoptartCompatHost and PoptartCompatDriver, wraps both in ad-hoc-signed .app bundles,
# launches the host, drives the shipping Accessibility and clipboard adapters against it, tears
# the host down, and exits with the driver's exit code.
#
# ONE-TIME PERMISSION GRANT
# -------------------------
# The driver reads and writes other processes' Accessibility elements and synthesises Cmd-V, so
# macOS requires an Accessibility grant for it. The first run will be refused and will print
# instructions. Grant it once in:
#
#     System Settings > Privacy & Security > Accessibility  ->  enable "PoptartCompatDriver"
#
# (If it is not listed, press + and choose .build/PoptartCompatDriver.app.) The bundles are signed
# with `codesign --sign - --requirements '=designated => identifier "..."'`, which pins the code
# identity to the bundle id rather than to the binary's hash, so the grant survives rebuilds. The
# host needs no permission at all.
#
# Set POPTART_COMPAT_DIRECT=1 to execute the driver binary straight from the bundle instead of
# through LaunchServices; in that mode macOS attributes the Accessibility grant to the terminal
# application running this script rather than to PoptartCompatDriver.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

BUILD_DIR="$REPO/.build"
OUTPUT="${1:-$BUILD_DIR/compat-matrix.json}"
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$REPO/$OUTPUT"
fi
CHANNEL="$(mktemp -d "${TMPDIR:-/tmp}/poptart-compat.XXXXXX")"
DRIVER_STDOUT="$BUILD_DIR/PoptartCompatDriver.stdout.log"
DRIVER_STDERR="$BUILD_DIR/PoptartCompatDriver.stderr.log"
HOST_STDOUT="$BUILD_DIR/PoptartCompatHost.stdout.log"
HOST_STDERR="$BUILD_DIR/PoptartCompatHost.stderr.log"
STATUS_FILE="$CHANNEL/driver-status"

HOST_PID=""
cleanup() {
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
    # Ask the host to quit through its own channel first so it tears its window down cleanly.
    printf '{"sequence":999999,"command":"quit"}' >"$CHANNEL/requests/999999.json" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$HOST_PID" 2>/dev/null || break
      sleep 0.2
    done
  fi
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$HOST_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$HOST_PID" 2>/dev/null || true
  fi
  rm -rf "$CHANNEL"
}
trap cleanup EXIT INT TERM

bundle() {
  local product="$1"
  local identifier="$2"
  local app="$BUILD_DIR/$product.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  ditto "$BIN_PATH/$product" "$app/Contents/MacOS/$product"
  ditto "$REPO/Tools/Compat/Support/$product-Info.plist" "$app/Contents/Info.plist"
  # Pin the designated requirement to the bundle id so the Accessibility grant survives rebuilds.
  codesign --force --sign - \
    --requirements "=designated => identifier \"$identifier\"" \
    "$app" >/dev/null
  printf '%s' "$app"
}

echo "building the compatibility harness"
swift build --product PoptartCompatHost
swift build --product PoptartCompatDriver
BIN_PATH="$(swift build --show-bin-path)"

HOST_APP="$(bundle PoptartCompatHost labs.playground.PoptartCompatHost)"
DRIVER_APP="$(bundle PoptartCompatDriver labs.playground.PoptartCompatDriver)"

echo "launching the host on channel $CHANNEL"
open -n \
  --stdout "$HOST_STDOUT" \
  --stderr "$HOST_STDERR" \
  "$HOST_APP" --args --channel "$CHANNEL"

for _ in $(seq 1 300); do
  [[ -f "$CHANNEL/host-ready.json" ]] && break
  sleep 0.2
done
if [[ ! -f "$CHANNEL/host-ready.json" ]]; then
  echo "PoptartCompatHost never became ready; see $HOST_STDERR" >&2
  exit 4
fi
HOST_PID="$(sed -n 's/.*"processIdentifier":\([0-9]*\).*/\1/p' "$CHANNEL/host-ready.json")"
echo "host ready (pid $HOST_PID)"

: >"$DRIVER_STDOUT"
: >"$DRIVER_STDERR"
if [[ "${POPTART_COMPAT_DIRECT:-0}" == "1" ]]; then
  set +e
  "$DRIVER_APP/Contents/MacOS/PoptartCompatDriver" \
    --channel "$CHANNEL" --output "$OUTPUT" --status "$STATUS_FILE" \
    | tee "$DRIVER_STDOUT"
  DRIVER_STATUS="${pipestatus[1]}"
  set -e
else
  open -n -W \
    --stdout "$DRIVER_STDOUT" \
    --stderr "$DRIVER_STDERR" \
    "$DRIVER_APP" --args --channel "$CHANNEL" --output "$OUTPUT" --status "$STATUS_FILE"
  # `open -W` reports its own launch status, so the driver's exit code arrives by status file.
  if [[ -f "$STATUS_FILE" ]]; then
    DRIVER_STATUS="$(tr -d '[:space:]' <"$STATUS_FILE")"
  else
    DRIVER_STATUS=4
  fi
  cat "$DRIVER_STDOUT"
  if [[ -s "$DRIVER_STDERR" ]]; then cat "$DRIVER_STDERR" >&2; fi
fi

if [[ "$DRIVER_STATUS" == "3" ]]; then
  cat >&2 <<'NOTE'

The matrix did NOT run: PoptartCompatDriver has no Accessibility permission, so nothing was
measured and nothing passed. Grant it in System Settings > Privacy & Security > Accessibility and
run this script again. To borrow the grant already held by the terminal application instead, run:

    POPTART_COMPAT_DIRECT=1 Tools/Compat/run.sh

NOTE
fi

exit "$DRIVER_STATUS"

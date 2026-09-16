#!/bin/zsh
# Continuous process-attributed packet capture. Run `sudo -v` first; the app itself runs as you.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
OUTPUT="$REPO/.build/traffic-capture.json"
if (( $# )); then
  [[ $# == 2 && "$1" == --output ]] || { echo "usage: ${0:t} [--output FILE]" >&2; exit 2; }
  OUTPUT="$2"
fi
[[ -t 0 ]] || { echo "A terminal is required to mark download phases" >&2; exit 2; }
sudo -n true || { echo "Run sudo -v before this script to authorize packet capture" >&2; exit 2; }
mkdir -p "${OUTPUT:h}"
print -r -- '{"schemaVersion":1,"passed":false,"status":"incomplete"}' >"$OUTPUT"
EVIDENCE="$(mktemp -d "${OUTPUT}.evidence.XXXXXX")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/poptart-capture.XXXXXX")"
APP_PID="" CAPTURE_JOB=""
stop_capture() {
  if [[ -n "$CAPTURE_JOB" ]]; then
    if [[ -s "$EVIDENCE/capture.pid" ]]; then
      sudo -n kill -INT "$(cat "$EVIDENCE/capture.pid")" 2>/dev/null || true
    fi
    wait "$CAPTURE_JOB" || return 1
    CAPTURE_JOB=""
  fi
}
cleanup() {
  [[ -z "$APP_PID" ]] || { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }
  stop_capture || true
  rm -rf "$TMP"
  echo "Capture evidence retained at $EVIDENCE" >&2
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mark() {
  python3 - "$EVIDENCE/phases.json" "$1" <<'PY'
import json,sys,time
from pathlib import Path
p=Path(sys.argv[1]); phases=json.loads(p.read_text()) if p.exists() else {}
phases[sys.argv[2]]=time.time()
p.write_text(json.dumps(phases,sort_keys=True)+'\n')
PY
}
ensure_alive() {
  kill -0 "$APP_PID" 2>/dev/null && kill -0 "$CAPTURE_JOB" 2>/dev/null || {
    echo "App or capture exited before all phases completed" >&2; exit 1;
  }
}
zsh Scripts/dev-run.sh --bundle-only >/dev/null
# Capturing by process name lets capture start before launch. Offline filtering also checks PID.
# Effective process metadata includes traffic attributed to Poptart through system services.
sudo -n sh -c 'echo $$ > "$1"; shift; exec "$@"' sh "$EVIDENCE/capture.pid" \
  /usr/sbin/tcpdump -i pktap,all -n -U -w "$EVIDENCE/traffic.pcapng" \
  -Q 'proc = Poptart or eproc = Poptart' 'ip or ip6' \
  >"$EVIDENCE/capture.stdout" 2>"$EVIDENCE/capture.log" &
CAPTURE_JOB=$!
ready=0
for _ in {1..100}; do
  kill -0 "$CAPTURE_JOB" 2>/dev/null || break
  if grep -q 'listening on' "$EVIDENCE/capture.log"; then ready=1; break; fi
  sleep 0.1
done
(( ready )) || { echo "Packet capture did not become ready" >&2; exit 1; }
mark captureReady
unset POPTART_MODEL_PACK_DIRECTORY
export POPTART_SUPPORT_DIRECTORY="$TMP"
export POPTART_STATUS_FILE="$TMP/status"
mark appStarted
.build/Poptart.app/Contents/MacOS/Poptart >"$EVIDENCE/app.stdout" 2>"$EVIDENCE/app.stderr" &
APP_PID=$!
print -r -- "$APP_PID" >"$EVIDENCE/app.pid"
echo "Advance to the Model Pack step. Press Enter here immediately BEFORE requesting the manifest/download." >&2
read -r _mark
ensure_alive
mark downloadStarted
echo "Request the manifest and install the Model Pack. Press Enter after installation completes." >&2
read -r _mark
ensure_alive
[[ -f "$TMP/ModelRuntime/active-model-pack.json" ]] || { echo "No installed Model Pack; download is unproven" >&2; exit 3; }
cp "$TMP/ModelRuntime/active-model-pack.json" "$EVIDENCE/installed-model-pack.json"
mark downloadFinished
sleep 20
ensure_alive
stop_capture
mark captureFinished
sudo -n /usr/sbin/tcpdump -n -q -tt -k NP -r "$EVIDENCE/traffic.pcapng" \
  -Q "pid = $APP_PID or epid = $APP_PID" >"$EVIDENCE/packets.txt" 2>"$EVIDENCE/decode.log"
python3 Scripts/privacy/verify_evidence.py traffic "$EVIDENCE" "$OUTPUT"

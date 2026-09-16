#!/bin/zsh
# Ad-hoc debug app + production pipeline under an IP-denying sandbox.
# Exit 3 means startup-only evidence; exit 0 requires successful model Cleanup and history readback.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
MODEL="" AUDIO="" OUTPUT="$REPO/.build/network-deny.json" STARTUP_ONLY=0
usage() { echo "usage: ${0:t} [--startup-only | --model DIR --audio DIR] [--output FILE]" >&2; exit 2; }
while (( $# )); do
  case "$1" in
    --startup-only) STARTUP_ONLY=1; shift ;;
    --model|--audio|--output)
      (( $# >= 2 )) || usage
      case "$1" in
        --model) MODEL="$2" ;; --audio) AUDIO="$2" ;; --output) OUTPUT="$2" ;;
      esac
      shift 2 ;;
    *) usage ;;
  esac
done
if (( STARTUP_ONLY )); then
  [[ -z "$MODEL" && -z "$AUDIO" ]] || usage
else
  [[ -d "$MODEL" && -d "$AUDIO" ]] || usage
  MODEL="$(cd "$MODEL" && pwd)"; AUDIO="$(cd "$AUDIO" && pwd)"
fi
mkdir -p "${OUTPUT:h}"
print -r -- '{"schemaVersion":1,"passed":false,"status":"incomplete"}' >"$OUTPUT"
PROFILE="$REPO/Scripts/privacy/deny-network.sb"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/poptart-deny.XXXXXX")"
APP_PID=""
stop_app() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
  fi
}
cleanup() { stop_app; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# EPERM proves the policy blocked the request, rather than an unavailable remote endpoint.
sandbox-exec -f "$PROFILE" python3 - <<'PY'
import errno, socket
for family, address in [(socket.AF_INET, ('127.0.0.1', 9)), (socket.AF_INET6, ('::1', 9))]:
    with socket.socket(family) as client:
        try:
            client.connect(address)
        except OSError as error:
            if error.errno != errno.EPERM:
                raise SystemExit('IP denial not proven: ' + str(error))
        else:
            raise SystemExit('sandbox allowed IP networking')
PY
zsh Scripts/dev-run.sh --bundle-only >/dev/null
unset POPTART_MODEL_PACK_DIRECTORY
export POPTART_SUPPORT_DIRECTORY="$TMP/app"
export POPTART_STATUS_FILE="$TMP/status"
sandbox-exec -f "$PROFILE" .build/Poptart.app/Contents/MacOS/Poptart \
  >.build/network-deny-app.stdout.log 2>.build/network-deny-app.stderr.log &
APP_PID=$!
settled=0
for _ in {1..240}; do
  kill -0 "$APP_PID" 2>/dev/null || break
  if [[ -f "$TMP/status" ]]; then
    case "$(cat "$TMP/status")" in
      "Ready."|"Install the verified Model Pack to start dictating."|"Finish setting Poptart up.") settled=1; break ;;
    esac
  fi
  sleep 0.25
done
(( settled )) || { echo "app startup failed; see .build/network-deny-app.stderr.log" >&2; exit 4; }
python3 - "$TMP/app/Settings.json" <<'PY'
import json,sys
settings=json.load(open(sys.argv[1]))
if not isinstance(settings.get('shortcutBinding'), str) or not settings['shortcutBinding']:
    sys.exit('settings persistence not proven')
PY
stop_app
if (( STARTUP_ONLY )); then
  python3 - "$TMP/status" "$OUTPUT" <<'PY'
import json,sys
report=dict(schemaVersion=1, applicationStatus=open(sys.argv[1]).read(), settingsWritten=True,
            ipDenialProven=True, startupOnly=True, dictationProven=False, passed=False)
text=json.dumps(report,sort_keys=True)
open(sys.argv[2],'w').write(text+'\n')
print(text)
PY
  exit 3
fi
swift build --product PoptartBenchmark >/dev/null
RUNNER="$(swift build --show-bin-path)/PoptartBenchmark"
sandbox-exec -f "$PROFILE" "$RUNNER" --fixtures "$REPO/Evals/fixtures/gold.jsonl" \
  --model "$MODEL" --audio "$AUDIO" --jsonl --history-directory "$TMP/runner" \
  >.build/network-deny-benchmark.jsonl 2>.build/network-deny-benchmark.stderr.log
python3 Scripts/privacy/verify_evidence.py deny .build/network-deny-benchmark.jsonl Evals/fixtures/gold.jsonl >"$TMP/results.json"
python3 - "$TMP/results.json" "$TMP/status" "$OUTPUT" "$PROFILE" <<'PY'
import hashlib,json,sys
report=json.load(open(sys.argv[1]))
report.update(schemaVersion=1,applicationStatus=open(sys.argv[2]).read(),settingsWritten=True,
              ipDenialProven=True,startupOnly=False,passed=True,sandboxProfileSHA256=hashlib.sha256(open(sys.argv[4],'rb').read()).hexdigest())
text=json.dumps(report,sort_keys=True)
open(sys.argv[3],'w').write(text+'\n')
print(text)
PY

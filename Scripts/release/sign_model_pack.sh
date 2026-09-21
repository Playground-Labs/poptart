#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: sign_model_pack.sh MANIFEST_JSON PRIVATE_ED25519_KEY OUTPUT_ENVELOPE" >&2
  exit 64
fi
manifest=$1
key=$2
output=$3
[ -f "$manifest" ] || { echo "manifest file is required" >&2; exit 1; }
[ -f "$key" ] || { echo "Ed25519 private key file is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

python3 - "$manifest" "$(dirname "$0")" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
from build_model_manifest import validate_manifest
path=Path(sys.argv[1]); value=json.loads(path.read_text())
config=json.loads((Path(sys.argv[2]).resolve().parents[1] / "Models/production-config.json").read_text())
validate_manifest(value, path.parent, value.get("cleanupTokenCeiling"), config)
PY

signature=$(mktemp "${TMPDIR:-/tmp}/poptart-signature.XXXXXX")
trap 'rm -f "$signature"' EXIT HUP INT TERM
openssl pkeyutl -sign -rawin -inkey "$key" -in "$manifest" -out "$signature"
python3 - "$manifest" "$signature" "$output" <<'PY'
import base64,json,sys
manifest=open(sys.argv[1],"rb").read(); signature=open(sys.argv[2],"rb").read()
if len(signature)!=64: raise SystemExit("unexpected Ed25519 signature length")
with open(sys.argv[3],"w") as out: json.dump({"manifest":base64.b64encode(manifest).decode(),"signature":base64.b64encode(signature).decode()},out,separators=(",",":"),sort_keys=True)
PY
echo "signed model pack envelope written to $output"

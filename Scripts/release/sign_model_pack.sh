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

python3 - "$manifest" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
if value.get("exampleOnly") or value.get("cleanupTokenCeiling") in (None, 0): raise SystemExit("refusing to sign example or unmeasured manifest")
artifacts=value.get("artifacts", [])
if {a.get("role") for a in artifacts}!={"recognition","cleanup"}: raise SystemExit("manifest must contain exactly recognition and cleanup roles")
for artifact in artifacts:
    if not isinstance(artifact.get("byteSize"), int) or artifact["byteSize"] <= 0: raise SystemExit("artifact byteSize is required")
    digest=artifact.get("sha256", "")
    if len(digest)!=64 or any(c not in "0123456789abcdef" for c in digest): raise SystemExit("artifact sha256 is required")
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

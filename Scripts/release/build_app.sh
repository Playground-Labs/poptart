#!/bin/zsh
# Assemble the optimized arm64 app without touching the development bundle.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: build_app.sh DEVELOPER_ID_SHA1 NEW_OUTPUT.app" >&2
  exit 64
fi
identity="$1"
output="${2:a}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$identity" =~ '^[[:xdigit:]]{40}$' ]] || {
  echo "a Developer ID Application certificate SHA-1 is required" >&2; exit 1
}
security find-identity -v -p codesigning | grep -iF "$identity" | grep -F 'Developer ID Application:' >/dev/null || {
  echo "the Developer ID identity is not available in this keychain" >&2; exit 1
}
[[ "$output" == *.app && ! -e "$output" && ! -L "$output" && -d "${output:h}" ]] || {
  echo "output must be a new .app path inside an existing directory" >&2; exit 1
}
python3 - <<'PY'
import base64, os, re
if not re.fullmatch(r'[A-Z0-9]{10}', os.environ.get('POPTART_TEAM_ID', '')):
    raise SystemExit('POPTART_TEAM_ID must be the expected 10-character Apple Developer Team ID')
try:
    key = base64.b64decode(os.environ.get('POPTART_MODEL_PACK_PUBLIC_KEY', ''), validate=True)
    if len(key) != 32:
        raise ValueError('wrong key length')
except ValueError:
    raise SystemExit('POPTART_MODEL_PACK_PUBLIC_KEY must be a base64 32-byte Ed25519 public key')
PY
cd "$repo"
swift build -c release --arch arm64 --product Poptart
bin_path="$(swift build -c release --arch arm64 --show-bin-path)"
staging="$(mktemp -d "${output:h}/.poptart-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
app="$staging/Poptart.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$bin_path/Poptart" "$app/Contents/MacOS/Poptart"
ditto "$repo/App/Poptart-Info.plist" "$app/Contents/Info.plist"
for resource in "$bin_path"/*.bundle(N); do
  ditto "$resource" "$app/Contents/Resources/${resource:t}"
done
ditto "$repo/LICENSE" "$app/Contents/Resources/LICENSE"
ditto "$repo/NOTICE" "$app/Contents/Resources/NOTICE"
python3 "$repo/Scripts/release/copy_notices.py" "$repo/Package.resolved" \
  "$repo/.build/checkouts" "$app/Contents/Resources/Licenses"
plutil -replace PoptartModelPackPublicKey -string "$POPTART_MODEL_PACK_PUBLIC_KEY" "$app/Contents/Info.plist"
zsh "$repo/Scripts/embed-sparkle.sh" "$app" "$identity" release
codesign --sign "$identity" --options runtime --timestamp \
  --entitlements "$repo/App/Poptart.entitlements" "$app"
python3 "$repo/Scripts/release/verify_app_signature.py" "$app" "$POPTART_TEAM_ID"
mv "$app" "$output"
echo "signed release app: $output (not yet notarized)"

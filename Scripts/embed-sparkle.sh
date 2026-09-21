#!/bin/zsh
# Shared by development and Developer ID bundles. Poptart does not use Sparkle's XPC services.
set -euo pipefail
if [[ $# -ne 3 || ( "$3" != development && "$3" != release ) ]]; then
  echo "usage: embed-sparkle.sh APP SIGNING_IDENTITY development|release" >&2; exit 64
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
python3 - "$app/Contents/Info.plist" "$3" <<'PY'
import base64, os, plistlib, sys
from urllib.parse import urlsplit
feed = os.environ.get('POPTART_APP_UPDATE_FEED_URL', '')
key = os.environ.get('POPTART_APP_UPDATE_PUBLIC_KEY', '')
if feed or key or sys.argv[2] == 'release':
    url = urlsplit(feed)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise SystemExit('POPTART_APP_UPDATE_FEED_URL must be an HTTPS appcast URL without credentials')
    try:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError('wrong length')
    except ValueError:
        raise SystemExit('POPTART_APP_UPDATE_PUBLIC_KEY must be a base64 32-byte Ed25519 public key')
    with open(sys.argv[1], 'rb') as source:
        info = plistlib.load(source)
    info.update(SUFeedURL=feed, SUPublicEDKey=key)
    with open(sys.argv[1], 'wb') as destination:
        plistlib.dump(info, destination)
PY
framework="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$repo/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
rm -rf "$framework/Versions/B/XPCServices" "$framework/XPCServices"
sign_options=(--force --sign "$2")
if [[ "$3" == release ]]; then sign_options+=(--options runtime --timestamp); fi
for component in "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
  codesign "${sign_options[@]}" "$component"
done

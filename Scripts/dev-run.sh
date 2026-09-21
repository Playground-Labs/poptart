#!/bin/zsh
# Builds Poptart, wraps it in an ad-hoc-signed .app bundle, and launches it.
#
# Poptart needs Microphone, Accessibility, and Input Monitoring grants, and macOS attaches those
# grants to a code identity. A bare `swift build` product has no bundle and no stable identity, so
# every rebuild would look like a different application and every grant would have to be given
# again. Signing the bundle with
#
#     codesign --sign - --requirements '=designated => identifier "labs.playground.Poptart"'
#
# pins the designated requirement to the bundle id rather than to the binary's hash, so the grants
# survive rebuilds. This is the same reasoning as Tools/Compat/run.sh, which does it for the
# compatibility harness.
#
# A copy of Poptart already running out of this bundle is asked to quit first, because replacing the
# bundle underneath a live process leaves it running code that no longer exists on disk. The Model
# Pack signing key is deliberately absent from source, so set POPTART_MODEL_PACK_PUBLIC_KEY to have
# it written into the bundled Info.plist; without it the build refuses every Model Pack action.
#
# Pass --bundle-only to build and sign without launching.
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--bundle-only" ) ]]; then
  echo "usage: ${0:t} [--bundle-only]" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

APP="$REPO/.build/Poptart.app"

swift build --product Poptart
BIN_PATH="$(swift build --show-bin-path)"

# Ask a running Poptart to quit through its own channel, then give it a moment to go.
osascript -e 'if application id "labs.playground.Poptart" is running then tell application id "labs.playground.Poptart" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 15); do
  pgrep -f "$APP/Contents/MacOS/Poptart" >/dev/null || break
  sleep 0.2
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN_PATH/Poptart" "$APP/Contents/MacOS/Poptart"
ditto "$REPO/App/Poptart-Info.plist" "$APP/Contents/Info.plist"
# SwiftPM emits resource bundles for FluidAudio, MLX, and friends beside the executable; the
# binary looks for them next to itself, so they have to travel into the bundle.
for resource in "$BIN_PATH"/*.bundle(N); do
  ditto "$resource" "$APP/Contents/Resources/${resource:t}"
done
if [[ -n "${POPTART_MODEL_PACK_PUBLIC_KEY:-}" ]]; then
  plutil -replace PoptartModelPackPublicKey \
    -string "$POPTART_MODEL_PACK_PUBLIC_KEY" "$APP/Contents/Info.plist"
else
  echo "POPTART_MODEL_PACK_PUBLIC_KEY is unset; Model Pack actions will be unavailable in this build" >&2
fi
zsh "$REPO/Scripts/embed-sparkle.sh" "$APP" - development
codesign --force --sign - \
  --requirements '=designated => identifier "labs.playground.Poptart"' \
  "$APP" >/dev/null

if [[ "${1:-}" == "--bundle-only" ]]; then
  echo "bundled $APP"
  exit 0
fi

open -n "$APP"

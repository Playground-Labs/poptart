#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: notarize_app.sh SIGNED_APP NOTARY_KEYCHAIN_PROFILE" >&2
  exit 64
fi
app=$1
profile=$2
[ -d "$app" ] || { echo "signed application bundle is required" >&2; exit 1; }
[ -n "$profile" ] || { echo "notary keychain profile is required" >&2; exit 1; }
command -v codesign >/dev/null && command -v xcrun >/dev/null || { echo "Apple signing tools are required" >&2; exit 1; }
codesign --verify --deep --strict "$app"
archive=$(mktemp "${TMPDIR:-/tmp}/poptart-notary.XXXXXX.zip")
trap 'rm -f "$archive"' EXIT HUP INT TERM
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
echo "application notarization verified"

#!/bin/zsh
# Exercise the SDK's actual logging implementation in debug and release configurations.
set -euo pipefail
cd "$(dirname "$0")/../.."
CHECKOUT="${1:-.build/checkouts/FluidAudio}"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT
cat > "$TEMPORARY/Probe.swift" <<'SWIFT'
import Foundation

@main enum Probe {
    static func main() async throws {
        if CommandLine.arguments.contains("--disabled") { AppLogger.disableLogging() }
        let logger = AppLogger(category: "PrivacyProbe")
        logger.debug("synthetic-private-transcript")
        logger.warning("synthetic-private-vocabulary")
        logger.error("synthetic-private-error")
        // Debug console writes use detached tasks; allow them to drain in this isolated process.
        try await Task.sleep(for: .seconds(1))
    }
}
SWIFT
for configuration in debug release; do
  FLAGS=(-O)
  if [[ "$configuration" == debug ]]; then FLAGS=(-D DEBUG); fi
  swiftc "${FLAGS[@]}" -parse-as-library "$CHECKOUT/Sources/FluidAudio/Shared/AppLogger.swift" \
    "$TEMPORARY/Probe.swift" -o "$TEMPORARY/probe"
  "$TEMPORARY/probe" > "$TEMPORARY/enabled" 2>&1
  grep -q synthetic-private-vocabulary "$TEMPORARY/enabled"
  "$TEMPORARY/probe" --disabled > "$TEMPORARY/disabled" 2>&1
  [[ ! -s "$TEMPORARY/disabled" ]]
done
echo 'FluidAudio debug/release logging suppression passed.'

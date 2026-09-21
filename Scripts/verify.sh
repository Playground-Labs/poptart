#!/bin/zsh
# Model-free checks; hosted CI is not physical-hardware performance or live privacy evidence.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Training/prepare_corpus.py --check
swift build
swift test
for package in DictationCore Persistence ModelRuntime Cleanup Recognition SystemIntegration; do
  swift test --package-path "Packages/$package"
done
# Cleanup's safety predicates must also behave correctly under whole-module optimization.
swift test --package-path Packages/Cleanup -c release
python3 Scripts/test_tooling.py
python3 Evals/run.py --release-suite
swift run PoptartVerifier
zsh Scripts/privacy/check_fluid_logging.sh
for script in Scripts/privacy/*.sh Scripts/release/*.sh Scripts/*.sh; do
  zsh -n "$script"
done

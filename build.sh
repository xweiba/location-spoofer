#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

usage() {
  cat <<'USAGE'
Usage: ./build.sh [--test]

Builds dist/PaopaoLocationSpoofer-unsigned.ipa without signing it.

Options:
  --test  After the unsigned IPA is created, run iOS Simulator unit tests.
USAGE
}

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    echo "$install_hint" >&2
    exit 1
  fi
}

run_simulator_tests() {
  local simulator_destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"

  xcodebuild \
    -project PaopaoLocationSpoofer.xcodeproj \
    -scheme PaopaoLocationSpoofer \
    -destination "$simulator_destination" \
    test
}

run_tests=0
case "${1:-}" in
  '')
    ;;
  --test)
    run_tests=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

require_command xcrun "Install Xcode and its Command Line Tools."
require_command xcodebuild "Install Xcode and select it with xcode-select."
require_command xcodegen "Install XcodeGen: brew install xcodegen"
require_command go "Install Go 1.26 or newer."

"$ROOT/Scripts/build-unsigned-ipa.sh"

IPA="$ROOT/dist/PaopaoLocationSpoofer-unsigned.ipa"
test -s "$IPA"
echo "Unsigned IPA created: $IPA"

if [ "$run_tests" -eq 1 ]; then
  run_simulator_tests
fi

echo "Next: sign with Impactor (https://github.com/claration/Impactor) and install on device."

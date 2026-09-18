#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
xcodegen generate --spec "$ROOT/project.yml"
xcodebuild test -project "$ROOT/SessionNavigationChecks.xcodeproj" -scheme SessionNavigationChecks \
  -destination 'platform=macOS' -derivedDataPath /tmp/ripul-session-navigation-tests \
  -parallel-testing-enabled NO "$@"

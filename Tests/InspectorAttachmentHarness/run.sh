#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SIMULATOR="${1:?usage: run.sh <simulator-UDID> [xcodebuild options]}"
RESULT="/tmp/ripul-inspector-attachments-$(date +%Y%m%d%H%M%S).xcresult"
xcodegen generate --spec "$ROOT/project.yml"
xcodebuild test -project "$ROOT/InspectorAttachmentChecks.xcodeproj" -scheme InspectorAttachmentChecks \
  -destination "platform=iOS Simulator,id=$SIMULATOR" \
  -derivedDataPath /tmp/ripul-host-preview-ios-dd -parallel-testing-enabled NO \
  -resultBundlePath "$RESULT" CODE_SIGNING_ALLOWED=NO "${@:2}"
echo "Results: $RESULT"

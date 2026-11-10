#!/bin/bash
# UI checks for CmsAppView against the scratch site `tab-bar-iphone-scratch`
# (docs/cms-app-view.md). Borrow a simulator first and pass its UDID:
#   ripul-train acquire simulators os=26 type=iPhone --reason "…" --wait
#   bash run.sh <udid> [screenshot dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
UDID="${1:?simulator UDID}"
SHOTS="${2:-/tmp/cms-app-view-shots}"
mkdir -p "$SHOTS"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
# A throwaway DerivedData outside the sanctioned paths, removed when done.
DD=/tmp/ripul-cms-app-view-tests
trap 'rm -rf "$DD"' EXIT
xcodegen generate --spec "$ROOT/project.yml"
TEST_RUNNER_CMS_SHOTS="$SHOTS" xcodebuild test -project "$ROOT/CmsAppViewChecks.xcodeproj" -scheme CmsAppViewChecks \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" -parallel-testing-enabled NO

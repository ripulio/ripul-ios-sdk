#!/bin/bash
# A sign-in returning to this device (LoopbackSignInReturn.swift): the request
# line, which return is taken, and the listener on this Mac's loopback.
set -euo pipefail
test_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d /tmp/ripul-loopback-sign-in-tests.XXXXXX)"
trap 'rm -rf "$test_build"' EXIT
swiftc -parse-as-library -module-cache-path "$test_build/modules" \
  "$test_root/Sources/RipulAgent/Sessions/LoopbackSignInReturn.swift" \
  "$test_root/Tests/LoopbackSignInReturn/main.swift" -o "$test_build/loopback-checks"
"$test_build/loopback-checks"

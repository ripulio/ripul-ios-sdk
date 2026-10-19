#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
EMBEDDED_TEST_BUILD=$(mktemp -d /tmp/ripul-embedded-tests.XXXXXX)
trap 'rm -rf "$EMBEDDED_TEST_BUILD"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library ../../Sources/RipulAgent/EmbeddedAgentClient.swift main.swift -o "$EMBEDDED_TEST_BUILD/checks"
"$EMBEDDED_TEST_BUILD/checks"

#!/bin/bash
# Compiles the production RipulInviteManager.swift alone against small
# stand-ins (Fixture.swift) and a URLProtocol transport, then runs the checks.
set -euo pipefail
cd "$(dirname "$0")"
TMP_BUILD=$(mktemp -d /tmp/ripul-invite-tests.XXXXXX)
trap 'rm -rf "$TMP_BUILD"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library Fixture.swift ../../Sources/RipulAgent/Sessions/RipulAccountIdentity.swift ../../Sources/RipulAgent/Sessions/RipulInviteManager.swift main.swift -o "$TMP_BUILD/checks"
"$TMP_BUILD/checks"

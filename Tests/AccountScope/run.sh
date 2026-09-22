#!/bin/bash
# Compiles the production RipulAccountIdentity.swift + RipulAccountScopedCache.swift
# alone against a small stand-in cache (Fixture.swift), then runs the checks.
set -euo pipefail
cd "$(dirname "$0")"
TMP_BUILD=$(mktemp -d /tmp/ripul-account-scope-tests.XXXXXX)
trap 'rm -rf "$TMP_BUILD"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  Fixture.swift \
  ../../Sources/RipulAgent/Sessions/RipulAccountIdentity.swift \
  ../../Sources/RipulAgent/Sessions/RipulAccountScopedCache.swift \
  main.swift -o "$TMP_BUILD/checks"
"$TMP_BUILD/checks"

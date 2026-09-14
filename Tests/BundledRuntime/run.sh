#!/bin/bash
set -euo pipefail
test_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d /tmp/ripul-runtime-tests.XXXXXX)"
trap 'rm -rf "$test_build"' EXIT
swiftc -parse-as-library "$test_root/Sources/RipulAgent/BundledAgentRuntime.swift" \
  "$test_root/Sources/RipulAgent/StandaloneNetworkPolicy.swift" \
  "$test_root/Tests/BundledRuntime/main.swift" -o "$test_build/runtime-checks"
"$test_build/runtime-checks"

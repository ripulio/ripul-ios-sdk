#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
EMBED_LAYOUT_BUILD=$(mktemp -d /tmp/ripul-embed-layout.XXXXXX)
trap 'rm -rf "$EMBED_LAYOUT_BUILD"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library ../../Sources/RipulAgent/EmbeddedChatPresentation.swift main.swift -o "$EMBED_LAYOUT_BUILD/checks"
"$EMBED_LAYOUT_BUILD/checks"

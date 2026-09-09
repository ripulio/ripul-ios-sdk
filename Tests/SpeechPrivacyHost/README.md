# Speech privacy crash regression host

This iOS host deliberately omits privacy declarations. Do not add speech
permission strings to fix it: their absence is the regression fixture.

Generate with `xcodegen generate` in this directory. Run `xcodebuild test
-project SpeechPrivacyHost.xcodeproj -scheme PrivacyMissingBoth -destination
'platform=iOS Simulator,name=iPhone 17 Pro'`, then repeat with scheme
`PrivacyMissingSpeech`. The latter declares microphone usage only, matching
WAC before its host configuration fix.

Both schemes exercise the real providers and voice controller in the host
executable, plus UI tests that tap the SDK's microphone, dismiss its warning,
and verify the host remains responsive. Screenshots are retained in the test
result bundle. No account, site key, network, or microphone grant is needed.

Standalone macOS package tests run the declaration validation cases but skip
the host-dependent cases: Xcode's runner supplies its own privacy descriptions.

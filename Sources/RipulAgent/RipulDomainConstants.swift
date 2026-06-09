import Foundation

// ---------------------------------------------------------------------------
// Domain configuration (iOS SDK)
// ---------------------------------------------------------------------------
// Default Ripul-owned hostnames the SDK falls back to when an embedding app
// doesn't provide its own. Consumers always have the option to override (the
// AgentConfiguration / SessionChannelClient initializers accept any URL), so
// these constants are *defaults*, not invariants — but if you rebrand the
// hosted Ripul service, change rootDomain and every default updates with it.
//
// The same shape is duplicated in each other package's constants file
// (chrome-extension/src/config/constants.ts, packages/api,
// packages/stripe-webhook, ripul-native-app). Keep them in sync — there is
// intentionally no shared package between SDK, native, web, and workers, so
// the constants are the contract.
// ---------------------------------------------------------------------------

public enum RipulDomain {
    public static let rootDomain = "ripul.io"

    public static let demoHost = "demo.\(rootDomain)"
    public static let llmProxyHost = "llm-proxy.\(rootDomain)"

    public static let demoURL = "https://\(demoHost)"
    public static let llmProxyURL = "https://\(llmProxyHost)"
}

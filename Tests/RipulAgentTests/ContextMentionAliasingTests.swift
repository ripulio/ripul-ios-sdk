import XCTest
@testable import RipulAgent

/// The native composer shows a context mention as `@Label` and swaps the
/// `[context: …]` token back in at submit. What reaches the web send path must
/// come out byte-identical to what the picker produced — the resolver parses it
/// with its own regex, and a mention that survives display but not the round
/// trip fails silently as a missing `<context>` block.
final class ContextMentionAliasingTests: XCTestCase {

    /// A real token off the repo.branches provider — base64url payload, no
    /// padding, label after the pipe.
    private let branchToken = """
        [context: repo.branches/eyJyb290IjoiL1VzZXJzL3BldGVybWF1ZGUvRG9jdW1lbnRzL3JlcG9zL3JpcHVsIiwicmVmIjoicmVmcy9oZWFkcy93b3JrdHJlZS1jbXMtYmlsbGluZy1waGFzZTAiLCJuYW1lIjoid29ya3RyZWUtY21zLWJpbGxpbmctcGhhc2UwIiwicmVtb3RlIjpmYWxzZX0 | worktree-cms-billing-phase0]
        """

    func testCollapseHidesTheRefAndKeepsTheLabel() {
        var aliases: [String: String] = [:]
        let collapsed = ContextMentionAliasing.collapse(branchToken, into: &aliases)

        XCTAssertEqual(collapsed, "@worktree-cms-billing-phase0")
        XCTAssertFalse(collapsed.contains("eyJyb290"), "the base64url ref must not reach the field")
        XCTAssertEqual(aliases["@worktree-cms-billing-phase0"], branchToken)
    }

    func testExpandRestoresTheTokenExactly() {
        var aliases: [String: String] = [:]
        let collapsed = ContextMentionAliasing.collapse(branchToken, into: &aliases)

        XCTAssertEqual(ContextMentionAliasing.expand(collapsed, using: aliases), branchToken)
    }

    func testSurroundingProseIsPreserved() {
        var aliases: [String: String] = [:]
        let typed = "rebase \(branchToken) onto main please"
        let collapsed = ContextMentionAliasing.collapse(typed, into: &aliases)

        XCTAssertEqual(collapsed, "rebase @worktree-cms-billing-phase0 onto main please")
        XCTAssertEqual(ContextMentionAliasing.expand(collapsed, using: aliases), typed)
    }

    /// Back-to-front splicing: collapsing the first match must not invalidate
    /// the ranges of the ones after it.
    func testMultipleMentionsAllRoundTrip() {
        var aliases: [String: String] = [:]
        let a = "[context: repo.branches/YWJj | main]"
        let b = "[context: repo.branches/ZGVm | feature/x]"
        let typed = "diff \(a) against \(b)"
        let collapsed = ContextMentionAliasing.collapse(typed, into: &aliases)

        XCTAssertEqual(collapsed, "diff @main against @feature/x")
        XCTAssertEqual(ContextMentionAliasing.expand(collapsed, using: aliases), typed)
    }

    /// One label prefixing another — expand sorts longest-first so `@main`
    /// can't eat the front of `@main-2`.
    func testPrefixingLabelsDoNotStealEachOthersText() {
        var aliases: [String: String] = [:]
        let short = "[context: repo.branches/YWJj | main]"
        let long = "[context: repo.branches/ZGVm | main-2]"
        let typed = "\(short) and \(long)"
        let collapsed = ContextMentionAliasing.collapse(typed, into: &aliases)

        XCTAssertEqual(collapsed, "@main and @main-2")
        XCTAssertEqual(ContextMentionAliasing.expand(collapsed, using: aliases), typed)
    }

    /// Nothing readable to put in the field, so the token stays as it is rather
    /// than collapsing to a bare "@".
    func testUnlabelledTokenIsLeftAlone() {
        var aliases: [String: String] = [:]
        let bare = "[context: page.blocks/hero]"
        XCTAssertEqual(ContextMentionAliasing.collapse(bare, into: &aliases), bare)
        XCTAssertTrue(aliases.isEmpty)
    }

    func testPlainTextIsUntouched() {
        var aliases: [String: String] = [:]
        let typed = "no mentions here, just an @person and a [bracket]"
        XCTAssertEqual(ContextMentionAliasing.collapse(typed, into: &aliases), typed)
        XCTAssertTrue(aliases.isEmpty)
        XCTAssertEqual(ContextMentionAliasing.expand(typed, using: [:]), typed)
    }

    /// An alias the user has edited away simply doesn't match — the mention
    /// drops, which is what deleting the chip does on web.
    func testEditedAliasDropsRatherThanCorrupts() {
        var aliases: [String: String] = [:]
        _ = ContextMentionAliasing.collapse(branchToken, into: &aliases)

        let edited = "@worktree-cms"
        XCTAssertEqual(ContextMentionAliasing.expand(edited, using: aliases), edited)
    }

    /// Collapse runs on every text change, so it has to be a no-op the second
    /// time through or the field would fight itself.
    func testCollapseIsIdempotent() {
        var aliases: [String: String] = [:]
        let once = ContextMentionAliasing.collapse(branchToken, into: &aliases)
        let twice = ContextMentionAliasing.collapse(once, into: &aliases)

        XCTAssertEqual(once, twice)
    }
}

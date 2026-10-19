import XCTest
@testable import RipulAgent

@MainActor final class SessionTitleOrderingTests: XCTestCase {
    private func tab(_ title: String, version: Double?, source: String = "user") -> ChatSession {
        ChatSession(id: "chat", sourceChatId: "chat", displayName: title, createdAt: Date(),
                    displayNameSource: source, displayNameRenamedAt: version)
    }
    private func row(_ title: String, version: Double?) -> UnifiedSession {
        UnifiedSession(id: "chat", title: title, lastUsed: Date(), gitBranch: nil, messageCount: nil,
                       projectName: nil, provider: "claude-cli", providerLabel: "Claude", machineName: "Mac",
                       titleFromScan: true, titleRenamedAt: version, ripulSession: nil)
    }
    func testAStaleTabCannotUndoTheScanOrAConfirmedRename() throws {
        let scanned = row("New manual name", version: 200)
        XCTAssertFalse(scanned.acceptsLocalTitle(tab("Old manual name", version: 100)))
        XCTAssertFalse(scanned.acceptsLocalTitle(tab("Automatic summary", version: nil, source: "auto")))
        let newest = tab("Newest manual name", version: 300)
        XCTAssertTrue(scanned.acceptsLocalTitle(newest))
        let rematched = scanned.withRipulSession(newest, title: newest.displayName)
        XCTAssertTrue(rematched.titleFromScan, "Changing a name does not orphan a scanned row")
        XCTAssertEqual(rematched.titleRenamedAt, 300)
        let cached = try JSONDecoder().decode(UnifiedSession.self, from: JSONEncoder().encode(rematched))
        XCTAssertFalse(cached.acceptsLocalTitle(tab("Old manual name", version: 200)))
    }
    func testAnExplicitRenameBeatsAnAutomaticScan() {
        XCTAssertTrue(row("Generated title", version: nil).acceptsLocalTitle(tab("Chosen name", version: 10)))
    }
    /// A rescan merges each row over the last; the precedence must survive it.
    func testARescanKeepsWhereTheNameCameFrom() {
        let merged = row("Generated title", version: 300).coalescing(over: row("Older title", version: 200))
        XCTAssertTrue(merged.titleFromScan)
        XCTAssertEqual(merged.titleRenamedAt, 300)
        XCTAssertFalse(merged.acceptsLocalTitle(tab("Automatic summary", version: nil, source: "auto")))
    }
}

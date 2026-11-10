import XCTest

/// A sent message glides up, and a streaming reply follows it without jumps
/// (Peter, 5 November 2026: "when the user's chat goes in ... it's never
/// smooth, it's always a jump. When the user types something in ... it just
/// glides up", and replies sometimes "scroll up in blocks"). The harness
/// (`NativeChatFollowHarness`) opens a chat of 150 rows, lets it sit quiet,
/// raises the keyboard, sends (the keyboard going down), and streams a reply,
/// watching where the chat is drawn every frame. It runs twice: with Smooth
/// follow off, the control, then on, the one held to the rules.
final class NativeChatFollowUITests: XCTestCase {
    @MainActor
    func testSentMessageAndReplyGlideToTheEnd() throws {
        let control = try measure(old: true)
        let summary = try measure(old: false)
        print("[FOLLOWTEST] control (Smooth follow off): " + control)
        print("[FOLLOWTEST] Smooth follow on: " + summary)
        XCTAssertTrue(summary.contains("keyboard: ") && summary.contains("send: ") && summary.contains("stream: "), summary)
        XCTAssertFalse(summary.contains("frames=0 "), "Every phase was watched: " + summary)
        // The follow never goes to the end at once: the only offset writes that move
        // at once are a pinned anchor's corrections, which move the rows with the
        // offset and so nobody sees. Before 5 November 2026 the keyboard coming up
        // went 302 pt at once ("bandChange"), and a send 665 pt at once after 0.7 s
        // of not moving at all.
        let instant = summary.components(separatedBy: " instant=").last ?? ""
        let leaps = instant.split(separator: ",").filter { !$0.hasPrefix("anchor:") && !$0.isEmpty }
        XCTAssertTrue(leaps.isEmpty, "Nothing went to the end at once: \(leaps) in " + summary)
        // The chat starts down with the keyboard at once, a streaming reply never moves
        // a row more than 24 pt in a frame, and the keyboard coming up moves it at most
        // a glide's frame across the simulator's stalls (control: 302 pt at once).
        XCTAssertLessThanOrEqual(Self.value("firstMoveMs", in: "send", of: summary) ?? .max, 300,
                                 "The chat starts moving at once: " + summary)
        XCTAssertEqual(Self.value("seenJumps", in: "stream", of: summary), 0,
                       "The reply follows without jumps: " + summary)
        // A glide's fastest frame: the keyboard spring (30 rad/s) over about 360 pt (the
        // keyboard and a composer grown to four lines) moves up to about 66 pt in a 60 Hz
        // frame on the simulator. Control: 302-368 pt at once.
        XCTAssertLessThanOrEqual(Self.value("biggestSeenJump", in: "keyboard", of: summary) ?? .max, 100,
                                 "The chat rides up with the keyboard: " + summary)
        // Sending moves the chat at most the first frame of the keyboard going down:
        // KeyboardObserver.hideAnimation travels about half the way in its first frame
        // (165 pt of 302 on 5 November 2026). Control: 665 pt at once, after 0.7 s still.
        XCTAssertLessThanOrEqual(Self.value("biggestSeenJump", in: "send", of: summary) ?? .max, 200,
                                 "Nothing drops the chat by the keyboard's height at once: " + summary)
        // A message of more than one line drops the inset twice (the keyboard, then the
        // composer shrinking). It shows once both are down, within the send's 0.85 s, not
        // with the reply's first row (Peter, 5 November 2026: "anything over 1 line just
        // appears").
        let shown = summary.components(separatedBy: "sentShownMs=").last.flatMap { Int($0.prefix { $0.isNumber }) }
        XCTAssertLessThanOrEqual(shown ?? .max, 700, "The sent message shows once the keyboard is down: " + summary)
        // Not under the collapsing composer (cleared 150 ms in, its drop waited out for
        // 0.4 s), where its glide went unseen: the wait for a band's layout published it at
        // 216 ms.
        XCTAssertGreaterThanOrEqual(shown ?? 0, 400, "The sent message waits for the composer to collapse: " + summary)
    }

    /// The owned list keeping only the rows within a screen (`-perfOff listGrowth`), printed
    /// beside the default: what keeping and growing rows costs the keyboard and the send.
    @MainActor
    func testFollowWithoutKeptRows() throws {
        print("[FOLLOWTEST] without kept rows: " + (try measure(old: false, extra: ["-perfOff", "listGrowth"])))
        print("[FOLLOWTEST] with kept rows: " + (try measure(old: false)))
    }

    /// Rows in `UIHostingConfiguration` content views (`-perfOff rowController`, Debug),
    /// printed beside the hosting controllers rows are in, twice each.
    @MainActor
    func testFollowRowHostingControl() throws {
        for round in 1...2 {
            print("[FOLLOWTEST] round \(round) rows in content views: " + (try measure(old: false, extra: ["-perfOff", "rowController"])))
            print("[FOLLOWTEST] round \(round) rows in hosting controllers: " + (try measure(old: false)))
        }
    }

    @MainActor
    private func measure(old: Bool, extra: [String] = []) throws -> String {
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-follow-ui-tests"] + (old ? ["--old-follow"] : []) + extra
        app.launch()
        defer { app.terminate() }
        let result = app.staticTexts["NativeChatFollowHarness.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        // Asleep while the harness measures (about 14 s): every poll of a query takes a
        // snapshot of the app's whole accessibility tree on its main thread, which grows
        // with the rows mounted and showed as frame gaps in the phases measured.
        Thread.sleep(forTimeInterval: 16)
        let done = NSPredicate(format: "label BEGINSWITH 'done'")
        expectation(for: done, evaluatedWith: result)
        waitForExpectations(timeout: 40)
        let summary = result.label
        let note = XCTAttachment(string: summary)
        note.name = old ? "Follow measurements, Smooth follow off" : "Follow measurements"
        note.lifetime = .keepAlways
        add(note)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = old ? "The end of the reply, Smooth follow off" : "The end of the reply"
        shot.lifetime = .keepAlways
        add(shot)
        return summary
    }

    /// A number from one phase of the summary: "send: frames=… jumps=3 …".
    private static func value(_ name: String, in phase: String, of summary: String) -> Int? {
        guard let part = summary.components(separatedBy: " | ").first(where: { $0.contains(phase + ": ") }),
              let range = part.range(of: name + "=") else { return nil }
        return Int(part[range.upperBound...].prefix { $0.isNumber })
    }
}

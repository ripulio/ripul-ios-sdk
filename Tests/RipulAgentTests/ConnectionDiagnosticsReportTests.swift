import XCTest
@testable import RipulAgent

/// Built from a real captured failure: an iPhone that timed out at
/// `await-handshake:start` against "Macbook pro" while all three machines were
/// still checking in. Pairings are trimmed to 5 of the original 46 — the
/// grouping behaviour is what matters, not the volume.
final class ConnectionDiagnosticsReportTests: XCTestCase {

    private let capturedFailure = """
    {
      "ok": true,
      "at": "2026-09-09T07:58:44.440Z",
      "build": "mttq61kd",
      "uptimeSec": 29,
      "crash": { "live": null, "lastPersisted": null },
      "remoteBridge": {
        "available": true,
        "machines": [
          { "machineId": "machine-1776870094109-9gqysp", "displayName": "Chrome (macOS)",
            "lastSeenAt": "2026-09-09T07:58:11.863Z", "lastSeenAgoSec": 33, "presumedOnline": true },
          { "machineId": "machine-608AE09902954A95BECCD0E0554B9F78", "displayName": "Macbook pro",
            "lastSeenAt": "2026-09-09T07:58:04.841Z", "lastSeenAgoSec": 40, "presumedOnline": true },
          { "machineId": "machine-B62369ADA3BD4449B18F7774774CDC89", "displayName": "peter’s Mac Studio",
            "lastSeenAt": "2026-09-09T07:57:41.529Z", "lastSeenAgoSec": 63, "presumedOnline": true }
        ]
      },
      "pairings": [
        { "tabId": "cli_3eb76076", "machineId": "machine-608AE09902954A95BECCD0E0554B9F78", "machineName": "Macbook pro", "roomId": "machine:u:a" },
        { "tabId": "cli_5818a89d", "machineId": "machine-B62369ADA3BD4449B18F7774774CDC89", "machineName": "peter’s Mac Studio", "roomId": "machine:u:b" },
        { "tabId": "cli_96a68469", "machineId": "machine-B62369ADA3BD4449B18F7774774CDC89", "machineName": "peter’s Mac Studio", "roomId": "machine:u:b" },
        { "tabId": "cli_0c0cd682", "machineId": "machine-608AE09902954A95BECCD0E0554B9F78", "machineName": "Macbook pro", "roomId": "machine:u:a" },
        { "tabId": "cli_4f01c800-b2d3-4b29-8eb7-fa32904256cf", "machineId": "machine-608AE09902954A95BECCD0E0554B9F78", "machineName": "Macbook pro", "roomId": "machine:u:a" }
      ],
      "connections": [
        { "label": "cli-live-tail" },
        { "label": "remote-pairing-catchup" },
        { "label": "relay:machine:", "state": "connecting", "readyState": 0, "handshakeReady": false,
          "intent": "up", "reconnectAttempts": 3, "lastInboundAgoMs": null, "livenessTimeoutMs": 37500 },
        { "label": "relay:machine:", "state": "connecting", "readyState": 0, "handshakeReady": false,
          "intent": "up", "reconnectAttempts": 3, "lastInboundAgoMs": null, "livenessTimeoutMs": 37500 },
        { "label": "relay:placehol", "state": "reconnecting", "readyState": null, "handshakeReady": false,
          "intent": "up", "reconnectAttempts": 3, "lastInboundAgoMs": null, "livenessTimeoutMs": 37500 },
        { "label": "sessionchannel" },
        { "label": "session:904256cf", "state": "reconnecting", "readyState": null, "handshakeReady": false,
          "intent": "up", "reconnectAttempts": 3, "lastInboundAgoMs": null, "livenessTimeoutMs": 75000 }
      ],
      "connectPhase": {
        "phase": "await-handshake:start",
        "detail": "tab=cli_4f01c800-b2d3-4b29-8eb7-fa32904256cf pending=0",
        "at": 1788940700945,
        "elapsedMs": 90
      }
    }
    """

    private func parseCapturedFailure() throws -> ConnectionDiagnosticsReport {
        try XCTUnwrap(ConnectionDiagnosticsReport.parse(json: capturedFailure))
    }

    func testParsesTopLevelClientState() throws {
        let report = try parseCapturedFailure()
        XCTAssertEqual(report.build, "mttq61kd")
        XCTAssertEqual(report.uptimeSec, 29)
        XCTAssertEqual(report.capturedAt, "2026-09-09T07:58:44.440Z")
        XCTAssertEqual(report.remoteBridgeAvailable, true)
        XCTAssertTrue(report.sectionErrors.isEmpty)
    }

    func testNullCrashFieldsAreNotReportedAsCrashes() throws {
        let report = try parseCapturedFailure()
        XCTAssertNil(report.crashLive)
        XCTAssertNil(report.crashPersisted)
        XCTAssertFalse(report.hasCrash)
    }

    func testPhaseIsClassifiedAsAStalledRemoteWait() throws {
        let phase = try XCTUnwrap(parseCapturedFailure().phase)
        XCTAssertEqual(phase.raw, "await-handshake:start")
        XCTAssertEqual(phase.title, "Waiting for the machine to answer")
        XCTAssertTrue(phase.isStalled)
        XCTAssertEqual(phase.scope, .remote)
        XCTAssertEqual(phase.elapsedText, "90ms")
        XCTAssertEqual(phase.detailFields.map(\.key), ["tab", "pending"])
        XCTAssertEqual(phase.detailFields.first?.value, "cli_4f01c800-b2d3-4b29-8eb7-fa32904256cf")
    }

    /// The connect tracer exists because "restart the host" is wrong for local
    /// stalls. A local phase must say so rather than blaming the remote machine.
    func testLocalStallExplicitlyExoneratesTheRemoteMachine() throws {
        let local = ConnectionDiagnosticsReport.Phase(raw: "create-tab:start", detail: nil, elapsedMs: 12000)
        XCTAssertEqual(local.scope, .local)
        XCTAssertTrue(local.isStalled)
        XCTAssertEqual(local.title, "Creating the session (local storage)")
        XCTAssertTrue(try XCTUnwrap(local.scopeExplanation).contains("restarting it will not help"))

        let remote = ConnectionDiagnosticsReport.Phase(raw: "await-handshake:start", detail: nil, elapsedMs: 20000)
        XCTAssertTrue(try XCTUnwrap(remote.scopeExplanation).contains("never answered"))
    }

    func testCompletedPhaseHasNoBlameLine() {
        let done = ConnectionDiagnosticsReport.Phase(raw: "await-handshake:end", detail: nil, elapsedMs: 400)
        XCTAssertFalse(done.isStalled)
        XCTAssertNil(done.scopeExplanation)
    }

    /// The whole point of correlating the phase's `tab=` against the pairings:
    /// name the one machine the attempt was for, out of the three listed.
    func testTargetMachineIsResolvedFromThePhaseTab() throws {
        let report = try parseCapturedFailure()
        XCTAssertEqual(report.targetMachineId, "machine-608AE09902954A95BECCD0E0554B9F78")
        XCTAssertEqual(report.targetMachine?.displayName, "Macbook pro")
        XCTAssertEqual(report.targetMachine?.lastSeenText, "40s ago")
    }

    func testMachinesRetainPresenceState() throws {
        let report = try parseCapturedFailure()
        XCTAssertEqual(report.machines.count, 3)
        XCTAssertTrue(report.machines.allSatisfy(\.presumedOnline))
        XCTAssertEqual(report.machines.last?.lastSeenText, "1m 3s ago")
    }

    func testPairingsCollapseToPerMachineCountsInFirstSeenOrder() throws {
        let report = try parseCapturedFailure()
        XCTAssertEqual(report.totalPairings, 5)
        XCTAssertEqual(report.pairingGroups.map(\.machineName), ["Macbook pro", "peter’s Mac Studio"])
        XCTAssertEqual(report.pairingGroups.map(\.tabCount), [3, 2])
    }

    /// Two rooms produce two `relay:machine:` entries. Identifiable rows keyed on
    /// a duplicated label collapse onto each other in SwiftUI, so labels are
    /// disambiguated at parse time.
    func testDuplicateTransportLabelsAreDisambiguated() throws {
        let labels = try parseCapturedFailure().transports.map(\.label)
        XCTAssertEqual(labels.count, Set(labels).count)
        XCTAssertEqual(labels[2], "relay:machine:")
        XCTAssertEqual(labels[3], "relay:machine: #2")
    }

    func testTransportHealthClassification() throws {
        let transports = try parseCapturedFailure().transports
        func health(_ label: String) -> ConnectionDiagnosticsReport.TransportHealth? {
            transports.first { $0.label == label }?.health
        }
        // Recoverables with no diagnostics() are neutral, not failures.
        XCTAssertEqual(health("cli-live-tail"), .untracked)
        XCTAssertEqual(health("relay:machine:"), .connecting)
        XCTAssertEqual(health("relay:placehol"), .reconnecting)
        XCTAssertEqual(health("session:904256cf"), .reconnecting)
        XCTAssertEqual(try parseCapturedFailure().unhealthyTransports.count, 4)
    }

    /// An open socket that has not finished its handshake is still "connecting" —
    /// reporting it green is what made the old dump misleading.
    func testOpenSocketAwaitingHandshakeIsNotHealthy() {
        let json = """
        {"connections":[
          {"label":"a","state":"open","handshakeReady":false,"intent":"up"},
          {"label":"b","state":"open","handshakeReady":true,"intent":"up","lastInboundAgoMs":4200}
        ]}
        """
        let report = ConnectionDiagnosticsReport.parse(json: json)
        XCTAssertEqual(report?.transports.first?.health, .connecting)
        XCTAssertEqual(report?.transports.last?.health, .healthy)
        XCTAssertEqual(report?.transports.last?.detailText, "open · last traffic 4s ago")
    }

    func testTransportSubtitleNamesRetriesAndSilence() throws {
        let transport = try XCTUnwrap(parseCapturedFailure().transports.first { $0.label == "relay:placehol" })
        XCTAssertEqual(transport.detailText, "reconnecting · 3 retries · no traffic yet")
    }

    // MARK: Tolerance
    //
    // Every section of the snapshot is independently guarded on the web side and
    // reports {"error": …} when its subsystem is broken. That is precisely the
    // report you most want, so a broken section must not sink the whole parse.

    func testGuardedSectionErrorsAreSurfacedWithoutLosingOtherSections() throws {
        let json = """
        {"build":"abc","remoteBridge":{"error":"TypeError: bridge import failed"},
         "pairings":{"error":"QuotaExceededError"},
         "connectPhase":{"phase":"create-tab:start","elapsedMs":19000}}
        """
        let report = try XCTUnwrap(ConnectionDiagnosticsReport.parse(json: json))
        XCTAssertEqual(report.build, "abc")
        XCTAssertEqual(report.phase?.raw, "create-tab:start")
        XCTAssertTrue(report.machines.isEmpty)
        XCTAssertEqual(report.sectionErrors["remoteBridge"], "TypeError: bridge import failed")
        XCTAssertEqual(report.sectionErrors["pairings"], "QuotaExceededError")
    }

    func testMissingSectionsDegradeToEmptyRatherThanFailing() throws {
        let report = try XCTUnwrap(ConnectionDiagnosticsReport.parse(json: #"{"ok":true}"#))
        XCTAssertNil(report.phase)
        XCTAssertNil(report.targetMachineId)
        XCTAssertTrue(report.machines.isEmpty)
        XCTAssertTrue(report.transports.isEmpty)
        XCTAssertEqual(report.totalPairings, 0)
    }

    func testNonObjectPayloadsReturnNilSoTheSheetFallsBackToRawText() {
        XCTAssertNil(ConnectionDiagnosticsReport.parse(json: "not json at all"))
        XCTAssertNil(ConnectionDiagnosticsReport.parse(json: "null"))
        XCTAssertNil(ConnectionDiagnosticsReport.parse(json: "[1,2,3]"))
    }

    func testCrashObjectIsRenderedRatherThanDropped() throws {
        let json = #"{"crash":{"live":"ReferenceError: x","lastPersisted":{"at":1,"message":"boom"}}}"#
        let report = try XCTUnwrap(ConnectionDiagnosticsReport.parse(json: json))
        XCTAssertTrue(report.hasCrash)
        XCTAssertEqual(report.crashLive, "ReferenceError: x")
        XCTAssertEqual(report.crashPersisted, #"{"at":1,"message":"boom"}"#)
    }

    /// The copy-JSON button must hand over the whole payload, not the subset the
    /// structured view happens to render.
    func testRawJSONRoundTripsEveryFieldIncludingUnmodelledOnes() throws {
        let report = try parseCapturedFailure()
        let reparsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(report.rawJSON.data(using: .utf8))) as? [String: Any]
        )
        XCTAssertEqual(reparsed["build"] as? String, "mttq61kd")
        XCTAssertEqual(reparsed["ok"] as? Bool, true)
        // roomId is never displayed, but a pasted report still has to contain it.
        let pairings = try XCTUnwrap(reparsed["pairings"] as? [[String: Any]])
        XCTAssertEqual(pairings.count, 5)
        XCTAssertEqual(pairings.first?["roomId"] as? String, "machine:u:a")
    }

    func testDurationTextScalesFromSecondsToHours() {
        XCTAssertEqual(ConnectionDiagnosticsReport.durationText(seconds: 0), "0s")
        XCTAssertEqual(ConnectionDiagnosticsReport.durationText(seconds: 59), "59s")
        XCTAssertEqual(ConnectionDiagnosticsReport.durationText(seconds: 60), "1m")
        XCTAssertEqual(ConnectionDiagnosticsReport.durationText(seconds: 3600), "1h 0m")
    }
}

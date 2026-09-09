import XCTest
@testable import RipulAgent

final class SpeechPrivacyRequirementsTests: XCTestCase {
    private func withBundle(_ declarations: [String: Any], check: (Bundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var info = declarations
        info["CFBundleIdentifier"] = "io.ripul.speech-privacy-test.\(UUID().uuidString)"
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        try check(XCTUnwrap(Bundle(url: directory)))
    }

    func testHostWithOnlyMicrophoneDeclarationRejectsAppleButAllowsCloud() throws {
        try withBundle(["NSMicrophoneUsageDescription": "Record voice messages"]) { bundle in
            XCTAssertThrowsError(try SpeechPrivacyRequirements.validate(requiresSpeechRecognition: true, bundle: bundle)) {
                XCTAssertEqual($0 as? SpeechPrivacyRequirements.MissingUsageDescription,
                               .init(key: "NSSpeechRecognitionUsageDescription"))
            }
            XCTAssertNoThrow(try SpeechPrivacyRequirements.validate(requiresSpeechRecognition: false, bundle: bundle))
        }
    }

    func testMissingEmptyAndInvalidDeclarationsAreRejected() throws {
        for value: Any in ["", " \n\t", 123] {
            for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
                var info: [String: Any] = [
                    "NSMicrophoneUsageDescription": "Record voice messages",
                    "NSSpeechRecognitionUsageDescription": "Transcribe voice messages"
                ]
                info[key] = value
                try withBundle(info) { bundle in
                    XCTAssertThrowsError(try SpeechPrivacyRequirements.validate(requiresSpeechRecognition: true, bundle: bundle)) {
                        XCTAssertEqual($0 as? SpeechPrivacyRequirements.MissingUsageDescription, .init(key: key))
                    }
                }
            }
        }
        try withBundle([:]) { bundle in
            XCTAssertThrowsError(try SpeechPrivacyRequirements.validate(requiresSpeechRecognition: false, bundle: bundle))
        }
    }

    func testConfiguredHostPassesPreflight() throws {
        try withBundle([
            "NSMicrophoneUsageDescription": "Record voice messages",
            "NSSpeechRecognitionUsageDescription": "Transcribe voice messages"
        ]) { bundle in
            XCTAssertNoThrow(try SpeechPrivacyRequirements.validate(requiresSpeechRecognition: true, bundle: bundle))
        }
    }

    /// Exercise the real entry points in hosts missing either both declarations
    /// or only speech recognition (the original WAC configuration).
    /// Calling the old implementation here would terminate the test process.
    @MainActor
    func testRealProvidersReturnErrorsWithoutKillingUndeclaredHost() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        try XCTSkipIf(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
                      "Run in SpeechPrivacyHost: Xcode's standalone runner supplies its own declarations")
        let missingMicrophone = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil
        let missingKey = missingMicrophone ? "NSMicrophoneUsageDescription" : "NSSpeechRecognitionUsageDescription"
        var tokenRequested = false
        var providers: [any NativeSpeechProviding] = [AppleSpeechProvider()]
        if missingMicrophone {
            providers.append(ElevenLabsNativeSpeechProvider(tokenProvider: { tokenRequested = true; return nil }))
        }
        for provider in providers {
            do {
                try await provider.startTranscription { _ in XCTFail("Capture must not start") }
                XCTFail("Undeclared host must fail before requesting permission")
            } catch {
                XCTAssertEqual(error as? SpeechPrivacyRequirements.MissingUsageDescription,
                               .init(key: missingKey))
            }
        }
        XCTAssertFalse(tokenRequested)
        XCTAssertFalse(SpeechService.shared.isTranscribing)
    }

    @MainActor
    func testVoiceModeWarnsAndStaysInactiveWithoutStartingAudioOrRetrying() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        try XCTSkipIf(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
                      "Run in SpeechPrivacyHost: Xcode's standalone runner supplies its own declarations")
        let oldProfile = SpeechPreferences.activeProfile
        defer { SpeechPreferences.activeProfile = oldProfile }
        SpeechPreferences.activeProfile = VoiceProfileConfig(sttProviderId: "apple-native", allowUserOverride: false)
        let controller = VoiceModeController()
        controller.start(bridge: AgentBridge(), tokenProvider: nil)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.captureLive)
        XCTAssertFalse(VoiceAudioSession.isHeld)
        let warning = try XCTUnwrap(controller.microphoneWarning)
        XCTAssertTrue(warning.contains("continue by typing"))
        // A normal voice notice retries after 2.2 seconds. Setup warnings must not.
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertEqual(controller.microphoneWarning, warning)
        controller.microphoneWarning = nil
        XCTAssertNil(controller.microphoneWarning)
    }
}

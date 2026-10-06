import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one gate in front of Apple's on-device model. Every FoundationModels
/// call in the SDK and the apps checks `isUsable` first.
///
/// WHY NOT JUST `SystemLanguageModel.default.isAvailable`: the 26.0 betas
/// shipped an older FoundationModels API. macOS 26.0 build 25A5306g (summer
/// 2025) has no `LanguageModelSession(model:tools:instructions:)`, no
/// `respond(to:generating:includeSchemaInPrompt:options:)`, no `prewarm(promptPrefix:)`
/// and no `GeneratedContent.jsonString`. The SDK marks all of them 26.0, so
/// `#available(26)` passes there too. Calling one is a crash.
///
/// The apps weak-link FoundationModels (OTHER_LDFLAGS in project.yml) so a
/// missing symbol can't stop the launch. A weakly linked function that is
/// missing is null, and this gate makes sure nothing calls it.
/// `scripts/check_os_symbols.py` lists what a given OS build is missing.
public enum OnDeviceModel {
    /// True when the model may be called on this device right now.
    /// Availability changes (Apple Intelligence switched off, assets still
    /// downloading), so it is checked per call, not cached.
    public static var isUsable: Bool { unusableReason == nil }

    /// Why the model can't be used, in words, or nil when it can.
    public static var unusableReason: String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return "needs iOS 26 or macOS 26" }
        if isEarlyBeta { return "this is a pre-release build of \(osVersion) (\(osBuild)), whose on-device model API is older than the app's" }
        let model = SystemLanguageModel.default
        return model.isAvailable ? nil : "\(model.availability)"
        #else
        return "FoundationModels is not in this SDK"
        #endif
    }

    /// A pre-release of x.0 for the first FoundationModels OS (26). Beta
    /// builds end in a lowercase letter (25A5306g); releases don't (25A354).
    /// Betas of 26.1 and later carry the released 26.0 API, so they pass.
    static var isEarlyBeta: Bool {
        isEarlyBeta(version: ProcessInfo.processInfo.operatingSystemVersion, build: osBuild)
    }

    static func isEarlyBeta(version v: OperatingSystemVersion, build: String) -> Bool {
        guard v.majorVersion == 26, v.minorVersion == 0 else { return false }
        return build.last.map { $0.isLetter && $0.isLowercase } ?? false
    }

    /// The OS build, "25A5306g". `kern.osversion` is the build, not the version.
    static let osBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }()

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}

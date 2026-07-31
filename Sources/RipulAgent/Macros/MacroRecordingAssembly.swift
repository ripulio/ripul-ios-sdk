import Foundation

/// Pure step-list assembly for recording — no UIKit, so `swift test` covers
/// the exact rules the overlay applies:
/// - a pause is inserted BEFORE a newly recorded action only when there's
///   already a step (never a leading pause, never a trailing one),
/// - `pauseSeconds <= 0` disables it entirely.
public enum MacroRecordingAssembly {
    public static func appending(_ step: MacroStep, to steps: [MacroStep], autoPauseSeconds: Double) -> [MacroStep] {
        var out = steps
        if autoPauseSeconds > 0, !out.isEmpty {
            let pause = MacroStep(kind: .pause, selector: MacroSelector(), seconds: autoPauseSeconds,
                                  recordedLabel: "Pause \(MacroRecordingAssembly.formatSeconds(autoPauseSeconds))s")
            out.append(pause)
        }
        out.append(step)
        return out
    }

    /// "1" for whole seconds, "1.5" otherwise — keeps the recorded label tidy.
    static func formatSeconds(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

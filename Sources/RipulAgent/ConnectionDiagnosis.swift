import SwiftUI

// MARK: - Connection diagnosis (friendly summary + expandable runtime details)
//
// Replaces the bare "Connection Failed: <raw error>" alert. The raw error string
// the app already produces is classified into a friendly one-line summary + an
// actionable hint; the raw error (plus the live connect-phase trace from
// window.__ripulConnectPhase) is preserved verbatim in an expandable "Technical
// details" section the end user can copy and send to us. No call sites change —
// presenters just swap `.alert(...)` for `.connectionDiagnosis($error, bridge:)`.

/// Friendly classification of a raw connection/new-session error. Pure data — no
/// availability gate — so it can be computed anywhere.
public struct ConnectionDiagnosis {
    public let summary: String
    public let hint: String?
    public let details: String

    /// Map a raw error (+ optional live connect-phase trace) into a friendly
    /// summary/hint while preserving the raw text in `details`.
    public static func classify(rawError: String?, phase: String?) -> ConnectionDiagnosis {
        let raw = (rawError?.isEmpty == false) ? rawError! : "Unknown error"
        let lower = raw.lowercased()
        var lines: [String] = []
        if let phase, !phase.isEmpty { lines.append("Last connect phase: \(phase)") }
        lines.append("Reason: \(raw)")
        let details = lines.joined(separator: "\n")

        func d(_ summary: String, _ hint: String) -> ConnectionDiagnosis {
            ConnectionDiagnosis(summary: summary, hint: hint, details: details)
        }

        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("didn't come back") || lower.contains("unresponsive") {
            return d("Couldn’t reach the machine in time",
                     "It usually IS online — this is most often a stale link after the app was in the background. Try again; it normally connects on the second attempt. If it keeps failing, expand the details and send them to us.")
        }
        if lower.contains("offline") {
            return d("That machine looks offline",
                     "Make sure Ripul is open and awake on it, then try again.")
        }
        if lower.contains("not found") {
            return d("That machine isn’t in your list",
                     "Pull to refresh your machines, or check it’s signed in to the same account.")
        }
        if lower.contains("not ready") || lower.contains("bridge") || lower.contains("starting") {
            return d("Ripul is still starting up",
                     "Give it a moment, then try again.")
        }
        return d("Couldn’t connect",
                 "Try again. If it keeps happening, expand the details below and send them to us.")
    }
}

/// A compact, friendly sheet: summary headline + actionable hint + an expandable,
/// copyable technical-details section (raw error + live connect-phase trace).
@available(iOS 16.0, macOS 13.0, *)
public struct ConnectionDiagnosisSheet: View {
    let rawError: String
    var bridge: AgentBridge?
    var onClose: () -> Void

    @State private var showDetails = false
    @State private var livePhase: String?

    public init(rawError: String, bridge: AgentBridge? = nil, onClose: @escaping () -> Void) {
        self.rawError = rawError
        self.bridge = bridge
        self.onClose = onClose
    }

    private var diagnosis: ConnectionDiagnosis {
        ConnectionDiagnosis.classify(rawError: rawError, phase: livePhase)
    }

    public var body: some View {
        let diag = diagnosis
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(diag.summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = diag.hint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(diag.details)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { copyDetails(diag.details) } label: {
                        Label("Copy details", systemImage: "doc.on.doc").font(.caption)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Technical details").font(.subheadline.weight(.medium))
            }
            Spacer(minLength: 0)
            Button { onClose() } label: {
                Text("Close").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        #if os(iOS)
        .presentationDetents(showDetails ? [.large] : [.medium])
        #endif
        // Best-effort: pull the live connect-phase trace so the details name WHERE
        // the connect actually stalled (local IDB vs the relay handshake).
        .task {
            if let p = await bridge?.getConnectPhase() { livePhase = p }
        }
    }

    private func copyDetails(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

@available(iOS 16.0, macOS 13.0, *)
public extension View {
    /// Present a friendly, expandable connection-failure diagnosis instead of a
    /// bare alert. Drives off the existing `String?` error binding — non-nil shows
    /// the sheet, dismiss clears it.
    func connectionDiagnosis(_ error: Binding<String?>, bridge: AgentBridge? = nil) -> some View {
        sheet(isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            ConnectionDiagnosisSheet(
                rawError: error.wrappedValue ?? "",
                bridge: bridge,
                onClose: { error.wrappedValue = nil }
            )
        }
    }
}

import Foundation

// MARK: - Structured client-diagnostics report
//
// `AgentBridge.fetchWebDiagnostics()` returns the raw JSON string produced by
// `window.__ripulDiagnostics` (see FrameMCPBridge). Dumping that string into the
// failure sheet was technically complete and practically unreadable: the real
// signal — WHERE the connect stalled, whether the target machine had checked in
// recently, which transport was down — sat behind ~50 near-identical pairing
// entries. This turns the payload into a model the sheet can render as sections,
// while the raw JSON stays verbatim for the copy button.
//
// Parsing is deliberately tolerant rather than `Codable`: every section of the
// snapshot is independently guarded on the web side and reports `{"error": ...}`
// when its subsystem is broken. A strict decoder would throw away the whole
// report over one broken section — which is exactly the report you most want.

public struct ConnectionDiagnosticsReport: Equatable {

    // MARK: Sub-models

    /// A machine as the relay's presence list last saw it.
    public struct Machine: Equatable, Identifiable {
        public let machineId: String
        public let displayName: String
        public let lastSeenAgoSec: Int?
        public let presumedOnline: Bool
        public var id: String { machineId }

        /// "40s ago" / "3m 20s ago" — nil when the snapshot carried no timestamp.
        public var lastSeenText: String? {
            guard let lastSeenAgoSec else { return nil }
            return "\(ConnectionDiagnosticsReport.durationText(seconds: lastSeenAgoSec)) ago"
        }
    }

    /// Health of one relay/session transport, as the sheet colour-codes it.
    public enum TransportHealth: Equatable {
        case healthy      // socket open and past its handshake
        case connecting   // dialling or waiting on the handshake
        case reconnecting // dropped and retrying
        case down         // intent up, but the socket is gone
        case untracked    // a recoverable that exposes no transport telemetry
    }

    /// One entry of the snapshot's `connections` array.
    public struct Transport: Equatable, Identifiable {
        public let label: String
        public let state: String?
        public let readyState: Int?
        public let handshakeReady: Bool?
        public let intent: String?
        public let reconnectAttempts: Int?
        public let lastInboundAgoMs: Int?
        public let livenessTimeoutMs: Int?
        public let diagnosticsError: String?
        public var id: String { label }

        public var health: TransportHealth {
            if diagnosticsError != nil { return .down }
            guard let state else { return .untracked }
            switch state {
            case "open", "connected", "ready":
                return handshakeReady == false ? .connecting : .healthy
            case "connecting":
                return .connecting
            case "reconnecting":
                return .reconnecting
            default:
                return intent == "up" ? .down : .untracked
            }
        }

        /// "connecting · 3 retries · no traffic yet" — the one-line subtitle.
        public var detailText: String {
            var parts: [String] = []
            if let state { parts.append(state) }
            if let attempts = reconnectAttempts, attempts > 0 {
                parts.append("\(attempts) retr\(attempts == 1 ? "y" : "ies")")
            }
            if let ago = lastInboundAgoMs {
                parts.append("last traffic \(ConnectionDiagnosticsReport.durationText(seconds: ago / 1000)) ago")
            } else if state != nil {
                parts.append("no traffic yet")
            }
            if let diagnosticsError { parts.append(diagnosticsError) }
            return parts.isEmpty ? "no telemetry" : parts.joined(separator: " · ")
        }
    }

    /// Paired tabs collapsed per machine. The raw list routinely runs to dozens
    /// of entries that differ only by tab id; the count is the only part anyone
    /// reads, and the full list is one copy-JSON away.
    public struct PairingGroup: Equatable, Identifiable {
        public let machineId: String
        public let machineName: String
        public let tabCount: Int
        public var id: String { machineId }
    }

    /// Where in the connect sequence the attempt got to.
    public struct Phase: Equatable {
        public let raw: String
        public let detail: String?
        public let elapsedMs: Int?

        /// Whether this phase waits on the local device or the remote machine.
        /// The connect tracer exists because "Try restarting the host" is a
        /// guess that is wrong for every local phase — so say which it is.
        public enum Scope: Equatable { case local, remote, unknown }

        public var scope: Scope {
            switch raw {
            case "enter", "bridge-imported", "machine-found", "machine-not-found",
                 "machine-not-found:refresh", "set-model:start", "raw-mode-setup":
                return .local
            case let p where p.hasPrefix("create-tab"), let p where p.hasPrefix("prepend"),
                 let p where p.hasPrefix("init-actions"), let p where p.hasPrefix("pair"):
                return .local
            case "machine-offline", "provider-done", "provider-error", "done":
                return .remote
            case let p where p.hasPrefix("await-handshake"):
                return .remote
            default:
                return .unknown
            }
        }

        /// A phase that opened without its matching `:end` is the one that hung.
        public var isStalled: Bool { raw.hasSuffix(":start") }

        public var title: String {
            switch raw {
            case "enter": return "Starting the connection"
            case "bridge-imported": return "Loaded the relay bridge"
            case "machine-found": return "Found the machine"
            case "machine-not-found", "machine-not-found:refresh": return "Machine not in your list"
            case "machine-offline": return "Machine reported offline"
            case "create-tab:start": return "Creating the session (local storage)"
            case "create-tab:end": return "Created the session"
            case "create-tab:failed": return "Could not create the session"
            case "pair:start": return "Pairing the session to the machine"
            case "prepend:start", "prepend:end": return "Preparing the session"
            case "init-actions:start", "init-actions:end": return "Setting up session actions"
            case "set-model:start": return "Selecting the model"
            case "await-handshake:start": return "Waiting for the machine to answer"
            case "await-handshake:end": return "Machine answered"
            case "raw-mode-setup": return "Configuring raw mode"
            case "provider-done": return "Provider ready"
            case "provider-error": return "Provider failed"
            case "done": return "Connected"
            case "error": return "The connection threw an error"
            default: return raw
            }
        }

        /// The blame line under the phase title — the whole point of the tracer.
        public var scopeExplanation: String? {
            guard isStalled || raw == "error" else { return nil }
            switch scope {
            case .local:
                return "This step runs entirely on this device — the remote machine was not involved yet, so restarting it will not help."
            case .remote:
                return "This step waits on the remote machine. It never answered."
            case .unknown:
                return nil
            }
        }

        /// `tab=cli_… pending=0` split into labelled pairs for the chip row.
        public var detailFields: [(key: String, value: String)] {
            guard let detail, !detail.isEmpty else { return [] }
            return detail.split(separator: " ").compactMap { token in
                let parts = token.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
        }

        /// The tab this attempt was for, so the report can name the machine it
        /// was actually talking to instead of listing all of them equally.
        public var tabId: String? {
            detailFields.first { $0.key == "tab" }?.value
        }

        public var elapsedText: String? {
            guard let elapsedMs else { return nil }
            return elapsedMs < 1000 ? "\(elapsedMs)ms" : ConnectionDiagnosticsReport.durationText(seconds: elapsedMs / 1000)
        }
    }

    // MARK: Fields

    public let capturedAt: String?
    public let build: String?
    public let uptimeSec: Int?
    public let crashLive: String?
    public let crashPersisted: String?
    public let remoteBridgeAvailable: Bool?
    public let machines: [Machine]
    public let pairingGroups: [PairingGroup]
    public let totalPairings: Int
    public let transports: [Transport]
    public let phase: Phase?
    /// machineId of the machine this attempt was for, resolved via the pairings.
    public let targetMachineId: String?
    /// Section name → error string, for subsystems that failed to report.
    public let sectionErrors: [String: String]
    /// The verbatim payload, for the copy-JSON button.
    public let rawJSON: String

    public var targetMachine: Machine? {
        guard let targetMachineId else { return nil }
        return machines.first { $0.machineId == targetMachineId }
    }

    /// Transports worth showing first: anything not healthy or untracked.
    public var unhealthyTransports: [Transport] {
        transports.filter { $0.health != .healthy && $0.health != .untracked }
    }

    public var hasCrash: Bool { crashLive != nil || crashPersisted != nil }

    // MARK: Parsing

    /// Parse a `__ripulDiagnostics` payload. Returns nil only when the string is
    /// not a JSON object at all — every other malformation degrades to a missing
    /// field so the sheet still renders whatever survived.
    public static func parse(json: String) -> ConnectionDiagnosticsReport? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        var sectionErrors: [String: String] = [:]
        /// A guarded section reports `{"error": ...}` in place of its payload.
        func section(_ key: String) -> [String: Any]? {
            guard let value = root[key] as? [String: Any] else { return nil }
            if let error = value["error"] as? String {
                sectionErrors[key] = error
                return nil
            }
            return value
        }

        let crash = section("crash")
        let bridge = section("remoteBridge")

        let machines: [Machine] = (bridge?["machines"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let machineId = entry["machineId"] as? String else { return nil }
            return Machine(
                machineId: machineId,
                displayName: (entry["displayName"] as? String) ?? machineId,
                lastSeenAgoSec: intValue(entry["lastSeenAgoSec"]),
                presumedOnline: (entry["presumedOnline"] as? Bool) ?? false
            )
        }

        // `pairings` is an array when healthy and `{"error": …}` when not.
        var pairings: [[String: Any]] = []
        if let array = root["pairings"] as? [[String: Any]] {
            pairings = array
        } else if let error = (root["pairings"] as? [String: Any])?["error"] as? String {
            sectionErrors["pairings"] = error
        }

        // Preserve first-appearance order: a stable list reads better across two
        // snapshots of the same failure than one that reshuffles by count.
        var groupOrder: [String] = []
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        var tabToMachine: [String: String] = [:]
        for pairing in pairings {
            guard let machineId = pairing["machineId"] as? String else { continue }
            if counts[machineId] == nil { groupOrder.append(machineId) }
            counts[machineId, default: 0] += 1
            if names[machineId] == nil {
                names[machineId] = (pairing["machineName"] as? String) ?? machineId
            }
            if let tabId = pairing["tabId"] as? String { tabToMachine[tabId] = machineId }
        }
        let pairingGroups = groupOrder.map { machineId in
            PairingGroup(
                machineId: machineId,
                machineName: names[machineId] ?? machineId,
                tabCount: counts[machineId] ?? 0
            )
        }

        var connections: [[String: Any]] = []
        if let array = root["connections"] as? [[String: Any]] {
            connections = array
        } else if let error = (root["connections"] as? [String: Any])?["error"] as? String {
            sectionErrors["connections"] = error
        }
        // Labels repeat (`relay:machine:` appears once per room), and Identifiable
        // needs them distinct or SwiftUI collapses the rows onto one another.
        var seenLabels: [String: Int] = [:]
        let transports: [Transport] = connections.map { entry in
            let base = (entry["label"] as? String) ?? "connection"
            let occurrence = seenLabels[base, default: 0]
            seenLabels[base] = occurrence + 1
            return Transport(
                label: occurrence == 0 ? base : "\(base) #\(occurrence + 1)",
                state: entry["state"] as? String,
                readyState: intValue(entry["readyState"]),
                handshakeReady: entry["handshakeReady"] as? Bool,
                intent: entry["intent"] as? String,
                reconnectAttempts: intValue(entry["reconnectAttempts"]),
                lastInboundAgoMs: intValue(entry["lastInboundAgoMs"]),
                livenessTimeoutMs: intValue(entry["livenessTimeoutMs"]),
                diagnosticsError: entry["diagnosticsError"] as? String
            )
        }

        var phase: Phase?
        if let phaseDict = section("connectPhase"), let raw = phaseDict["phase"] as? String {
            phase = Phase(
                raw: raw,
                detail: phaseDict["detail"] as? String,
                elapsedMs: intValue(phaseDict["elapsedMs"])
            )
        }

        return ConnectionDiagnosticsReport(
            capturedAt: root["at"] as? String,
            build: root["build"] as? String,
            uptimeSec: intValue(root["uptimeSec"]),
            crashLive: describeCrash(crash?["live"]),
            crashPersisted: describeCrash(crash?["lastPersisted"]),
            remoteBridgeAvailable: bridge?["available"] as? Bool,
            machines: machines,
            pairingGroups: pairingGroups,
            totalPairings: pairings.count,
            transports: transports,
            phase: phase,
            targetMachineId: phase?.tabId.flatMap { tabToMachine[$0] },
            sectionErrors: sectionErrors,
            rawJSON: prettyPrinted(root) ?? json
        )
    }

    // MARK: Formatting helpers

    /// `Int`, `Double` and `NSNumber` all show up here depending on how the JS
    /// value round-tripped, so normalise rather than conditionally casting.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// Crash entries are free-form (string, object, or null) — render whatever
    /// arrived, but never surface JSON's `null` as if it were a crash.
    private static func describeCrash(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func prettyPrinted(_ root: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func durationText(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s" }
        let hours = minutes / 60
        return hours == 0 ? "\(minutes)m" : "\(hours)h \(minutes % 60)m"
    }
}

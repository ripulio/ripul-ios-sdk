import SwiftUI

// MARK: - Parsed Log

/// Structured view over a raw `ConsoleLogEntry.message`. Renderers match on this
/// shape rather than poking the raw string. A log is considered "typed" when
/// `tag` is set (`[host:ping] …`) and/or `jsonPayload` parses successfully.
@available(iOS 16.0, macOS 13.0, *)
struct ParsedConsoleLog {
    let tag: String?
    let summary: String
    let jsonPayload: [String: Any]?
    let jsonText: String?
    let rawMessage: String

    static func parse(_ message: String) -> ParsedConsoleLog {
        let lines = message.components(separatedBy: "\n")
        let firstLine = lines.first ?? message

        var tag: String? = nil
        var summary = firstLine
        if firstLine.hasPrefix("["),
           let endBracket = firstLine.firstIndex(of: "]"),
           endBracket > firstLine.startIndex {
            let afterOpen = firstLine.index(after: firstLine.startIndex)
            tag = String(firstLine[afterOpen..<endBracket])
            let afterClose = firstLine.index(after: endBracket)
            summary = String(firstLine[afterClose...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " —-:"))
        }

        let remaining = lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var json: [String: Any]? = nil
        var jsonText: String? = nil
        if let (dict, text) = tryParseJSONObject(remaining) {
            json = dict
            jsonText = text
        } else if tag == nil, let (dict, text) = tryParseJSONObject(message) {
            json = dict
            jsonText = text
            summary = ""
        }

        return ParsedConsoleLog(
            tag: tag,
            summary: summary,
            jsonPayload: json,
            jsonText: jsonText,
            rawMessage: message
        )
    }

    private static func tryParseJSONObject(_ text: String) -> ([String: Any], String)? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        return (dict, text)
    }
}

// MARK: - Renderer Registry

/// A typed renderer produces two views over the same parsed log:
///
/// * `renderSummary` is rendered inline in the log row alongside the
///   timestamp / level columns. It stays compact — a tag pill, a headline,
///   and at most one short subtitle — because it's constrained by the row's
///   message-column width.
/// * `renderDetail` is rendered in a master/detail panel that folds out
///   below the row when the user taps the disclosure. It is full-width and
///   may use multi-line key/value sections, code blocks, or anything else
///   that would be cramped in the row.
@available(iOS 16.0, macOS 13.0, *)
struct ConsoleLogRendererDescriptor {
    let canRender: (ParsedConsoleLog, String) -> Bool
    let renderSummary: (ParsedConsoleLog, String) -> AnyView
    let renderDetail: (ParsedConsoleLog, String) -> AnyView
    /// Tag a row must carry for this renderer's filter chip to match it.
    /// Adding a descriptor with a non-nil `filterTag` automatically grows
    /// the console viewer's filter bar — no UI changes needed. `nil` for
    /// generic catch-alls (e.g. JSON fallback) that match any payload and
    /// shouldn't claim a filter slot.
    let filterTag: String?
    /// Optional short label for the filter chip. Falls back to `filterTag`
    /// if nil — useful when the wire tag is verbose (`ripul/sync`) but a
    /// short label (`sync`) fits the chip better.
    let filterLabel: String?
}

@available(iOS 16.0, macOS 13.0, *)
enum ConsoleLogRendererRegistry {
    /// Order matters — first match wins. Specific tag-based renderers come
    /// before the generic JSON fallback.
    static let descriptors: [ConsoleLogRendererDescriptor] = [
        hostPingDescriptor,
        ripulSyncDescriptor,
        jsonFallbackDescriptor,
    ]

    static func renderer(
        for parsed: ParsedConsoleLog,
        level: String
    ) -> ConsoleLogRendererDescriptor? {
        descriptors.first { $0.canRender(parsed, level) }
    }

    /// Filter chips contributed by typed renderers — `(wireTag, displayLabel)`
    /// pairs in registry order. The console viewer appends these to its
    /// standard level chips so new renderers automatically appear.
    static var filterTags: [(tag: String, label: String)] {
        descriptors.compactMap { d in
            guard let tag = d.filterTag else { return nil }
            return (tag, d.filterLabel ?? tag)
        }
    }
}

// MARK: - host:ping Renderer

@available(iOS 16.0, macOS 13.0, *)
private let hostPingDescriptor = ConsoleLogRendererDescriptor(
    canRender: { parsed, _ in
        parsed.tag == "host:ping" && parsed.jsonPayload != nil
    },
    renderSummary: { parsed, level in
        AnyView(HostPingSummary(parsed: parsed, level: level))
    },
    renderDetail: { parsed, level in
        AnyView(HostPingDetail(parsed: parsed, level: level))
    },
    filterTag: "host:ping",
    filterLabel: nil
)

@available(iOS 16.0, macOS 13.0, *)
private struct HostPingSummary: View {
    let parsed: ParsedConsoleLog
    let level: String

    private var payload: [String: Any] { parsed.jsonPayload ?? [:] }
    private var displayName: String { payload["displayName"] as? String ?? "unknown machine" }

    private var headline: String {
        if parsed.summary.localizedCaseInsensitiveContains("timeout") { return "Timed out" }
        if parsed.summary.localizedCaseInsensitiveContains("send failed") { return "Send failed" }
        return parsed.summary.isEmpty ? "Error" : parsed.summary
    }

    private var headlineColor: Color { level == "ERROR" ? .red : .primary }

    var body: some View {
        HStack(spacing: 6) {
            TagPill(text: "host:ping", style: level == "ERROR" ? .destructive : .neutral)
            Text(headline)
                .foregroundStyle(headlineColor)
                .fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Text(displayName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct HostPingDetail: View {
    let parsed: ParsedConsoleLog
    let level: String

    private var payload: [String: Any] { parsed.jsonPayload ?? [:] }

    private static let keyOrder: [String] = [
        "displayName", "reason", "ageMs", "requestId", "roomId",
    ]

    private var pairs: [(String, String)] {
        return orderedPayloadPairs(payload, keyOrder: Self.keyOrder)
    }

    var body: some View {
        RendererDetailPanel {
            ForEach(pairs, id: \.0) { key, value in
                RendererDetailRow(label: key, value: value)
            }
        }
    }
}

// MARK: - ripul/sync Renderer

/// Catch-up / snapshot lifecycle events emitted by SessionChannelClient via
/// `logSyncEvent`. The summary stays one-line (pill + event verb + chat tail);
/// the detail panel breaks out the full JSON payload in a fixed, narrative
/// order so a glance answers "did the snapshot truncate, and where?".
@available(iOS 16.0, macOS 13.0, *)
private let ripulSyncDescriptor = ConsoleLogRendererDescriptor(
    canRender: { parsed, _ in
        parsed.tag == "ripul/sync" && parsed.jsonPayload != nil
    },
    renderSummary: { parsed, level in
        AnyView(RipulSyncSummary(parsed: parsed, level: level))
    },
    renderDetail: { parsed, level in
        AnyView(RipulSyncDetail(parsed: parsed, level: level))
    },
    filterTag: "ripul/sync",
    filterLabel: "sync"
)

@available(iOS 16.0, macOS 13.0, *)
private struct RipulSyncSummary: View {
    let parsed: ParsedConsoleLog
    let level: String

    private var payload: [String: Any] { parsed.jsonPayload ?? [:] }
    private var event: String { (payload["event"] as? String) ?? parsed.summary }
    private var chat: String { (payload["chat"] as? String) ?? "" }

    private var pillStyle: TagPill.Style {
        switch level {
        case "ERROR": return .destructive
        case "WARN":  return .info
        default:      return .neutral
        }
    }

    private var headlineColor: Color {
        switch level {
        case "ERROR": return .red
        case "WARN":  return .orange
        default:      return .primary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            TagPill(text: "sync", style: pillStyle)
            Text(event)
                .foregroundStyle(headlineColor)
                .fontWeight(.medium)
            if !chat.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text("chat=\(chat)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct RipulSyncDetail: View {
    let parsed: ParsedConsoleLog
    let level: String

    private var payload: [String: Any] { parsed.jsonPayload ?? [:] }

    /// Field order tuned for the catch-up narrative — read-path counts first
    /// (so a glance answers "did the snapshot truncate?"), then sequence info,
    /// then timing/reconnect bookkeeping.
    private static let keyOrder: [String] = [
        "event",
        "chat",
        "mode",
        "reason",
        "provider",
        "cliSessionId",
        "messages",
        "existing",
        "newMessages",
        "baselined",
        "appended",
        "actions",
        "totalCount",
        "totalVisibleCount",
        "filtered",
        "chunks",
        "firstChunkActions",
        "sinceSeq",
        "seq",
        "beforeTs",
        "limit",
        "tail",
        "bands",
        "expand",
        "subscribed",
        "snapshotReceived",
        "elapsedMs",
        "attempt",
        "maxAttempts",
        "reconnectAttempts",
        "delayMs",
        "timeoutMs",
        "was",
        "state",
        "code",
        "message",
    ]

    var body: some View {
        RendererDetailPanel {
            ForEach(orderedPayloadPairs(payload, keyOrder: Self.keyOrder), id: \.0) { key, value in
                RendererDetailRow(label: key, value: value)
            }
        }
    }
}

// MARK: - JSON Fallback Renderer

@available(iOS 16.0, macOS 13.0, *)
private let jsonFallbackDescriptor = ConsoleLogRendererDescriptor(
    canRender: { parsed, _ in parsed.jsonPayload != nil },
    renderSummary: { parsed, level in
        AnyView(JSONFallbackSummary(parsed: parsed, level: level))
    },
    renderDetail: { parsed, level in
        AnyView(JSONFallbackDetail(parsed: parsed, level: level))
    },
    filterTag: nil,
    filterLabel: nil
)

@available(iOS 16.0, macOS 13.0, *)
private struct JSONFallbackSummary: View {
    let parsed: ParsedConsoleLog
    let level: String

    private var summaryColor: Color {
        level == "ERROR" ? .red : .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            if let tag = parsed.tag {
                TagPill(text: tag, style: level == "ERROR" ? .destructive : .neutral)
            }
            if !parsed.summary.isEmpty {
                Text(parsed.summary)
                    .foregroundStyle(summaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if parsed.tag == nil {
                Text("{json}")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct JSONFallbackDetail: View {
    let parsed: ParsedConsoleLog
    let level: String

    private var pairs: [(String, String)] {
        guard let dict = parsed.jsonPayload else { return [] }
        return dict.sorted { $0.key < $1.key }.map { ($0.key, formatJSONValue($0.value)) }
    }

    var body: some View {
        RendererDetailPanel {
            ForEach(pairs, id: \.0) { key, value in
                RendererDetailRow(label: key, value: value)
            }
        }
    }
}

// MARK: - Building Blocks

@available(iOS 16.0, macOS 13.0, *)
struct TagPill: View {
    enum Style { case neutral, destructive, info }
    let text: String
    var style: Style = .neutral

    private var background: Color {
        switch style {
        case .neutral: return Color.secondary.opacity(0.15)
        case .destructive: return Color.red.opacity(0.15)
        case .info: return Color.blue.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch style {
        case .neutral: return .secondary
        case .destructive: return .red
        case .info: return .blue
        }
    }

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// Full-width detail panel container — used by every typed renderer's
/// `renderDetail`. Provides consistent padding, spacing, and a subtle
/// inset so it visually nests under its summary row.
@available(iOS 16.0, macOS 13.0, *)
struct RendererDetailPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

/// Single key/value row used inside `RendererDetailPanel`. The label column is wide
/// enough for the longest catch-up payload key (`totalVisibleCount`,
/// `reconnectAttempts`) without truncation; the value wraps to multiple lines
/// rather than truncating, since the detail panel is the master/detail "fold
/// out" and should never hide content.
@available(iOS 16.0, macOS 13.0, *)
struct RendererDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption2, design: .monospaced))
    }
}

// MARK: - Shared Helpers

/// Walks the payload in the renderer's preferred key order, then appends any
/// extra keys alphabetically so an unexpected field still surfaces.
@available(iOS 16.0, macOS 13.0, *)
func orderedPayloadPairs(
    _ payload: [String: Any],
    keyOrder: [String],
) -> [(String, String)] {
    var pairs: [(String, String)] = []
    var seen = Set<String>()
    for k in keyOrder {
        if seen.contains(k) { continue }
        if let v = payload[k], !(v is NSNull) {
            pairs.append((k, formatJSONValue(v)))
            seen.insert(k)
        }
    }
    for (k, v) in payload.sorted(by: { $0.key < $1.key }) {
        if seen.contains(k) { continue }
        if v is NSNull { continue }
        pairs.append((k, formatJSONValue(v)))
    }
    return pairs
}

@available(iOS 16.0, macOS 13.0, *)
func formatJSONValue(_ value: Any) -> String {
    if let s = value as? String { return s }
    if let b = value as? Bool { return b ? "true" : "false" }
    if let n = value as? NSNumber { return n.stringValue }
    if value is NSNull { return "null" }
    if let data = try? JSONSerialization.data(withJSONObject: value),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    return String(describing: value)
}

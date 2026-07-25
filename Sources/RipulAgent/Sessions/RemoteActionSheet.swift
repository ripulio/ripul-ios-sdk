import SwiftUI
import WebKit

/// Sheet for executing a remote action that requires parameter input,
/// or for showing the result of any remote action execution.
///
/// Ported verbatim from the native app (`Shared/RemoteActionSheet.swift`).
public struct RemoteActionSheet: View {
    let action: RemoteActionDescriptor
    var initialResult: [String: Any]? = nil
    let onExecute: ([String: Any]) async -> [String: Any]
    @Environment(\.dismiss) private var dismiss

    public init(
        action: RemoteActionDescriptor,
        initialResult: [String: Any]? = nil,
        onExecute: @escaping ([String: Any]) async -> [String: Any]
    ) {
        self.action = action
        self.initialResult = initialResult
        self.onExecute = onExecute
    }

    @State private var paramValues: [String: String] = [:]
    @State private var isExecuting = false
    @State private var result: [String: Any]?
    @State private var hasExecuted = false

    /// Properties from the inputSchema
    private var properties: [(key: String, schema: [String: Any])] {
        guard let props = action.inputSchema["properties"] as? [String: [String: Any]] else { return [] }
        return props.sorted(by: { $0.key < $1.key }).map { (key: $0.key, schema: $0.value) }
    }

    private var requiredKeys: Set<String> {
        Set((action.inputSchema["required"] as? [String]) ?? [])
    }

    private var hasParams: Bool {
        !properties.isEmpty
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Description
                    if !action.description.isEmpty {
                        Text(action.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Parameter form
                    if hasParams && !hasExecuted {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(properties, id: \.key) { key, schema in
                                paramField(key: key, schema: schema)
                            }
                        }
                    }

                    // Result display
                    if let result {
                        resultContent(result)
                    }

                    // Execute button
                    if !hasExecuted {
                        Button {
                            Task { await executeAction() }
                        } label: {
                            HStack {
                                if isExecuting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                                Text(isExecuting ? "Executing..." : "Execute")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .uiKitIdentifier("RemoteActionSheet.executeButton")
                        .buttonStyle(.borderedProminent)
                        .tint(action.destructive ? .red : .blue)
                        .disabled(isExecuting)
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .navigationTitle(action.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .uiKitIdentifier("RemoteActionSheet.closeButton")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear {
            if let initialResult {
                result = initialResult
                hasExecuted = true
            }
        }
    }

    // MARK: - Parameter Field

    @ViewBuilder
    private func paramField(key: String, schema: [String: Any]) -> some View {
        let label = key
        let description = schema["description"] as? String ?? ""
        let type = schema["type"] as? String ?? "string"
        let isRequired = requiredKeys.contains(key)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                if isRequired {
                    Text("*")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            switch type {
            case "boolean":
                Toggle(description, isOn: Binding(
                    get: { paramValues[key] == "true" },
                    set: { paramValues[key] = $0 ? "true" : "false" }
                ))
                .font(.caption)
            case "number":
                TextField(description.isEmpty ? label : description, text: Binding(
                    get: { paramValues[key] ?? "" },
                    set: { paramValues[key] = $0 }
                ))
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .textFieldStyle(.roundedBorder)
            default:
                TextField(description.isEmpty ? label : description, text: Binding(
                    get: { paramValues[key] ?? "" },
                    set: { paramValues[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Result Rendering (Priority Chain)

    /// Rendering priority:
    /// 1. result["html"] exists → Web view
    /// 2. result["outputSchema"] exists → Native schema-driven (per-result override)
    /// 3. action.outputSchema exists → Native schema-driven (descriptor-level)
    /// 4. Error result → Single error message
    /// 5. Single field → Single value text
    /// 6. Multiple fields → Auto key-value rows
    @ViewBuilder
    private func resultContent(_ result: [String: Any]) -> some View {
        let isError = (result["status"] as? String) == "error"

        // Status header
        HStack(spacing: 6) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(isError ? "Failed" : "Success")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            copyJSONButton(result)
        }

        if isError {
            // Priority 4: Error
            errorResultView(result)
        } else if let html = result["html"] as? String, !html.isEmpty {
            // Priority 1: HTML in result
            WebResultView(html: html)
                .frame(minHeight: 120, maxHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let resultSchema = OutputSchema.fromResult(result) {
            // Priority 2: Per-result output schema override
            schemaResultView(result, schema: resultSchema)
        } else if let descriptorSchema = action.outputSchema {
            // Priority 3: Descriptor-level output schema
            schemaResultView(result, schema: descriptorSchema)
        } else {
            // Priority 5/6: Auto fallback
            autoResultView(result)
        }
    }

    // MARK: - Error Result

    @ViewBuilder
    private func errorResultView(_ result: [String: Any]) -> some View {
        let errorMsg = result["error"] as? String ?? result["message"] as? String ?? "Unknown error"
        Text(errorMsg)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }

    // MARK: - Schema-Driven Result

    @ViewBuilder
    private func schemaResultView(_ result: [String: Any], schema: OutputSchema) -> some View {
        let displayFields = result.filter { $0.key != "status" && $0.key != "outputSchema" }

        switch schema.layout {
        case .raw:
            rawLayoutView(displayFields)
        case .list:
            listLayoutView(displayFields, schema: schema)
        case .card:
            cardLayoutView(displayFields, schema: schema)
        }
    }

    @ViewBuilder
    private func cardLayoutView(_ fields: [String: Any], schema: OutputSchema) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Render prominent fields first
            let prominentFields = schema.fields.filter { $0.style == .prominent }
            ForEach(prominentFields, id: \.key) { field in
                if let value = fields[field.key] {
                    prominentFieldView(field: field, value: value)
                }
            }

            // Render remaining fields
            let regularFields = schema.fields.filter { $0.style != .prominent }
            ForEach(regularFields, id: \.key) { field in
                if let value = fields[field.key] {
                    styledFieldRow(field: field, value: value)
                }
            }

            // Render any result keys not covered by the schema
            let schemaKeys = Set(schema.fields.map { $0.key })
            let extraKeys = fields.keys.filter { !schemaKeys.contains($0) }.sorted()
            ForEach(extraKeys, id: \.self) { key in
                defaultFieldRow(key: key, value: fields[key]!)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func listLayoutView(_ fields: [String: Any], schema: OutputSchema) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !schema.fields.isEmpty {
                ForEach(schema.fields, id: \.key) { field in
                    if let value = fields[field.key] {
                        styledFieldRow(field: field, value: value)
                        if field.key != schema.fields.last?.key {
                            Divider()
                        }
                    }
                }
            } else {
                // No field descriptors — render all keys as list items
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    defaultFieldRow(key: key, value: fields[key]!)
                    if key != fields.keys.sorted().last {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rawLayoutView(_ fields: [String: Any]) -> some View {
        let text = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        codeBlockView(text)
    }

    // MARK: - Styled Field Views

    @ViewBuilder
    private func prominentFieldView(field: OutputFieldDescriptor, value: Any) -> some View {
        HStack(spacing: 8) {
            if let icon = field.icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let label = field.label {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(value)")
                    .font(.title3)
                    .fontWeight(.bold)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func styledFieldRow(field: OutputFieldDescriptor, value: Any) -> some View {
        switch field.style {
        case .badge:
            badgeFieldView(field: field, value: value)
        case .codeBlock:
            VStack(alignment: .leading, spacing: 4) {
                if let label = field.label {
                    fieldLabel(label, icon: field.icon)
                }
                codeBlockView("\(value)")
            }
        case .timestamp:
            timestampFieldView(field: field, value: value)
        case .bytes:
            bytesFieldView(field: field, value: value)
        case .progressBar:
            progressBarFieldView(field: field, value: value)
        case .prominent:
            prominentFieldView(field: field, value: value)
        case .default:
            defaultStyledFieldRow(field: field, value: value)
        }
    }

    @ViewBuilder
    private func defaultStyledFieldRow(field: OutputFieldDescriptor, value: Any) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = field.icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 16)
            }
            Text(field.label ?? humanize(field.key))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text("\(value)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func badgeFieldView(field: OutputFieldDescriptor, value: Any) -> some View {
        HStack(spacing: 8) {
            if let icon = field.icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 16)
            }
            Text(field.label ?? humanize(field.key))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text("\(value)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
            Spacer()
        }
    }

    @ViewBuilder
    private func timestampFieldView(field: OutputFieldDescriptor, value: Any) -> some View {
        let relativeText = formatTimestamp(value)
        HStack(spacing: 8) {
            if let icon = field.icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 16)
            }
            Text(field.label ?? humanize(field.key))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(relativeText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func bytesFieldView(field: OutputFieldDescriptor, value: Any) -> some View {
        let formatted = formatBytes(value)
        HStack(spacing: 8) {
            if let icon = field.icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 16)
            }
            Text(field.label ?? humanize(field.key))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(formatted)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    /// Progress bar rendering.
    /// Value format: `{percent: Number (0-100), label?: String}` or a plain number 0-100.
    @ViewBuilder
    private func progressBarFieldView(field: OutputFieldDescriptor, value: Any) -> some View {
        let parsed = parseProgressValue(value)
        let percent = min(max(parsed.percent, 0), 100)
        let fraction = percent / 100.0

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon = field.icon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text(field.label ?? humanize(field.key))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if let label = parsed.label {
                    Text(label)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 8)

            Text("\(Int(percent))% in use")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func parseProgressValue(_ value: Any) -> (percent: Double, label: String?) {
        // Dict form: {percent: Number, label?: String}
        if let dict = value as? [String: Any] {
            let percent: Double
            if let n = dict["percent"] as? Double { percent = n }
            else if let n = dict["percent"] as? Int { percent = Double(n) }
            else { percent = 0 }
            let label = dict["label"] as? String
            return (percent: percent, label: label)
        }
        // Scalar form: plain number 0-100
        if let n = value as? Double { return (percent: n, label: nil) }
        if let n = value as? Int { return (percent: Double(n), label: nil) }
        return (percent: 0, label: nil)
    }

    // MARK: - Auto Fallback (no schema)

    @ViewBuilder
    private func autoResultView(_ result: [String: Any]) -> some View {
        let displayFields = result.filter { $0.key != "status" }

        if displayFields.count <= 1 {
            // Single value: show as text
            let msg = displayFields.values.first.map { "\($0)" } ?? "Done"
            Text(msg)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        } else {
            // Multiple fields: show as labeled rows
            VStack(alignment: .leading, spacing: 6) {
                ForEach(displayFields.keys.sorted(), id: \.self) { key in
                    defaultFieldRow(key: key, value: displayFields[key]!)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func defaultFieldRow(key: String, value: Any) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(humanize(key))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text("\(value)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Shared Widgets

    @ViewBuilder
    private func copyJSONButton(_ result: [String: Any]) -> some View {
        Button {
            let payload = result.filter { $0.key != "outputSchema" }
            let json = Self.serializeJSON(payload)
            #if os(iOS)
            UIPasteboard.general.string = json
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            #endif
        } label: {
            Label("Copy JSON", systemImage: "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private static func serializeJSON(_ value: [String: Any]) -> String {
        let sanitized = sanitizeForJSON(value)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                  withJSONObject: sanitized,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let str = String(data: data, encoding: .utf8)
        else {
            return "\(value)"
        }
        return str
    }

    /// JSONSerialization rejects non-JSON types (Date, URL, nil, etc.). Coerce them to strings.
    private static func sanitizeForJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitizeForJSON(v) }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { sanitizeForJSON($0) }
        }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n }
        if let b = value as? Bool { return b }
        return "\(value)"
    }

    @ViewBuilder
    private func codeBlockView(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = text
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .padding(.top, 4)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func fieldLabel(_ label: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting Helpers

    private func humanize(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Format a timestamp value to relative time string.
    /// Accepts: seconds since epoch (number) or ISO 8601 string.
    private func formatTimestamp(_ value: Any) -> String {
        var date: Date?
        if let epoch = value as? Double {
            date = Date(timeIntervalSince1970: epoch)
        } else if let epoch = value as? Int {
            date = Date(timeIntervalSince1970: Double(epoch))
        } else if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: str)
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime]
                date = formatter.date(from: str)
            }
        }

        guard let date else { return "\(value)" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Format a raw byte count to human-readable size.
    /// Accepts: number (raw byte count).
    private func formatBytes(_ value: Any) -> String {
        var bytes: Int64?
        if let n = value as? Int { bytes = Int64(n) }
        else if let n = value as? Int64 { bytes = n }
        else if let n = value as? Double { bytes = Int64(n) }
        else if let n = value as? UInt64 { bytes = Int64(n) }

        guard let bytes else { return "\(value)" }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Execution

    private func executeAction() async {
        isExecuting = true
        defer { isExecuting = false }

        // Build params dict, converting types as needed
        var params: [String: Any] = [:]
        for (key, schema) in properties {
            guard let value = paramValues[key], !value.isEmpty else { continue }
            let type = schema["type"] as? String ?? "string"
            switch type {
            case "number":
                params[key] = Double(value) ?? value
            case "boolean":
                params[key] = value == "true"
            default:
                params[key] = value
            }
        }

        result = await onExecute(params)
        hasExecuted = true
    }
}

// MARK: - WebResultView

/// Shared HTML wrapping logic for both platforms.
private enum WebResultHTML {
    static let maxContentSize = 256 * 1024  // 256 KB

    static func wrappedHTML(_ html: String) -> String {
        let safeHTML = html.count > maxContentSize
            ? "<pre style='color: #f88; padding: 16px;'>Content too large to display (\(html.count / 1024) KB). Limit: \(maxContentSize / 1024) KB.</pre>"
            : html

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="color-scheme" content="dark light">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                margin: 0; padding: 12px;
                font-size: 13px;
                color-scheme: dark light;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #e0e0e0; }
            }
            @media (prefers-color-scheme: light) {
                body { color: #1a1a1a; }
            }
            pre { white-space: pre-wrap; word-break: break-word; }
        </style>
        </head>
        <body>\(safeHTML)</body>
        </html>
        """
    }

    static func configureWebView() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // Disable JavaScript for security — result HTML is purely presentational
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs
        return config
    }
}

/// Navigation delegate that blocks all navigation except the initial HTML load.
class WebResultNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}

#if os(iOS)
/// Minimal WKWebView wrapper for rendering host-defined HTML results (iOS).
/// Security: JS disabled, navigation blocked, content size limited to 256 KB.
struct WebResultView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WebResultHTML.configureWebView())
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(WebResultHTML.wrappedHTML(html), baseURL: nil)
    }

    func makeCoordinator() -> WebResultNavigationDelegate { WebResultNavigationDelegate() }
}
#else
/// Minimal WKWebView wrapper for rendering host-defined HTML results (macOS).
/// Security: JS disabled, navigation blocked, content size limited to 256 KB.
struct WebResultView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WebResultHTML.configureWebView()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(WebResultHTML.wrappedHTML(html), baseURL: nil)
    }

    func makeCoordinator() -> WebResultNavigationDelegate { WebResultNavigationDelegate() }
}
#endif

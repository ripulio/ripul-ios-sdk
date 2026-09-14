import SwiftUI
import Combine

/// Read-only call data projected by the same web pipeline that owns the lozenge.
struct ToolCallDetail: Decodable, Identifiable, Equatable {
    let id: String
    let toolName: String
    let status: String
    let timestamp: Double
    let arguments: String
    let result: String?
    let error: String?
    let diagnostics: String
    let rendererName: String?
    let renderArguments: CmsJSON?
    let commandPresentation: ShellToolPresentation?

    var statusTitle: String {
        switch status {
        case "success", "complete", "completed": return "Completed"
        case "error", "failed": return "Failed"
        case "pending", "running", "streaming": return "Running"
        default: return status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    var resultText: String {
        result ?? (statusTitle == "Running" ? "Waiting for result…" : "No result was recorded.")
    }

    var recordedCommand: String? {
        let args = ToolValue.parse(arguments).objectValue ?? [:]
        return ["command", "cmd", "CommandLine"].compactMap { args[$0]?.displayString }.first
    }
}

/// Executable identity and readable source supplied by the shared web parser.
struct ShellToolPresentation: Decodable, Equatable {
    let label: String
    let symbol: String
    let color: String?
    let command: String
    let commandBreakLines: [Int]?
    let commandPipeLines: [Int]?
    let summary: String
    let source: String?
    let language: String?
}

struct ToolCallDetailsRequest: Decodable, Equatable {
    let requestId: String
    let title: String
    let calls: [ToolCallDetail]
    let initialCallId: String?

    var initialExpandedCallId: String? {
        calls.first(where: { $0.id == initialCallId })?.id ?? calls.last?.id
    }
}

/// A leaf store: streaming result updates redraw the sheet, not AgentView's WKWebView.
@MainActor
public final class ToolCallDetailsStore: ObservableObject {
    @Published private(set) var request: ToolCallDetailsRequest?
    @Published private(set) var expandedCallIds: Set<String> = []

    func setExpanded(_ expanded: Bool, callId: String) {
        guard request?.calls.contains(where: { $0.id == callId }) == true else { return }
        if expanded { expandedCallIds.insert(callId) }
        else { expandedCallIds.remove(callId) }
    }

    func receive(_ message: [String: Any], opening: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let next = try? JSONDecoder().decode(ToolCallDetailsRequest.self, from: data),
              !next.requestId.isEmpty, !next.calls.isEmpty,
              Set(next.calls.map(\.id)).count == next.calls.count else { return }
        // Late updates after dismissal must never reopen the sheet, and another
        // chat's old updates must never replace the currently inspected call.
        guard opening || request?.requestId == next.requestId else { return }
        if request?.requestId != next.requestId {
            expandedCallIds = [next.initialExpandedCallId!]
        } else {
            // Results and new calls preserve every disclosure choice, including
            // deliberately closing all calls. New iterations start collapsed.
            let retained = expandedCallIds.intersection(next.calls.map(\.id))
            if retained != expandedCallIds { expandedCallIds = retained }
        }
        if request != next { request = next }
    }

    @discardableResult
    func close(requestId: String? = nil) -> String? {
        guard let current = request, requestId == nil || requestId == current.requestId else { return nil }
        request = nil
        expandedCallIds = []
        return current.requestId
    }
}

struct ToolCallDetailsPresenter: ViewModifier {
    @ObservedObject var store: ToolCallDetailsStore
    let onDismiss: (String) -> Void

    private func close() {
        if let id = store.close() { onDismiss(id) }
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { store.request != nil }, set: { if !$0 { close() } })) {
            ToolCallDetailsSheet(store: store, onClose: close)
        }
    }
}

struct ToolCallDetailsSheet: View {
    @ObservedObject var store: ToolCallDetailsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
              ScrollView {
                if let request = store.request {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(request.calls.enumerated().reversed()), id: \.element.id) { index, call in
                            ToolCallDisclosure(call: call, number: index + 1, count: request.calls.count,
                                isExpanded: Binding(
                                    get: { store.expandedCallIds.contains(call.id) },
                                    set: { store.setExpanded($0, callId: call.id) }
                                ))
                                .id(call.id)
                                .transition(reduceMotion ? .identity : .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    // Animate membership, not streaming output. A fresh request
                    // starts a new stack so opening a sheet never replays arrivals.
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: request.calls.map(\.id))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(request.requestId)
                }
              }
              .task(id: store.request?.requestId) {
                  if let callId = store.request?.initialExpandedCallId {
                      proxy.scrollTo(callId, anchor: .top)
                  }
              }
            }
            #if os(iOS)
            .background(Color(.systemGroupedBackground))
            #else
            .background(Color(nsColor: .windowBackgroundColor))
            #endif
            .navigationTitle(store.request?.title ?? "Tool details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).accessibilityIdentifier("ToolCallDetails.done")
                }
            }
        }
        .accessibilityIdentifier("ToolCallDetails.sheet")
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 520, idealWidth: 720, minHeight: 420, idealHeight: 650)
        #endif
    }
}

private struct ToolCallDisclosure: View {
    let call: ToolCallDetail
    let number: Int
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        let summary = NativeToolSummary(call)
        DisclosureGroup(isExpanded: $isExpanded) {
            // Do not build renderers or highlight output for closed calls.
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    NativeToolCallRenderer(call: call, summaryTitle: call.commandPresentation == nil ? summary.title : summary.subtitle)
                    if let error = call.error { detailSection("Error", text: error) }
                    DisclosureGroup("Call information") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(call.toolName).font(.subheadline)
                            Text(call.id).font(.caption).foregroundStyle(.secondary)
                            if call.commandPresentation != nil, let command = call.recordedCommand {
                                NativeToolCodeBlock(text: command, syntax: .shell, identifier: "ToolCallDetails.invocation")
                            }
                            NativeToolCodeBlock(text: call.diagnostics, syntax: .json, identifier: "ToolCallDetails.diagnostics")
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Call \(number) of \(count)")
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                    if call.timestamp > 0 {
                        Text("·")
                        Text(Date(timeIntervalSince1970: call.timestamp / 1000), format: .dateTime.hour().minute())
                    }
                    Spacer(minLength: 4)
                    statusBadge
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: summary.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(call.commandPresentation?.color.map { Color(hex: $0) } ?? .secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .accessibilityIdentifier("ToolCallDetails.summary.\(call.id)")
                        if let subtitle = summary.subtitle {
                            Text(subtitle)
                                .font(.system(.caption, design: summary.isCode ? .monospaced : .default))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .accessibilityIdentifier("ToolCallDetails.subtitle.\(call.id)")
                        }
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(ToolCallPanelStyle(callId: call.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ToolCallDetails.call.\(call.id)")
    }

    private var statusBadge: some View {
        let failed = call.statusTitle == "Failed"
        let running = call.statusTitle == "Running"
        let color: Color = failed ? .red : running ? .orange : call.statusTitle == "Completed" ? .green : .secondary
        return Label(call.statusTitle, systemImage: failed ? "exclamationmark.circle.fill" : running ? "clock" : "checkmark.circle")
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.08), in: Capsule())
            .fixedSize()
            .accessibilityIdentifier("ToolCallDetails.status")
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ToolCallDetails.\(title.lowercased())")
        }
    }
}

/// Matches the Files screen's GlassSectionPanel: shared glass surface, 16-point
/// corners/insets and an animated leading chevron, with room for a call summary.
private struct ToolCallPanelStyle: DisclosureGroupStyle {
    let callId: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("ToolCallDetails.toggle.\(callId)")

            if configuration.isExpanded {
                Divider().padding(.horizontal, 16)
                configuration.content
                    .disclosureGroupStyle(.automatic)
                    .padding(16)
            }
        }
        .modifier(GlassPanelBackground())
    }
}

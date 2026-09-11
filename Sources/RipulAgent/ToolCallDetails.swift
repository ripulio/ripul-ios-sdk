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
}

struct ToolCallDetailsRequest: Decodable, Equatable {
    let requestId: String
    let title: String
    let calls: [ToolCallDetail]
}

/// A leaf store: streaming result updates redraw the sheet, not AgentView's WKWebView.
@MainActor
public final class ToolCallDetailsStore: ObservableObject {
    @Published private(set) var request: ToolCallDetailsRequest?
    @Published var selectedId: String = ""

    var selectedCall: ToolCallDetail? {
        request?.calls.first { $0.id == selectedId } ?? request?.calls.last
    }

    func receive(_ message: [String: Any], opening: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let next = try? JSONDecoder().decode(ToolCallDetailsRequest.self, from: data),
              !next.requestId.isEmpty, !next.calls.isEmpty,
              Set(next.calls.map(\.id)).count == next.calls.count else { return }
        // Late updates after dismissal must never reopen the sheet, and another
        // chat's old updates must never replace the currently inspected call.
        guard opening || request?.requestId == next.requestId else { return }
        if request?.requestId != next.requestId || !next.calls.contains(where: { $0.id == selectedId }) {
            selectedId = next.calls.last!.id
        }
        if request != next { request = next }
    }

    @discardableResult
    func close(requestId: String? = nil) -> String? {
        guard let current = request, requestId == nil || requestId == current.requestId else { return nil }
        request = nil
        selectedId = ""
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
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let request = store.request, let call = store.selectedCall {
                        if request.calls.count > 1 {
                            Picker("Call", selection: $store.selectedId) {
                                ForEach(Array(request.calls.enumerated()), id: \.element.id) { index, item in
                                    Text("Call \(index + 1) of \(request.calls.count) · \(item.statusTitle)").tag(item.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("ToolCallDetails.iteration")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(call.statusTitle)
                                .foregroundStyle(call.statusTitle == "Failed" ? Color.red : Color.secondary)
                                .accessibilityIdentifier("ToolCallDetails.status")
                            if call.timestamp > 0 {
                                Text(Date(timeIntervalSince1970: call.timestamp / 1000), format: .dateTime)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        NativeToolCallRenderer(call: call)
                            .id(call.id)
                        if let error = call.error { detailSection("Error", text: error) }
                        DisclosureGroup("Call information") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(call.toolName).font(.subheadline)
                                Text(call.id).font(.caption).foregroundStyle(.secondary)
                                NativeToolCodeBlock(text: call.diagnostics, syntax: .json, identifier: "ToolCallDetails.diagnostics")
                                    .id(call.id)
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

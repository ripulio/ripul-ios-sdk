import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One tool, in full: description, a native parameter list flattened from its
/// JSON Schema, and the raw schema. Presented as a sheet by the browser; usable
/// standalone anywhere a `RipulToolInventory.Tool` is at hand.
@available(iOS 15.0, macOS 13.0, *)
public struct RipulToolDetailView: View {
    public let tool: RipulToolInventory.Tool

    @Environment(\.dismiss) private var dismiss
    @State private var schemaExpanded = false
    @State private var copied = false

    public init(tool: RipulToolInventory.Tool) {
        self.tool = tool
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let why = absentExplanation {
                        Text(why)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !tool.description.isEmpty {
                        section("Description") {
                            Text(tool.description)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section(tool.parameters.isEmpty ? "Parameters — none" : "Parameters") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(tool.parameters) { param in
                                parameterRow(param)
                                if param.id != tool.parameters.last?.id { Divider() }
                            }
                        }
                    }
                    section("Schema") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button(schemaExpanded ? "Hide raw JSON" : "Show raw JSON") {
                                    withAnimation(.easeInOut(duration: 0.18)) { schemaExpanded.toggle() }
                                }
                                .font(.caption)
                                .uiKitIdentifier("ToolDetail.schema.toggle")
                                Spacer()
                                Button {
                                    copy(tool.schemaJSON)
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                }
                                .uiKitIdentifier("ToolDetail.schema.copy")
                            }
                            if schemaExpanded {
                                Text(tool.schemaJSON)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .uiKitIdentifier("ToolDetail")
    }

    /// Plain-language reason a catalog-only tool is not in this chat.
    private var absentExplanation: String? {
        switch tool.absentReason {
        case "web-agent-only":
            return "Defined in the catalog for the embedded web agent, but not opted in for CLI sessions. No switch will bring it into this chat; it needs availableInContexts: cli on its definition."
        case "abstract":
            return "Prompt-scoped: only meaningful inside a prompt tool's workflow, never offered directly."
        case "no-handler":
            return "The catalog defines it, but this bundle has no handler for it, so it cannot run here."
        case .some:
            return "Not available to this chat."
        case nil:
            return nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    badge(tool.originLabel)
                    if let reason = tool.absentReasonLabel {
                        badge(reason)
                    } else {
                        badge(tool.visibleNow ? "in the model's list now" : "not in the list now")
                    }
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .uiKitIdentifier("ToolDetail.done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func parameterRow(_ param: RipulToolInventory.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(param.name).font(.callout.monospaced())
                Text(param.type).font(.caption).foregroundStyle(.secondary)
                if param.required {
                    Text("required")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            if !param.description.isEmpty {
                Text(param.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !param.enumValues.isEmpty {
                Text(param.enumValues.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .uiKitIdentifier("ToolDetail.parameter")
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

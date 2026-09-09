import SwiftUI

@available(iOS 16.0, macOS 14.0, *)
struct ComposerContextButton: View {
    @ObservedObject var store: RipulComposerContextStore
    let session: String?
    let options: [RipulComposerContext]
    let size: CGFloat
    @State private var preview: RipulContextAttachment?
    @State private var error: String?
    @State private var loading = false
    @State private var captureTask: Task<Void, Never>?

    var body: some View {
        Menu {
            Section("App context") {
                ForEach(options.filter { $0.kind != .instruction }) { option in
                    Button { capture(option) } label: { Label(option.title, systemImage: option.systemImage) }
                }
            }
            if options.contains(where: { $0.kind == .instruction }) {
                Section("Shortcuts") {
                    ForEach(options.filter { $0.kind == .instruction }) { option in
                        Button { capture(option) } label: { Label(option.title, systemImage: option.systemImage) }
                    }
                }
            }
        } label: {
            Image(systemName: loading ? "hourglass" : "text.badge.plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(loading || options.isEmpty || session == nil)
        .accessibilityLabel("Add context")
        .accessibilityIdentifier("NativeChatInput.context")
        .help("Choose context to attach to your message")
        .sheet(item: $preview) { item in
            ComposerContextPreview(item: item) { store.attach($0, to: session) }
        }
        .alert("Context unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onChange(of: session) { _ in captureTask?.cancel(); loading = false; preview = nil; error = nil }
        .onDisappear { captureTask?.cancel() }
    }

    private func capture(_ option: RipulComposerContext) {
        loading = true
        captureTask = Task { @MainActor in
            do {
                let content = try await option.resolve()
                guard !Task.isCancelled else { return }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    error = "This context has no content yet."; loading = false; return
                }
                preview = RipulContextAttachment(option: option, content: content)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct ComposerContextChips: View {
    @ObservedObject var store: RipulComposerContextStore
    let session: String?
    @State private var preview: RipulContextAttachment?
    var body: some View {
        let items = store.attachments(for: session)
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 4) {
                            Button { preview = item } label: {
                                Label(item.title, systemImage: item.isInstruction ? "text.badge.checkmark" : "rectangle.inset.filled")
                                    .lineLimit(1)
                                if item.duration == .conversation { Image(systemName: "repeat") }
                            }
                            .accessibilityLabel("Preview \(item.title), \(item.duration.rawValue)")
                            Button { store.remove(item.id, from: session) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Remove \(item.title)")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.quaternary, in: Capsule())
                    }
                }.padding(.horizontal, 8).padding(.top, 6)
            }
            .sheet(item: $preview) { item in ComposerContextPreview(item: item) { store.attach($0, to: session) } }
            .onChange(of: session) { _ in preview = nil }
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct ComposerContextPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: RipulContextAttachment
    let attach: (RipulContextAttachment) -> Void
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review what will be attached. Nothing is sent until you send a message.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if item.isInstruction {
                    Picker("Include with", selection: $item.duration) {
                        ForEach(RipulContextAttachment.Duration.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } else {
                    Label("Snapshot for the next message", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(item.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle(item.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Attach") { attach(item); dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("ComposerContext.attach")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 360, idealHeight: 500)
        #endif
    }
}

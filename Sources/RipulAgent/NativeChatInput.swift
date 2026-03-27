import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if canImport(PhotosUI)
import PhotosUI
#endif

// MARK: - Cross-platform Image Type

#if os(iOS)
public typealias PlatformImage = UIImage
#elseif os(macOS)
public typealias PlatformImage = NSImage
#endif

// MARK: - Image Attachment Model (cross-platform)

/// Model for a native image attachment with a platform-native thumbnail for display.
public struct NativeImageAttachment: Identifiable {
    public let id: String
    public let mediaType: String
    public let data: String // base64
    public let thumbnail: PlatformImage

    public init(id: String, mediaType: String, data: String, thumbnail: PlatformImage) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.thumbnail = thumbnail
    }

    public func toDictionary() -> [String: String] {
        ["id": id, "mediaType": mediaType, "data": data]
    }
}

// MARK: - Preference Keys

private struct FileSuggestionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - File Suggestion Model

/// A file suggestion returned from the remote host for @files autocomplete.
public struct FileSuggestion: Identifiable {
    public let id: String
    public let path: String
    public let isDirectory: Bool

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, isDirectory: Bool) {
        self.id = path
        self.path = path
        self.isDirectory = isDirectory
    }
}

// MARK: - Cross-platform Chat Input

/// A floating chat input that uses Liquid Glass on iOS 26+ and ultraThinMaterial elsewhere.
/// Includes image attachments and photos picker on both platforms.
/// Camera is iOS-only.
#if os(iOS)
@available(iOS 16.0, *)
public struct NativeChatInput: View {
    @Binding var text: String
    @Binding var imageAttachments: [NativeImageAttachment]
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isAgentRunning: Bool
    let isAgentPaused: Bool
    let onSubmit: () -> Void
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    var chatInputLayout: String?
    /// Optional callback to query remote host for file suggestions.
    /// When provided, typing `@` followed by text triggers file autocomplete.
    var onQueryFiles: ((String) async -> [FileSuggestion])?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var textHeight: CGFloat = 36
    @State private var fileSuggestions: [FileSuggestion] = []
    @State private var showFileSuggestions = false
    @State private var fileQueryTask: Task<Void, Never>?
    @State private var fileSuggestionsHeight: CGFloat = 0
    /// The character index where the `@` trigger was typed
    @State private var atTriggerIndex: String.Index?

    private var isTwoRow: Bool { chatInputLayout == "twoRow" }
    private var resolvedChatInputGlassStyle: String { chatInputGlassStyle ?? "clear" }

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        isAgentRunning: Bool = false,
        isAgentPaused: Bool = false,
        onSubmit: @escaping () -> Void,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil,
        chatInputLayout: String? = nil,
        onQueryFiles: ((String) async -> [FileSuggestion])? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
        self.chatInputLayout = chatInputLayout
        self.onQueryFiles = onQueryFiles
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    public var body: some View {
        VStack(spacing: 4) {
            if showFileSuggestions && !fileSuggestions.isEmpty {
                fileSuggestionsOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Group {
                if isTwoRow {
                    twoRowBody
                } else {
                    singleRowBody
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: textHeight)
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isAgentRunning)
        .animation(.easeInOut(duration: 0.2), value: isTwoRow)
        .animation(.easeInOut(duration: 0.15), value: showFileSuggestions)
        .onChange(of: text) { newValue in
            if newValue.isEmpty {
                textHeight = 36 // minHeight — snap immediately when text is cleared
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { uiImage in
                if let jpeg = uiImage.jpegData(compressionQuality: 0.8) {
                    let base64 = jpeg.base64EncodedString()
                    let id = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<100000))"
                    imageAttachments.append(NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: uiImage))
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - File Suggestions

    /// Detect `@` followed by typing and trigger file query
    private func handleAtDetection(_ value: String) {
        guard onQueryFiles != nil else {
            NSLog("[NativeChatInput] @files: onQueryFiles callback not set")
            return
        }

        // Find the last `@` in the text
        guard let atRange = value.range(of: "@", options: .backwards) else {
            dismissFileSuggestions()
            return
        }

        // Check that @ is at start of text or preceded by a space
        if atRange.lowerBound != value.startIndex {
            let charBefore = value[value.index(before: atRange.lowerBound)]
            if !charBefore.isWhitespace {
                dismissFileSuggestions()
                return
            }
        }

        let afterAt = String(value[atRange.upperBound...])

        // If there's a space after the query portion, the mention is "closed" — dismiss
        if afterAt.contains(" ") {
            dismissFileSuggestions()
            return
        }

        // Need at least 1 char after @ to search
        guard !afterAt.isEmpty else {
            dismissFileSuggestions()
            return
        }

        atTriggerIndex = atRange.lowerBound

        // Debounced query
        NSLog("[NativeChatInput] @files: querying for '%@'", afterAt)
        fileQueryTask?.cancel()
        fileQueryTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            guard !Task.isCancelled else { return }
            if let queryFiles = onQueryFiles {
                let results = await queryFiles(afterAt)
                NSLog("[NativeChatInput] @files: got %d results for '%@'", results.count, afterAt)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    fileSuggestions = results
                    showFileSuggestions = !results.isEmpty
                }
            }
        }
    }

    private func dismissFileSuggestions() {
        showFileSuggestions = false
        fileSuggestions = []
        atTriggerIndex = nil
        fileQueryTask?.cancel()
    }

    private func selectFileSuggestion(_ suggestion: FileSuggestion) {
        // Replace the @query with @path/to/file
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + suggestion.path + " "
        } else {
            text += suggestion.path + " "
        }
        dismissFileSuggestions()
    }

    private var fileSuggestionsOverlay: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(fileSuggestions) { suggestion in
                        Button {
                            selectFileSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.isDirectory ? "folder.fill" : "doc.text.fill")
                                    .foregroundStyle(suggestion.isDirectory ? .blue : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.fileName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if suggestion.path != suggestion.fileName {
                                        Text(suggestion.path)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != fileSuggestions.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    // MARK: - Single Row Layout (default)

    private var singleRowBody: some View {
        ChatInputGlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                plusMenuButton

                // Group adjacent glass surfaces so they share the same sampling region.
                VStack(spacing: 0) {
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    HStack(spacing: 4) {
                        textInputView
                        actionButton
                    }
                }
                .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))

                historyMenuButton
            }
        }
    }

    // MARK: - Two Row Layout (buttons below text area)

    private var twoRowBody: some View {
        ChatInputGlassGroup {
            VStack(spacing: 6) {
                // Full-width text area
                VStack(spacing: 0) {
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    textInputView
                        .padding(.trailing, 8)
                }

                // Buttons row below (inside the shared glass bounding box)
                HStack(spacing: 8) {
                    plusMenuButton
                    historyMenuButton
                    Spacer()
                    twoRowActionButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
        }
    }

    // MARK: - Shared Subviews

    private var plusMenuButton: some View {
        Menu {
            Button {
                showCamera = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photos", systemImage: "photo")
            }
            if onQuickCommands != nil {
                Button {
                    dismissKeyboard()
                    onQuickCommands?()
                } label: {
                    Label("Quick Commands", systemImage: "bolt.fill")
                }
            }
            Button {
                dismissKeyboard()
                onNewChat?()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
        }
    }

    private var textInputView: some View {
        NoAutofillTextView(
            text: $text,
            height: $textHeight,
            placeholder: "Message...",
            onSubmit: {
                dismissKeyboard()
                onSubmit()
            },
            onTextChange: { newText in
                if newText.isEmpty {
                    dismissFileSuggestions()
                } else {
                    handleAtDetection(newText)
                }
            }
        )
        .frame(maxWidth: .infinity, minHeight: textHeight, maxHeight: textHeight, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            Button {
                dismissKeyboard()
                onPause?()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: "clear"))
            }
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 4)
        } else if isAgentPaused && isAgentRunning {
            Button {
                dismissKeyboard()
                onSubmit()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: "clear"))
            }
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 4)
        } else if isAgentPaused || hasContent {
            Button {
                dismissKeyboard()
                onSubmit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: "clear"))
            }
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private var twoRowActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            Button {
                dismissKeyboard()
                onPause?()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: nil))
            }
            .transition(.scale.combined(with: .opacity))
        } else if isAgentPaused && isAgentRunning {
            Button {
                dismissKeyboard()
                onSubmit()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: nil))
            }
            .transition(.scale.combined(with: .opacity))
        } else if isAgentPaused || hasContent {
            Button {
                dismissKeyboard()
                onSubmit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: nil))
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var historyMenuButton: some View {
        if let history = messageHistory, !history.recentMessages.isEmpty {
            Menu {
                ForEach(history.recentMessages.prefix(15), id: \.self) { msg in
                    Button {
                        text = msg
                    } label: {
                        Text(msg.prefix(80) + (msg.count > 80 ? "..." : ""))
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
            }
        }
    }

    private var imageThumbsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: attachment.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            imageAttachments.removeAll { $0.id == attachment.id }
                            selectedPhotos = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .gray)
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

#elseif os(macOS)

@available(macOS 14.0, *)
public struct NativeChatInput: View {
    @Binding var text: String
    @Binding var imageAttachments: [NativeImageAttachment]
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isAgentRunning: Bool
    let isAgentPaused: Bool
    let onSubmit: () -> Void
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    var chatInputLayout: String?
    /// Optional callback to query remote host for file suggestions.
    /// When provided, typing `@` followed by text triggers file autocomplete.
    var onQueryFiles: ((String) async -> [FileSuggestion])?
    @State private var showPhotoPicker = false
    @FocusState private var isFocused: Bool
    @State private var fileSuggestions: [FileSuggestion] = []
    @State private var showFileSuggestions = false
    @State private var fileQueryTask: Task<Void, Never>?
    /// The character index where the `@` trigger was typed
    @State private var atTriggerIndex: String.Index?

    private var isTwoRow: Bool { chatInputLayout == "twoRow" }
    private var resolvedChatInputGlassStyle: String { chatInputGlassStyle ?? "clear" }

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        isAgentRunning: Bool = false,
        isAgentPaused: Bool = false,
        onSubmit: @escaping () -> Void,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil,
        chatInputLayout: String? = nil,
        onQueryFiles: ((String) async -> [FileSuggestion])? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
        self.chatInputLayout = chatInputLayout
        self.onQueryFiles = onQueryFiles
    }

    // MARK: - File Suggestions

    /// Detect `@` followed by typing and trigger file query
    private func handleAtDetection(_ value: String) {
        guard onQueryFiles != nil else { return }

        guard let atRange = value.range(of: "@", options: .backwards) else {
            dismissFileSuggestions()
            return
        }

        if atRange.lowerBound != value.startIndex {
            let charBefore = value[value.index(before: atRange.lowerBound)]
            if !charBefore.isWhitespace {
                dismissFileSuggestions()
                return
            }
        }

        let afterAt = String(value[atRange.upperBound...])

        if afterAt.contains(" ") {
            dismissFileSuggestions()
            return
        }

        guard !afterAt.isEmpty else {
            dismissFileSuggestions()
            return
        }

        atTriggerIndex = atRange.lowerBound

        NSLog("[NativeChatInput] @files: querying for '%@'", afterAt)
        fileQueryTask?.cancel()
        fileQueryTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            guard !Task.isCancelled else { return }
            if let queryFiles = onQueryFiles {
                let results = await queryFiles(afterAt)
                NSLog("[NativeChatInput] @files: got %d results for '%@'", results.count, afterAt)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    fileSuggestions = results
                    showFileSuggestions = !results.isEmpty
                }
            }
        }
    }

    private func dismissFileSuggestions() {
        showFileSuggestions = false
        fileSuggestions = []
        atTriggerIndex = nil
        fileQueryTask?.cancel()
    }

    private func selectFileSuggestion(_ suggestion: FileSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + suggestion.path + " "
        } else {
            text += suggestion.path + " "
        }
        dismissFileSuggestions()
    }

    private var fileSuggestionsOverlay: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(fileSuggestions) { suggestion in
                        Button {
                            selectFileSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.isDirectory ? "folder.fill" : "doc.text.fill")
                                    .foregroundStyle(suggestion.isDirectory ? .blue : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.fileName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if suggestion.path != suggestion.fileName {
                                        Text(suggestion.path)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != fileSuggestions.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    public var body: some View {
        Group {
            if isTwoRow {
                twoRowBody
            } else {
                singleRowBody
            }
        }
        .overlay(alignment: .top) {
            if showFileSuggestions {
                fileSuggestionsOverlay
                    .offset(y: -8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isAgentRunning)
        .animation(.easeInOut(duration: 0.2), value: isTwoRow)
        .animation(.easeInOut(duration: 0.2), value: showFileSuggestions)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.escape) {
            if isAgentRunning && !isAgentPaused {
                onPause?()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if let history = messageHistory,
               let previous = history.navigateUp(currentText: text) {
                text = previous
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if let history = messageHistory,
               let next = history.navigateDown() {
                text = next
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Single Row Layout (default)

    private var singleRowBody: some View {
        ChatInputGlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                plusMenuButton

                VStack(spacing: 0) {
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    HStack(spacing: 4) {
                        textInputView
                        actionButton
                    }
                }
                .frame(minHeight: 40)
                .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))

                historyMenuButton
            }
        }
    }

    // MARK: - Two Row Layout (buttons below text area)

    private var twoRowBody: some View {
        ChatInputGlassGroup {
            VStack(spacing: 6) {
                VStack(spacing: 0) {
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    textInputView
                        .padding(.trailing, 8)
                }
                .frame(minHeight: 40)

                // Buttons row below (inside the shared glass bounding box)
                HStack(spacing: 8) {
                    plusMenuButton
                    historyMenuButton
                    Spacer()
                    twoRowActionButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
        }
    }

    // MARK: - Shared Subviews

    private var plusMenuButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photos", systemImage: "photo")
            }
            if onQuickCommands != nil {
                Button {
                    onQuickCommands?()
                } label: {
                    Label("Quick Commands", systemImage: "bolt.fill")
                }
            }
            Button {
                onNewChat?()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 40, height: 40)
        .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
    }

    private var textInputView: some View {
        TextField("Message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.leading, 12)
            .padding(.vertical, 8)
            .onSubmit {
                onSubmit()
            }
            .onChange(of: text) { newValue in
                handleAtDetection(newValue)
            }
    }

    @ViewBuilder
    private var actionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            Button {
                onPause?()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 28)
                    .background(Color.orange, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 6)
        } else if isAgentPaused {
            Button {
                onSubmit()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 28)
                    .background(Color.green, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 6)
        } else if hasContent {
            Button {
                onSubmit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 28)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private var twoRowActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            Button {
                onPause?()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: nil))
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        } else if isAgentPaused {
            Button {
                onSubmit()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: nil))
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        } else if hasContent {
            Button {
                onSubmit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: nil))
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var historyMenuButton: some View {
        if let history = messageHistory, !history.recentMessages.isEmpty {
            Menu {
                ForEach(history.recentMessages.prefix(15), id: \.self) { msg in
                    Button {
                        text = msg
                    } label: {
                        Text(msg.prefix(80) + (msg.count > 80 ? "..." : ""))
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40, height: 40)
            .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
        }
    }

    private var imageThumbsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: attachment.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            imageAttachments.removeAll { $0.id == attachment.id }
                            selectedPhotos = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .gray)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

#endif

// MARK: - Glass Background (cross-platform)

@available(iOS 15.0, macOS 14.0, *)
public struct GlassChatInputBackground: ViewModifier {
    public var glassStyle: String? // "regular", "clear", or "identity"

    public init(glassStyle: String? = nil) {
        self.glassStyle = glassStyle
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glassStyle == "identity" {
                content
            } else {
                let style: Glass = glassStyle == "regular" ? .regular : .clear
                content
                    .background(.clear)
                    .glassEffect(style, in: .rect(cornerRadius: 22))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
        #else
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        #endif
    }
}

@available(iOS 15.0, macOS 14.0, *)
private struct ChatInputGlassGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
        #endif
    }
}

// MARK: - iOS-only: UIKit Text Input & Camera

#if os(iOS)
/// UITextView subclass that suppresses the iOS autofill toolbar above the keyboard.
class ChatTextView: UITextView {
    override var textContentType: UITextContentType! {
        get { nil }
        set { }
    }

    // Replace the system autofill toolbar with an invisible empty view
    private let _emptyAccessory: UIView = {
        let v = UIView(frame: .zero)
        v.isHidden = true
        return v
    }()

    override var inputAccessoryView: UIView? {
        get { _emptyAccessory }
        set { }
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        if #available(iOS 17.0, *) {
            builder.remove(menu: .autoFill)
        }
        super.buildMenu(with: builder)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let name = NSStringFromSelector(action)
        if name.lowercased().contains("autofill") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// UITextView wrapper that completely disables autofill suggestions.
@available(iOS 15.0, *)
struct NoAutofillTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var onTextChange: ((String) -> Void)?

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ChatTextView {
        let textView = ChatTextView()
        textView.delegate = context.coordinator
        let bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        textView.font = .systemFont(ofSize: bodySize + 1, weight: .semibold)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = true

        // Let Apple's vibrancy handle text color adaptation
        textView.textColor = .label

        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .yes
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []

        // Placeholder
        let label = UILabel()
        label.text = placeholder
        label.font = textView.font
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8)
        ])
        context.coordinator.placeholderLabel = label

        return textView
    }

    func updateUIView(_ textView: ChatTextView, context: Context) {

        if textView.text != text {
            textView.text = text
            context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
            // Invalidate intrinsic size so contentSize reflects the new text
            // before we read it. Without this, clearing the text leaves the
            // old (multi-line) contentSize until the next layout pass.
            textView.invalidateIntrinsicContentSize()
            textView.layoutIfNeeded()
            context.coordinator.recalcHeight(textView)
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoAutofillTextView
        var placeholderLabel: UILabel?

        init(_ parent: NoAutofillTextView) {
            self.parent = parent
        }

        func recalcHeight(_ textView: UITextView) {
            // When empty, contentSize can lag behind — snap to minimum
            let target = textView.text.isEmpty
                ? parent.minHeight
                : min(max(textView.contentSize.height, parent.minHeight), parent.maxHeight)
            if target != parent.height {
                DispatchQueue.main.async {
                    self.parent.height = target
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            recalcHeight(textView)
            parent.onTextChange?(textView.text)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

/// Wraps UIImagePickerController for camera capture.
@available(iOS 15.0, *)
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif // os(iOS)

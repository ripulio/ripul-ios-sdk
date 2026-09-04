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

/// A UI element suggestion from the current page's data-ui attributes.
public struct ElementSuggestion: Identifiable {
    public let id: String
    public let dataUi: String

    public var componentName: String {
        dataUi.split(separator: ".").first.map(String.init) ?? dataUi
    }

    public init(dataUi: String) {
        self.id = dataUi
        self.dataUi = dataUi
    }
}

/// A participant suggestion for @-mention routing in multi-participant chats.
/// Maps to a model id (agent) or, eventually, a human client id.
public struct ParticipantSuggestion: Identifiable {
    public let id: String       // ParticipantId — model id today, client id in future
    public let name: String     // Display name (e.g. "Claude")
    public let group: String?   // Provider / category for grouping (e.g. "Anthropic")

    public init(id: String, name: String, group: String? = nil) {
        self.id = id
        self.name = name
        self.group = group
    }
}

/// A branch suggestion for the @ picker — a git branch of the chat's repo.
/// `token` is the serialised `[context: …]` chip text; the composer displays it
/// as a readable alias (see `ContextMentionAliasing`) and swaps the token back
/// in at submit, where the web path resolves it to live branch facts (sha,
/// upstream, ahead/behind, checked-out state).
public struct BranchSuggestion: Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let remote: Bool
    public let token: String

    public init(id: String, name: String, description: String? = nil, remote: Bool = false, token: String) {
        self.id = id
        self.name = name
        self.description = description
        self.remote = remote
        self.token = token
    }
}

/// Context mentions serialise to `[context: provider.id/<ref> | Label]`, where
/// the ref is a base64url payload that routinely runs past 150 characters. The
/// web composer never shows it — Tiptap renders the mention as a chip node and
/// only serialises the token on the way out. A UITextView/TextField has no chip,
/// so the native composer keeps the readable half (`@origin/main`) in the field
/// and swaps the token back in at submit. The string that reaches the web send
/// path is identical either way.
enum ContextMentionAliasing {
    /// Mirrors CONTEXT_TOKEN_RE in
    /// chrome-extension/src/context-providers/resolveContextRefs.ts.
    private static let tokenPattern = try? NSRegularExpression(
        pattern: #"\[context:\s*([A-Za-z0-9_.]+)/([A-Za-z0-9_-]+)(?:\s*\|\s*([^\]]*?))?\s*\]"#
    )

    /// Cheap pre-check so the common keystroke path never touches the regex.
    private static let marker = "[context:"

    /// The composer-visible form of a mention.
    static func alias(for label: String) -> String { "@" + label }

    /// Replace every labelled token in `text` with its alias, recording the
    /// mapping so `expand` can reverse it. Covers tokens that arrive already
    /// serialised — history recall, a restored draft, a paste — not just picks.
    /// Unlabelled tokens are left alone: there is nothing readable to show.
    static func collapse(_ text: String, into aliases: inout [String: String]) -> String {
        guard let tokenPattern, text.contains(marker) else { return text }
        let ns = text as NSString
        let matches = tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        // Back to front, so an earlier match's range stays valid as we splice.
        for match in matches.reversed() {
            let labelRange = match.range(at: 3)
            guard labelRange.location != NSNotFound else { continue }
            let label = ns.substring(with: labelRange).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            let aliasText = alias(for: label)
            aliases[aliasText] = ns.substring(with: match.range)
            out.replaceCharacters(in: match.range, with: aliasText)
        }
        return out as String
    }

    /// Swap each recorded alias back to its token. An alias the user has edited
    /// away simply doesn't match and the mention drops — the same outcome as
    /// deleting the chip on web.
    static func expand(_ text: String, using aliases: [String: String]) -> String {
        guard !aliases.isEmpty else { return text }
        var out = text
        // Longest first, so a label that prefixes another can't claim its text.
        for aliasText in aliases.keys.sorted(by: { $0.count > $1.count }) {
            guard let token = aliases[aliasText] else { continue }
            out = out.replacingOccurrences(of: aliasText, with: token)
        }
        return out
    }
}

/// A toggleable class of @ suggestions. Keys match the web composer's
/// atMenuClassToggles so a user's preference has the same shape on both
/// surfaces (values do not sync across devices; absent = on, as on web).
private struct AtClassToggleSpec: Identifiable {
    let key: String
    let label: String
    let icon: String
    var id: String { key }

    static let all: [AtClassToggleSpec] = [
        AtClassToggleSpec(key: "people", label: "People", icon: "person.fill"),
        AtClassToggleSpec(key: "repo", label: "Branches", icon: "arrow.triangle.branch"),
        AtClassToggleSpec(key: "files", label: "Files", icon: "doc.text.fill"),
    ]
}

private enum AtClassToggles {
    static let defaultsKey = "atMenuClassToggles"

    static func isHidden(_ key: String) -> Bool {
        UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? Bool == false
    }

    static func setHidden(_ key: String, _ hidden: Bool) {
        var dict = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        dict[key] = !hidden
        UserDefaults.standard.set(dict, forKey: defaultsKey)
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
    /// Send a human note (not sent to agent, for human-to-human communication).
    var onSubmitNote: (() -> Void)?
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    let onAddTodoItem: (() -> Void)?
    /// Fetches the user's todo items (with current-chat id for grouping) when
    /// the "Pick to do" menu entry is tapped. A selected todo's text is appended
    /// to this view's own `$text` binding — the native composer is the source
    /// of truth, not the hidden web composer.
    let onFetchTodoItems: (() async -> RipulTodoItemsResult)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    var chatInputLayout: String?
    /// Toggle between plan (read-only) and edit (default) mode for CLI sessions.
    @Binding var planMode: Bool
    /// Whether to show the plan/edit mode toggle (e.g., only in raw CLI sessions).
    var showPlanModeToggle: Bool
    /// Optional callback to query remote host for file suggestions.
    /// When provided, typing `@` followed by text triggers file autocomplete.
    var onQueryFiles: ((String) async -> [FileSuggestion])?
    /// Optional callback to fetch UI element suggestions from the current page.
    var onQueryElements: (() async -> [ElementSuggestion])?
    /// Optional callback to fetch chat participant suggestions (agents + humans).
    /// When provided, the `@` category overlay shows a "People" row that lists them.
    var onQueryParticipants: (() async -> [ParticipantSuggestion])?
    /// Optional callback to fetch repo branch suggestions (the chat's repo).
    /// When provided, the `@` overlay shows a "Branches" section; picking one
    /// inserts its `[context: …]` token, resolved to live branch facts at send.
    var onQueryBranches: ((String) async -> [BranchSuggestion])?
    /// Structured participant IDs picked since the last send. Cleared on submit
    /// by the parent so a new turn starts empty. Drives `addressedTo` routing.
    @Binding var addressedParticipants: [String]
    var onFocusChanged: ((Bool) -> Void)?
    /// Hidden debug shortcut: long-press on the "+" button.
    var onPlusLongPress: (() -> Void)?
    /// Fetches slash commands when the user types "/" as the first character.
    /// When provided (with onSubmitSlashCommand), a native slash menu opens —
    /// the native counterpart of the web composer's SlashCommandMenuReact.
    var onQuerySlashCommands: (() async -> [SlashCommandInfo])?
    /// Submits a slash command message ("/cmd" or "/cmd option") picked from
    /// the slash menu. The menu clears the input text before calling.
    var onSubmitSlashCommand: ((String) -> Void)?
    /// Speech provider for mic dictation. Typed `Any?` because the speech
    /// layer is @available(iOS 26+) while the SDK floor is 17 — stored
    /// properties can't carry availability, so it's unlocked via #available
    /// casts. Pass `(any NativeSpeechProviding)?`; nil hides the mic button.
    var speechProvider: Any?
    /// Mic tap enters hands-free voice mode; double-tap toggles
    /// dictation-into-composer; long-press seeds voice mode with the
    /// composer text as the first spoken utterance (testing voice mode
    /// without speaking). The Bool is that seed flag; the return says
    /// whether voice mode actually started — on refusal (voice profile off)
    /// the mic falls back to dictation. Nil = dictation only.
    var onEnterVoiceMode: ((Bool) -> Bool)?
    @State private var isDictating = false
    @State private var dictationBase = ""
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var textHeight: CGFloat = 36
    @State private var fileSuggestions: [FileSuggestion] = []
    @State private var fileQueryTask: Task<Void, Never>?
    @State private var fileSuggestionsHeight: CGFloat = 0
    /// The character index where the `@` trigger was typed
    @State private var atTriggerIndex: String.Index?
    @State private var showAtSuggestions = false
    @State private var allElementSuggestions: [ElementSuggestion] = []
    @State private var elementSuggestions: [ElementSuggestion] = []
    @State private var allParticipantSuggestions: [ParticipantSuggestion] = []
    @State private var participantSuggestions: [ParticipantSuggestion] = []
    @State private var branchSuggestions: [BranchSuggestion] = []
    @State private var allBranchSuggestions: [BranchSuggestion] = []
    /// Classes hidden via the toggle chips (persisted in UserDefaults).
    @State private var hiddenClasses: Set<String> = Set(AtClassToggleSpec.all.filter { AtClassToggles.isHidden($0.key) }.map(\.key))
    @State private var showHistorySheet = false
    @State private var showTodoPicker = false
    @State private var glowPhase: Bool = false
    @State private var showSlashMenu = false
    @State private var slashFilter = ""
    @State private var slashCommands: [SlashCommandInfo] = []
    @State private var slashCommandsLoaded = false
    @State private var slashDrillCommand: SlashCommandInfo?
    /// Composer-visible alias → the `[context: …]` token it stands in for.
    @State private var contextAliases: [String: String] = [:]

    private var isTwoRow: Bool { chatInputLayout == "twoRow" }
    private var resolvedChatInputGlassStyle: String { chatInputGlassStyle ?? "clear" }

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        isAgentRunning: Bool = false,
        isAgentPaused: Bool = false,
        onSubmit: @escaping () -> Void,
        onSubmitNote: (() -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        onAddTodoItem: (() -> Void)? = nil,
        onFetchTodoItems: (() async -> RipulTodoItemsResult)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil,
        chatInputLayout: String? = nil,
        planMode: Binding<Bool> = .constant(false),
        showPlanModeToggle: Bool = false,
        onQueryFiles: ((String) async -> [FileSuggestion])? = nil,
        onQueryElements: (() async -> [ElementSuggestion])? = nil,
        onQueryParticipants: (() async -> [ParticipantSuggestion])? = nil,
        onQueryBranches: ((String) async -> [BranchSuggestion])? = nil,
        addressedParticipants: Binding<[String]> = .constant([]),
        onFocusChanged: ((Bool) -> Void)? = nil,
        onPlusLongPress: (() -> Void)? = nil,
        onQuerySlashCommands: (() async -> [SlashCommandInfo])? = nil,
        onSubmitSlashCommand: ((String) -> Void)? = nil,
        speechProvider: Any? = nil,
        onEnterVoiceMode: ((Bool) -> Bool)? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onSubmitNote = onSubmitNote
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.onAddTodoItem = onAddTodoItem
        self.onFetchTodoItems = onFetchTodoItems
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
        self.chatInputLayout = chatInputLayout
        self._planMode = planMode
        self.showPlanModeToggle = showPlanModeToggle
        self.onQueryFiles = onQueryFiles
        self.onQueryElements = onQueryElements
        self.onQueryParticipants = onQueryParticipants
        self.onQueryBranches = onQueryBranches
        self._addressedParticipants = addressedParticipants
        self.onFocusChanged = onFocusChanged
        self.onPlusLongPress = onPlusLongPress
        self.onQuerySlashCommands = onQuerySlashCommands
        self.onSubmitSlashCommand = onSubmitSlashCommand
        self.speechProvider = speechProvider
        self.onEnterVoiceMode = onEnterVoiceMode
    }

    private func dismissKeyboard() {
        // Every submit path dismisses the keyboard first, so this doubles as
        // the dictation stop hook — sending (or dismissing) ends the mic.
        stopDictation()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Dictation (mic → text binding)

    private var dictationAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        // The site key's profile can switch speech off wholesale. Checked here
        // rather than at the mic's gestures: with voice off the button should
        // be absent, not present and inert.
        guard SpeechPreferences.voiceEnabled else { return false }
        return speechProvider is (any NativeSpeechProviding)
    }

    /// Streams live transcription into the text binding: the in-flight
    /// partial rides after the committed base and is rewritten in place;
    /// committed segments fold into the base. Typed text present at mic
    /// start is preserved as the initial base.
    private func toggleDictation() {
        guard #available(iOS 26.0, *),
              let provider = speechProvider as? any NativeSpeechProviding else { return }
        if isDictating {
            provider.stopTranscription()
            return
        }
        dictationBase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try await provider.startTranscription { event in
                    switch event {
                    case .partial(let partial):
                        text = dictationBase.isEmpty ? partial : dictationBase + " " + partial
                    case .committed(let segment):
                        dictationBase = dictationBase.isEmpty ? segment : dictationBase + " " + segment
                        text = dictationBase
                    case .audioLevel:
                        break
                    case .error:
                        break
                    case .ended:
                        isDictating = false
                    }
                }
                isDictating = true
            } catch {
                isDictating = false
            }
        }
    }

    private func stopDictation() {
        guard isDictating, #available(iOS 26.0, *),
              let provider = speechProvider as? any NativeSpeechProviding else { return }
        provider.stopTranscription()
    }

    private func micButton(size: CGFloat) -> some View {
        // Not a Button: tap, double-tap, and long-press each map to a
        // distinct action, so the gestures compose exclusively — a Button's
        // touch-up action would fire on the first tap of a double-tap and
        // again when a long-press is released.
        let longPress = LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            if let onEnterVoiceMode {
                // Long-press = seed voice mode with the typed text as the
                // first utterance (spoken-reply testing without speaking).
                // Also stops any in-flight dictation; the dictated text
                // stays in the composer and goes in as the first utterance.
                dismissKeyboard()
                if !onEnterVoiceMode(true) { toggleDictation() }
            } else {
                toggleDictation()
            }
        }
        let doubleTap = TapGesture(count: 2).onEnded {
            // Double-tap = dictation-into-composer (transcribe, don't send).
            toggleDictation()
        }
        let singleTap = TapGesture().onEnded {
            if isDictating {
                // The mic is live from a double-tap — any tap ends it.
                toggleDictation()
            } else if let onEnterVoiceMode {
                // Tap = conversation mode with a live mic; the composer text
                // stays put (long-press is what consumes it). Drop the
                // keyboard so the overlay isn't fighting it for the screen.
                dismissKeyboard()
                if !onEnterVoiceMode(false) { toggleDictation() }
            } else {
                toggleDictation()
            }
        }
        return Image(systemName: isDictating ? "mic.fill" : "mic")
            .font(.system(size: size == 40 ? 18 : 16, weight: .bold))
            .foregroundStyle(isDictating ? Color.red : Color.accentColor)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .modifier(GlassCircleModifier(glassStyle: "clear"))
            .gesture(longPress.exclusively(before: doubleTap.exclusively(before: singleTap)))
            .accessibilityAddTraits(.isButton)
    }

    public var body: some View {
        VStack(spacing: 4) {
            if showAtSuggestions {
                unifiedSuggestionsOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showSlashMenu {
                slashCommandsOverlay
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
        .onChange(of: text) { newValue in
            if isDictating && newValue.isEmpty {
                dictationBase = ""
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isTwoRow)
        .animation(.easeInOut(duration: 0.15), value: showAtSuggestions)
        .animation(.easeInOut(duration: 0.15), value: showSlashMenu)
        .onChange(of: text) { newValue in
            if newValue.isEmpty {
                textHeight = 36 // minHeight — snap immediately when text is cleared
            }
            collapseIncomingContextTokens(newValue)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { uiImage in
                let resized = PhotoAttachmentHelper.downsamplePublic(uiImage)
                if let jpeg = resized.jpegData(compressionQuality: 0.7) {
                    let base64 = jpeg.base64EncodedString()
                    let id = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<100000))"
                    imageAttachments.append(NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: resized))
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showTodoPicker) {
            TodoPickerSheet(
                onFetch: onFetchTodoItems,
                onSelect: { todoText in
                    let separator = text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " "
                    text = text + separator + todoText
                    showTodoPicker = false
                }
            )
        }
    }

    // MARK: - @ Mention Suggestions

    /// Detect `@` followed by typing and populate a single ranked suggestion list
    /// (participants first, then files, then UI elements).
    private func handleAtDetection(_ value: String) {
        guard onQueryFiles != nil || onQueryElements != nil || onQueryParticipants != nil || onQueryBranches != nil else { return }

        guard let atRange = value.range(of: "@", options: .backwards) else {
            dismissAtOverlay()
            return
        }

        if atRange.lowerBound != value.startIndex {
            let charBefore = value[value.index(before: atRange.lowerBound)]
            if !charBefore.isWhitespace {
                dismissAtOverlay()
                return
            }
        }

        let afterAt = String(value[atRange.upperBound...])

        if afterAt.contains(" ") {
            dismissAtOverlay()
            return
        }

        let wasOpen = showAtSuggestions
        atTriggerIndex = atRange.lowerBound
        showAtSuggestions = true

        if !wasOpen {
            // Pre-fetch participants and elements once when the overlay opens.
            if let queryParticipants = onQueryParticipants {
                Task {
                    let results = await queryParticipants()
                    await MainActor.run {
                        allParticipantSuggestions = results
                        participantSuggestions = filterParticipants(by: afterAt, all: results)
                    }
                }
            }
            if !hiddenClasses.contains("repo"), let queryBranches = onQueryBranches {
                Task {
                    let results = await queryBranches(afterAt)
                    await MainActor.run {
                        allBranchSuggestions = results
                        branchSuggestions = filterBranches(by: afterAt, all: results)
                    }
                }
            }
            if let queryElements = onQueryElements {
                Task {
                    let results = await queryElements()
                    await MainActor.run {
                        allElementSuggestions = results
                        elementSuggestions = filterElements(by: afterAt, all: results)
                    }
                }
            }
        } else {
            // Already open — refilter cached lists locally.
            participantSuggestions = filterParticipants(by: afterAt, all: allParticipantSuggestions)
            branchSuggestions = filterBranches(by: afterAt, all: allBranchSuggestions)
            elementSuggestions = filterElements(by: afterAt, all: allElementSuggestions)
        }

        // Files: debounced remote query, only when there's text to search for.
        fileQueryTask?.cancel()
        if afterAt.isEmpty {
            fileSuggestions = []
        } else if let queryFiles = onQueryFiles {
            fileQueryTask = Task {
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                guard !Task.isCancelled else { return }
                let results = await queryFiles(afterAt)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    fileSuggestions = results
                }
            }
        }
    }

    private func filterParticipants(by query: String, all: [ParticipantSuggestion]) -> [ParticipantSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    private func filterElements(by query: String, all: [ElementSuggestion]) -> [ElementSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.dataUi.lowercased().contains(q) }
    }

    private func filterBranches(by query: String, all: [BranchSuggestion]) -> [BranchSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    private func dismissAtOverlay() {
        showAtSuggestions = false
        fileSuggestions = []
        elementSuggestions = []
        allElementSuggestions = []
        participantSuggestions = []
        allParticipantSuggestions = []
        branchSuggestions = []
        allBranchSuggestions = []
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
        dismissAtOverlay()
    }

    private func selectElementSuggestion(_ suggestion: ElementSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@ui:\(suggestion.dataUi) "
        } else {
            text += "@ui:\(suggestion.dataUi) "
        }
        dismissAtOverlay()
    }

    private func selectParticipantSuggestion(_ suggestion: ParticipantSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + suggestion.name + " "
        } else {
            text += "@" + suggestion.name + " "
        }
        if !addressedParticipants.contains(suggestion.id) {
            addressedParticipants.append(suggestion.id)
        }
        dismissAtOverlay()
    }

    private func selectBranchSuggestion(_ suggestion: BranchSuggestion) {
        // The field shows the branch name; submitMessage swaps the token back in.
        let alias = ContextMentionAliasing.alias(for: suggestion.name)
        contextAliases[alias] = suggestion.token
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + alias + " "
        } else {
            text += alias + " "
        }
        dismissAtOverlay()
    }

    /// A raw token can land in the field without going through the picker —
    /// history recall (which stores the submitted, expanded text), a restored
    /// draft, a paste. Collapse those to aliases too, so the base64 ref is never
    /// on screen and the mention still survives a re-send.
    private func collapseIncomingContextTokens(_ newValue: String) {
        var aliases = contextAliases
        let collapsed = ContextMentionAliasing.collapse(newValue, into: &aliases)
        guard collapsed != newValue else { return }
        contextAliases = aliases
        text = collapsed
    }

    /// Restore the `[context: …]` tokens the composer is displaying as aliases,
    /// then hand off. `text` is a binding straight into the caller's state, so
    /// the submit handler reads the expanded string.
    private func submitMessage() {
        let expanded = ContextMentionAliasing.expand(text, using: contextAliases)
        if expanded != text { text = expanded }
        contextAliases = [:]
        onSubmit()
    }

    private func toggleClass(_ key: String) {
        if hiddenClasses.contains(key) {
            hiddenClasses.remove(key)
        } else {
            hiddenClasses.insert(key)
        }
        AtClassToggles.setHidden(key, hiddenClasses.contains(key))
    }

    /// Fast show/hide chips for whole classes of suggestions, pinned atop the
    /// overlay. Persistence mirrors the web composer's atMenuClassToggles.
    private var classToggleRow: some View {
        HStack(spacing: 6) {
            ForEach(AtClassToggleSpec.all) { spec in
                Button {
                    toggleClass(spec.key)
                } label: {
                    Label(spec.label, systemImage: spec.icon)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(hiddenClasses.contains(spec.key) ? Color.clear : Color.accentColor.opacity(0.18)))
                        .overlay(Capsule().stroke(hiddenClasses.contains(spec.key) ? Color.secondary.opacity(0.35) : Color.accentColor, lineWidth: 1))
                        .foregroundStyle(hiddenClasses.contains(spec.key) ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func branchRow(_ suggestion: BranchSuggestion) -> some View {
        Button {
            selectBranchSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let description = suggestion.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if suggestion.remote {
                    Image(systemName: "cloud")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var afterAtText: String {
        guard let triggerIdx = atTriggerIndex,
              triggerIdx < text.endIndex else { return "" }
        let after = text.index(after: triggerIdx)
        guard after <= text.endIndex else { return "" }
        return String(text[after...])
    }

    private var unifiedSuggestionsOverlay: some View {
        VStack(spacing: 0) {
            classToggleRow
            let peopleShown = !participantSuggestions.isEmpty && !hiddenClasses.contains("people")
            let branchesShown = !branchSuggestions.isEmpty && !hiddenClasses.contains("repo")
            let filesShown = !fileSuggestions.isEmpty && !hiddenClasses.contains("files")
            let hasResults = peopleShown || branchesShown || filesShown || !elementSuggestions.isEmpty
            if !hasResults {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(hiddenClasses.contains("people") && hiddenClasses.contains("repo") && hiddenClasses.contains("files") && elementSuggestions.isEmpty ? "All classes hidden — use the toggles above" : (afterAtText.isEmpty ? "Type to search people, branches, files, and UI elements" : "No matches for \u{201C}\(afterAtText)\u{201D}"))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if peopleShown {
                            suggestionSectionHeader("People")
                            ForEach(participantSuggestions) { suggestion in
                                participantRow(suggestion)
                                if suggestion.id != participantSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if branchesShown {
                            if peopleShown {
                                Divider()
                            }
                            suggestionSectionHeader("Branches")
                            ForEach(branchSuggestions) { suggestion in
                                branchRow(suggestion)
                                if suggestion.id != branchSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if filesShown {
                            if peopleShown || branchesShown {
                                Divider()
                            }
                            suggestionSectionHeader("Files")
                            ForEach(fileSuggestions) { suggestion in
                                fileRow(suggestion)
                                if suggestion.id != fileSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if !elementSuggestions.isEmpty {
                            if peopleShown || branchesShown || filesShown {
                                Divider()
                            }
                            suggestionSectionHeader("UI Elements")
                            ForEach(elementSuggestions) { suggestion in
                                elementRow(suggestion)
                                if suggestion.id != elementSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    private func suggestionSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func participantRow(_ suggestion: ParticipantSuggestion) -> some View {
        Button {
            selectParticipantSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AutocompleteConstants.category(for: "people")?.sfSymbol ?? "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let group = suggestion.group, !group.isEmpty {
                        Text(group)
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
    }

    private func fileRow(_ suggestion: FileSuggestion) -> some View {
        Button {
            selectFileSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.isDirectory ? "folder.fill" : (AutocompleteConstants.category(for: "files")?.sfSymbol ?? "doc.text.fill"))
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
    }

    private func elementRow(_ suggestion: ElementSuggestion) -> some View {
        Button {
            selectElementSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AutocompleteConstants.category(for: "ui")?.sfSymbol ?? "tag.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.componentName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if suggestion.dataUi != suggestion.componentName {
                        Text(suggestion.dataUi)
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
    }

    // MARK: - / Slash Command Menu

    /// Detect "/" as the first character and show the native slash menu.
    /// Mirrors the web composer's semantics (ChatInputContainer.handleInputChange):
    /// opens only when the whole text is exactly "/", stays open while the text
    /// starts with "/" and contains no space, closes on the first space.
    private func handleSlashDetection(_ value: String) {
        guard onQuerySlashCommands != nil, onSubmitSlashCommand != nil else { return }

        if showSlashMenu {
            if !value.hasPrefix("/") || value.contains(" ") {
                dismissSlashOverlay()
            } else {
                slashFilter = String(value.dropFirst())
            }
        } else if value == "/" {
            slashFilter = ""
            slashDrillCommand = nil
            showSlashMenu = true
            fetchSlashCommands()
        }
    }

    private func fetchSlashCommands() {
        guard let query = onQuerySlashCommands else { return }
        slashCommandsLoaded = false
        Task {
            let results = await query()
            await MainActor.run {
                slashCommands = results
                slashCommandsLoaded = true
            }
        }
    }

    private func dismissSlashOverlay() {
        showSlashMenu = false
        slashFilter = ""
        slashDrillCommand = nil
    }

    private var filteredSlashCommands: [SlashCommandInfo] {
        if slashFilter.isEmpty { return slashCommands }
        let query = slashFilter.lowercased()
        return slashCommands.filter {
            $0.command.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    /// Tapping a command: options drill down in place (same as QuickCommandsSheet);
    /// anything else submits immediately.
    private func selectSlashCommand(_ command: SlashCommandInfo) {
        if command.options.isEmpty {
            submitSlashMessage("/\(command.command)")
        } else {
            slashDrillCommand = command
        }
    }

    private func selectSlashOption(_ option: SlashCommandOption) {
        guard let command = slashDrillCommand else { return }
        submitSlashMessage("/\(command.command) \(option.value)")
    }

    private func submitSlashMessage(_ message: String) {
        text = ""
        dismissSlashOverlay()
        onSubmitSlashCommand?(message)
    }

    private var slashCommandsOverlay: some View {
        VStack(spacing: 0) {
            if let drilled = slashDrillCommand {
                slashOptionsList(drilled)
            } else if filteredSlashCommands.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "slash.square")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(slashCommandsLoaded
                         ? (slashFilter.isEmpty ? "No commands available" : "No commands matching \u{201C}\(slashFilter)\u{201D}")
                         : "Loading commands…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        suggestionSectionHeader("Commands")
                        ForEach(filteredSlashCommands) { command in
                            slashCommandRow(command)
                            if command.id != filteredSlashCommands.last?.id {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    private func slashOptionsList(_ command: SlashCommandInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Button {
                    slashDrillCommand = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("/\(command.command)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(command.options) { option in
                    Divider().padding(.leading, 40)
                    Button {
                        selectSlashOption(option)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
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
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func slashCommandRow(_ command: SlashCommandInfo) -> some View {
        Button {
            selectSlashCommand(command)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: command.sfSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("/\(command.command)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(command.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !command.options.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        if showPlanModeToggle {
                            planModeToggle
                        }
                        textInputView
                        if dictationAvailable {
                            micButton(size: 36)
                        }
                        actionButton
                    }
                }
                .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
                .modifier(WaitingGlowModifier(isActive: agentWaiting, glowPhase: glowPhase))

                historyMenuButton
            }
        }
        .onChange(of: agentWaiting) { waiting in
            if waiting {
                withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                    glowPhase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    glowPhase = false
                }
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
                    if showPlanModeToggle {
                        planModeToggle
                    }
                    if dictationAvailable {
                        micButton(size: 40)
                    }
                    Spacer()
                    twoRowActionButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
            .modifier(WaitingGlowModifier(isActive: agentWaiting, glowPhase: glowPhase))
        }
        .onChange(of: agentWaiting) { waiting in
            if waiting {
                withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                    glowPhase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    glowPhase = false
                }
            }
        }
    }

    // MARK: - Plan Mode Toggle

    private var planModeToggle: some View {
        Menu {
            Button {
                planMode = false
            } label: {
                if !planMode { Label("Edit", systemImage: "checkmark") }
                else { Text("Edit") }
            }
            Button {
                planMode = true
            } label: {
                if planMode { Label("Plan", systemImage: "checkmark") }
                else { Text("Plan") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: planMode ? "eye" : "pencil")
                    .font(.system(size: 14, weight: .semibold))
                Text(planMode ? "Plan" : "Edit")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(height: 36)
            .padding(.horizontal, 10)
            .modifier(GlassPillModifier())
        }
        .animation(.easeInOut(duration: 0.15), value: planMode)
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
            if onFetchTodoItems != nil {
                Button {
                    dismissKeyboard()
                    showTodoPicker = true
                } label: {
                    Label("Pick to do", systemImage: "list.bullet.clipboard")
                }
            }
            if onAddTodoItem != nil {
                Button {
                    dismissKeyboard()
                    onAddTodoItem?()
                } label: {
                    Label("New to do", systemImage: "checklist")
                }
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
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                onPlusLongPress?()
            }
        )
    }

    private var agentWaiting: Bool {
        isAgentRunning && !isAgentPaused
    }

    // Matches ChatTextView's font so the shimmer overlay sits exactly where
    // the UIKit placeholder label would.
    private var placeholderFont: Font {
        .system(size: UIFont.preferredFont(forTextStyle: .body).pointSize + 1, weight: .semibold)
    }

    private var textInputView: some View {
        NoAutofillTextView(
            text: $text,
            height: $textHeight,
            // While waiting, the UIKit placeholder is blanked and the
            // shimmering SwiftUI overlay below renders the copy instead.
            placeholder: agentWaiting ? "" : isAgentPaused ? "Agent is paused, add new instruction…" : "Message...",
            onSubmit: {
                // On Catalyst (hardware keyboard) keep focus after sending so the
                // next message can be typed immediately; on iOS dismiss as before.
                #if !targetEnvironment(macCatalyst)
                dismissKeyboard()
                #endif
                submitMessage()
            },
            onTextChange: { newText in
                if newText.isEmpty {
                    dismissAtOverlay()
                    dismissSlashOverlay()
                } else {
                    handleAtDetection(newText)
                    handleSlashDetection(newText)
                }
            },
            onFocusChanged: onFocusChanged
        )
        .frame(maxWidth: .infinity, minHeight: textHeight, maxHeight: textHeight, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if agentWaiting && text.isEmpty {
                Text("Waiting on agent…")
                    .font(placeholderFont)
                    .ripulShimmer(base: Color(uiColor: .placeholderText))
                    .padding(.leading, 12)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    noteButton(size: 36, onTap: onSubmitNote, glassStyle: "clear")
                }
                if hasContent {
                    sendButton(size: 36, glassStyle: "clear")
                }
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
            }
            .padding(.trailing, 4)
        } else if isAgentPaused && isAgentRunning {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    noteButton(size: 36, onTap: onSubmitNote, glassStyle: "clear")
                }
                Button {
                    dismissKeyboard()
                    submitMessage()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .modifier(GlassCircleModifier(glassStyle: "clear"))
                }
            }
            .padding(.trailing, 4)
        } else if isAgentPaused || hasContent {
            HStack(spacing: 4) {
                if let onSubmitNote {
                    noteButton(size: 36, onTap: onSubmitNote, glassStyle: "clear")
                }
                Button {
                    dismissKeyboard()
                    submitMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .modifier(GlassCircleModifier(glassStyle: "clear"))
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func noteButton(size: CGFloat, onTap: @escaping () -> Void, glassStyle: String?) -> some View {
        Button {
            dismissKeyboard()
            onTap()
        } label: {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: size == 40 ? 18 : 16, weight: .bold))
                .foregroundStyle(.purple)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .modifier(GlassCircleModifier(glassStyle: glassStyle))
        }
    }

    // Send-to-agent button shown while a turn is running (when there's typed
    // content). Routes onSubmit -> bridge.submitMessage -> __ripulSubmitMessage,
    // which the web app FIFO-queues for CLI sessions (or injects as mid-run
    // context for in-process agents). Lets users type-ahead without stopping.
    private func sendButton(size: CGFloat, glassStyle: String?) -> some View {
        Button {
            dismissKeyboard()
            submitMessage()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: size == 40 ? 18 : 16, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .modifier(GlassCircleModifier(glassStyle: glassStyle))
        }
    }

    @ViewBuilder
    private var twoRowActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    noteButton(size: 40, onTap: onSubmitNote, glassStyle: nil)
                        .transition(.scale.combined(with: .opacity))
                }
                if hasContent {
                    sendButton(size: 40, glassStyle: nil)
                        .transition(.scale.combined(with: .opacity))
                }
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
            }
        } else if isAgentPaused && isAgentRunning {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    noteButton(size: 40, onTap: onSubmitNote, glassStyle: nil)
                        .transition(.scale.combined(with: .opacity))
                }
                Button {
                    dismissKeyboard()
                    submitMessage()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .modifier(GlassCircleModifier(glassStyle: nil))
                }
                .transition(.scale.combined(with: .opacity))
            }
        } else if isAgentPaused || hasContent {
            HStack(spacing: 4) {
                if let onSubmitNote {
                    noteButton(size: 40, onTap: onSubmitNote, glassStyle: nil)
                        .transition(.scale.combined(with: .opacity))
                }
                Button {
                    dismissKeyboard()
                    submitMessage()
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
    }

    @ViewBuilder
    private var historyMenuButton: some View {
        if let history = messageHistory, history.hasMessages {
            Button {
                showHistorySheet = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
            }
            .sheet(isPresented: $showHistorySheet) {
                HistorySheet(history: history) { msg in
                    text = msg
                    showHistorySheet = false
                }
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
    /// Send a human note (not sent to agent, for human-to-human communication).
    var onSubmitNote: (() -> Void)?
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    let onAddTodoItem: (() -> Void)?
    /// Fetches the user's todo items (with current-chat id for grouping) when
    /// the "Pick to do" menu entry is tapped. A selected todo's text is appended
    /// to this view's own `$text` binding — the native composer is the source
    /// of truth, not the hidden web composer.
    let onFetchTodoItems: (() async -> RipulTodoItemsResult)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    var chatInputLayout: String?
    /// Toggle between plan (read-only) and edit (default) mode for CLI sessions.
    @Binding var planMode: Bool
    /// Whether to show the plan/edit mode toggle (e.g., only in raw CLI sessions).
    var showPlanModeToggle: Bool
    /// Optional callback to query remote host for file suggestions.
    /// When provided, typing `@` followed by text triggers file autocomplete.
    var onQueryFiles: ((String) async -> [FileSuggestion])?
    /// Optional callback to fetch UI element suggestions from the current page.
    var onQueryElements: (() async -> [ElementSuggestion])?
    /// Optional callback to fetch chat participant suggestions (agents + humans).
    /// When provided, the `@` category overlay shows a "People" row that lists them.
    var onQueryParticipants: (() async -> [ParticipantSuggestion])?
    /// Optional callback to fetch repo branch suggestions (the chat's repo).
    /// When provided, the `@` overlay shows a "Branches" section; picking one
    /// inserts its `[context: …]` token, resolved to live branch facts at send.
    var onQueryBranches: ((String) async -> [BranchSuggestion])?
    /// Structured participant IDs picked since the last send. Cleared on submit
    /// by the parent so a new turn starts empty. Drives `addressedTo` routing.
    @Binding var addressedParticipants: [String]
    var onFocusChanged: ((Bool) -> Void)?
    /// Speech provider for mic dictation — see the iOS variant's doc comment.
    var speechProvider: Any?
    /// Mic tap enters hands-free voice mode; double-tap toggles
    /// dictation-into-composer; long-press seeds voice mode with the
    /// composer text as the first spoken utterance (testing voice mode
    /// without speaking). The Bool is that seed flag; the return says
    /// whether voice mode actually started — on refusal (voice profile off)
    /// the mic falls back to dictation. Nil = dictation only.
    var onEnterVoiceMode: ((Bool) -> Bool)?
    @State private var isDictating = false
    @State private var dictationBase = ""
    @State private var showPhotoPicker = false
    @FocusState private var isFocused: Bool
    @State private var fileSuggestions: [FileSuggestion] = []
    @State private var fileQueryTask: Task<Void, Never>?
    /// The character index where the `@` trigger was typed
    @State private var atTriggerIndex: String.Index?
    @State private var showHistorySheet = false
    @State private var showTodoPicker = false
    @State private var glowPhase: Bool = false
    @State private var showAtSuggestions = false
    @State private var allElementSuggestions: [ElementSuggestion] = []
    @State private var elementSuggestions: [ElementSuggestion] = []
    @State private var allParticipantSuggestions: [ParticipantSuggestion] = []
    @State private var participantSuggestions: [ParticipantSuggestion] = []
    @State private var branchSuggestions: [BranchSuggestion] = []
    @State private var allBranchSuggestions: [BranchSuggestion] = []
    /// Classes hidden via the toggle chips (persisted in UserDefaults).
    @State private var hiddenClasses: Set<String> = Set(AtClassToggleSpec.all.filter { AtClassToggles.isHidden($0.key) }.map(\.key))
    /// Composer-visible alias → the `[context: …]` token it stands in for.
    @State private var contextAliases: [String: String] = [:]

    private var isTwoRow: Bool { chatInputLayout == "twoRow" }
    private var resolvedChatInputGlassStyle: String { chatInputGlassStyle ?? "clear" }

    public init(
        text: Binding<String>,
        imageAttachments: Binding<[NativeImageAttachment]>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        isAgentRunning: Bool = false,
        isAgentPaused: Bool = false,
        onSubmit: @escaping () -> Void,
        onSubmitNote: (() -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        onAddTodoItem: (() -> Void)? = nil,
        onFetchTodoItems: (() async -> RipulTodoItemsResult)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil,
        chatInputLayout: String? = nil,
        planMode: Binding<Bool> = .constant(false),
        showPlanModeToggle: Bool = false,
        onQueryFiles: ((String) async -> [FileSuggestion])? = nil,
        onQueryElements: (() async -> [ElementSuggestion])? = nil,
        onQueryParticipants: (() async -> [ParticipantSuggestion])? = nil,
        onQueryBranches: ((String) async -> [BranchSuggestion])? = nil,
        addressedParticipants: Binding<[String]> = .constant([]),
        onFocusChanged: ((Bool) -> Void)? = nil,
        speechProvider: Any? = nil,
        onEnterVoiceMode: ((Bool) -> Bool)? = nil
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onSubmitNote = onSubmitNote
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.onAddTodoItem = onAddTodoItem
        self.onFetchTodoItems = onFetchTodoItems
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
        self.chatInputLayout = chatInputLayout
        self._planMode = planMode
        self.showPlanModeToggle = showPlanModeToggle
        self.onQueryFiles = onQueryFiles
        self.onQueryElements = onQueryElements
        self.onQueryParticipants = onQueryParticipants
        self.onQueryBranches = onQueryBranches
        self._addressedParticipants = addressedParticipants
        self.onFocusChanged = onFocusChanged
        self.speechProvider = speechProvider
        self.onEnterVoiceMode = onEnterVoiceMode
    }

    // MARK: - @ Mention Suggestions

    /// Detect `@` followed by typing and populate a single ranked suggestion list
    /// (participants first, then files, then UI elements).
    private func handleAtDetection(_ value: String) {
        guard onQueryFiles != nil || onQueryElements != nil || onQueryParticipants != nil || onQueryBranches != nil else { return }

        guard let atRange = value.range(of: "@", options: .backwards) else {
            dismissAtOverlay()
            return
        }

        if atRange.lowerBound != value.startIndex {
            let charBefore = value[value.index(before: atRange.lowerBound)]
            if !charBefore.isWhitespace {
                dismissAtOverlay()
                return
            }
        }

        let afterAt = String(value[atRange.upperBound...])

        if afterAt.contains(" ") {
            dismissAtOverlay()
            return
        }

        let wasOpen = showAtSuggestions
        atTriggerIndex = atRange.lowerBound
        showAtSuggestions = true

        if !wasOpen {
            // Pre-fetch participants and elements once when the overlay opens.
            if let queryParticipants = onQueryParticipants {
                Task {
                    let results = await queryParticipants()
                    await MainActor.run {
                        allParticipantSuggestions = results
                        participantSuggestions = filterParticipants(by: afterAt, all: results)
                    }
                }
            }
            if !hiddenClasses.contains("repo"), let queryBranches = onQueryBranches {
                Task {
                    let results = await queryBranches(afterAt)
                    await MainActor.run {
                        allBranchSuggestions = results
                        branchSuggestions = filterBranches(by: afterAt, all: results)
                    }
                }
            }
            if let queryElements = onQueryElements {
                Task {
                    let results = await queryElements()
                    await MainActor.run {
                        allElementSuggestions = results
                        elementSuggestions = filterElements(by: afterAt, all: results)
                    }
                }
            }
        } else {
            // Already open — refilter cached lists locally.
            participantSuggestions = filterParticipants(by: afterAt, all: allParticipantSuggestions)
            branchSuggestions = filterBranches(by: afterAt, all: allBranchSuggestions)
            elementSuggestions = filterElements(by: afterAt, all: allElementSuggestions)
        }

        // Files: debounced remote query, only when there's text to search for.
        fileQueryTask?.cancel()
        if afterAt.isEmpty {
            fileSuggestions = []
        } else if let queryFiles = onQueryFiles {
            fileQueryTask = Task {
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                guard !Task.isCancelled else { return }
                let results = await queryFiles(afterAt)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    fileSuggestions = results
                }
            }
        }
    }

    private func filterParticipants(by query: String, all: [ParticipantSuggestion]) -> [ParticipantSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    private func filterElements(by query: String, all: [ElementSuggestion]) -> [ElementSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.dataUi.lowercased().contains(q) }
    }

    private func filterBranches(by query: String, all: [BranchSuggestion]) -> [BranchSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    private func dismissAtOverlay() {
        showAtSuggestions = false
        fileSuggestions = []
        elementSuggestions = []
        allElementSuggestions = []
        participantSuggestions = []
        allParticipantSuggestions = []
        branchSuggestions = []
        allBranchSuggestions = []
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
        dismissAtOverlay()
    }

    private func selectElementSuggestion(_ suggestion: ElementSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@ui:\(suggestion.dataUi) "
        } else {
            text += "@ui:\(suggestion.dataUi) "
        }
        dismissAtOverlay()
    }

    private func selectParticipantSuggestion(_ suggestion: ParticipantSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + suggestion.name + " "
        } else {
            text += "@" + suggestion.name + " "
        }
        if !addressedParticipants.contains(suggestion.id) {
            addressedParticipants.append(suggestion.id)
        }
        dismissAtOverlay()
    }

    private func selectBranchSuggestion(_ suggestion: BranchSuggestion) {
        // The field shows the branch name; submitMessage swaps the token back in.
        let alias = ContextMentionAliasing.alias(for: suggestion.name)
        contextAliases[alias] = suggestion.token
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + alias + " "
        } else {
            text += alias + " "
        }
        dismissAtOverlay()
    }

    /// A raw token can land in the field without going through the picker —
    /// history recall (which stores the submitted, expanded text), a restored
    /// draft, a paste. Collapse those to aliases too, so the base64 ref is never
    /// on screen and the mention still survives a re-send.
    private func collapseIncomingContextTokens(_ newValue: String) {
        var aliases = contextAliases
        let collapsed = ContextMentionAliasing.collapse(newValue, into: &aliases)
        guard collapsed != newValue else { return }
        contextAliases = aliases
        text = collapsed
    }

    /// Restore the `[context: …]` tokens the composer is displaying as aliases,
    /// then hand off. `text` is a binding straight into the caller's state, so
    /// the submit handler reads the expanded string.
    private func submitMessage() {
        let expanded = ContextMentionAliasing.expand(text, using: contextAliases)
        if expanded != text { text = expanded }
        contextAliases = [:]
        onSubmit()
    }

    private func toggleClass(_ key: String) {
        if hiddenClasses.contains(key) {
            hiddenClasses.remove(key)
        } else {
            hiddenClasses.insert(key)
        }
        AtClassToggles.setHidden(key, hiddenClasses.contains(key))
    }

    /// Fast show/hide chips for whole classes of suggestions, pinned atop the
    /// overlay. Persistence mirrors the web composer's atMenuClassToggles.
    private var classToggleRow: some View {
        HStack(spacing: 6) {
            ForEach(AtClassToggleSpec.all) { spec in
                Button {
                    toggleClass(spec.key)
                } label: {
                    Label(spec.label, systemImage: spec.icon)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(hiddenClasses.contains(spec.key) ? Color.clear : Color.accentColor.opacity(0.18)))
                        .overlay(Capsule().stroke(hiddenClasses.contains(spec.key) ? Color.secondary.opacity(0.35) : Color.accentColor, lineWidth: 1))
                        .foregroundStyle(hiddenClasses.contains(spec.key) ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func branchRow(_ suggestion: BranchSuggestion) -> some View {
        Button {
            selectBranchSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let description = suggestion.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if suggestion.remote {
                    Image(systemName: "cloud")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var afterAtText: String {
        guard let triggerIdx = atTriggerIndex,
              triggerIdx < text.endIndex else { return "" }
        let after = text.index(after: triggerIdx)
        guard after <= text.endIndex else { return "" }
        return String(text[after...])
    }

    private var unifiedSuggestionsOverlay: some View {
        VStack(spacing: 0) {
            classToggleRow
            let peopleShown = !participantSuggestions.isEmpty && !hiddenClasses.contains("people")
            let branchesShown = !branchSuggestions.isEmpty && !hiddenClasses.contains("repo")
            let filesShown = !fileSuggestions.isEmpty && !hiddenClasses.contains("files")
            let hasResults = peopleShown || branchesShown || filesShown || !elementSuggestions.isEmpty
            if !hasResults {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(hiddenClasses.contains("people") && hiddenClasses.contains("repo") && hiddenClasses.contains("files") && elementSuggestions.isEmpty ? "All classes hidden — use the toggles above" : (afterAtText.isEmpty ? "Type to search people, branches, files, and UI elements" : "No matches for \u{201C}\(afterAtText)\u{201D}"))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if peopleShown {
                            suggestionSectionHeader("People")
                            ForEach(participantSuggestions) { suggestion in
                                participantRow(suggestion)
                                if suggestion.id != participantSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if branchesShown {
                            if peopleShown {
                                Divider()
                            }
                            suggestionSectionHeader("Branches")
                            ForEach(branchSuggestions) { suggestion in
                                branchRow(suggestion)
                                if suggestion.id != branchSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if filesShown {
                            if peopleShown || branchesShown {
                                Divider()
                            }
                            suggestionSectionHeader("Files")
                            ForEach(fileSuggestions) { suggestion in
                                fileRow(suggestion)
                                if suggestion.id != fileSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if !elementSuggestions.isEmpty {
                            if peopleShown || branchesShown || filesShown {
                                Divider()
                            }
                            suggestionSectionHeader("UI Elements")
                            ForEach(elementSuggestions) { suggestion in
                                elementRow(suggestion)
                                if suggestion.id != elementSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    private func suggestionSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func participantRow(_ suggestion: ParticipantSuggestion) -> some View {
        Button {
            selectParticipantSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AutocompleteConstants.category(for: "people")?.sfSymbol ?? "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let group = suggestion.group, !group.isEmpty {
                        Text(group)
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
    }

    private func fileRow(_ suggestion: FileSuggestion) -> some View {
        Button {
            selectFileSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.isDirectory ? "folder.fill" : (AutocompleteConstants.category(for: "files")?.sfSymbol ?? "doc.text.fill"))
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
    }

    private func elementRow(_ suggestion: ElementSuggestion) -> some View {
        Button {
            selectElementSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AutocompleteConstants.category(for: "ui")?.sfSymbol ?? "tag.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.componentName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if suggestion.dataUi != suggestion.componentName {
                        Text(suggestion.dataUi)
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
            if showAtSuggestions {
                unifiedSuggestionsOverlay
                    .offset(y: -8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isAgentRunning)
        .animation(.easeInOut(duration: 0.2), value: isTwoRow)
        .onChange(of: text) { newValue in
            if isDictating && newValue.isEmpty {
                dictationBase = ""
            }
            collapseIncomingContextTokens(newValue)
        }
        .animation(.easeInOut(duration: 0.2), value: showAtSuggestions)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .sheet(isPresented: $showTodoPicker) {
            TodoPickerSheet(
                onFetch: onFetchTodoItems,
                onSelect: { todoText in
                    let separator = text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " "
                    text = text + separator + todoText
                    showTodoPicker = false
                }
            )
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: isFocused) { focused in
            onFocusChanged?(focused)
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

    // MARK: - Dictation (mic → text binding)

    private var dictationAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        // See the iOS variant: voice off removes the button rather than
        // leaving it there to do nothing.
        guard SpeechPreferences.voiceEnabled else { return false }
        return speechProvider is (any NativeSpeechProviding)
    }

    private func toggleDictation() {
        guard #available(macOS 26.0, *),
              let provider = speechProvider as? any NativeSpeechProviding else { return }
        if isDictating {
            provider.stopTranscription()
            return
        }
        dictationBase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try await provider.startTranscription { event in
                    switch event {
                    case .partial(let partial):
                        text = dictationBase.isEmpty ? partial : dictationBase + " " + partial
                    case .committed(let segment):
                        dictationBase = dictationBase.isEmpty ? segment : dictationBase + " " + segment
                        text = dictationBase
                    case .audioLevel:
                        break
                    case .error:
                        break
                    case .ended:
                        isDictating = false
                    }
                }
                isDictating = true
            } catch {
                isDictating = false
            }
        }
    }

    private func stopDictation() {
        guard isDictating, #available(macOS 26.0, *),
              let provider = speechProvider as? any NativeSpeechProviding else { return }
        provider.stopTranscription()
    }

    private func micButton(size: CGFloat) -> some View {
        // Not a Button: tap, double-tap, and long-press each map to a
        // distinct action, so the gestures compose exclusively — a Button's
        // click action would fire on the first click of a double-click and
        // again when a long-press is released.
        let longPress = LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            if let onEnterVoiceMode {
                // Long-press = seed voice mode with the typed text as the
                // first utterance (spoken-reply testing without speaking).
                // Stop any in-flight dictation first; the dictated text
                // stays in the composer and goes in as the first utterance.
                stopDictation()
                if !onEnterVoiceMode(true) { toggleDictation() }
            } else {
                toggleDictation()
            }
        }
        let doubleTap = TapGesture(count: 2).onEnded {
            // Double-tap = dictation-into-composer (transcribe, don't send).
            toggleDictation()
        }
        let singleTap = TapGesture().onEnded {
            if isDictating {
                // The mic is live from a double-tap — any tap ends it.
                toggleDictation()
            } else if let onEnterVoiceMode {
                // Tap = conversation mode with a live mic; the composer text
                // stays put (long-press is what consumes it).
                if !onEnterVoiceMode(false) { toggleDictation() }
            } else {
                toggleDictation()
            }
        }
        return Image(systemName: isDictating ? "mic.fill" : "mic")
            .font(.system(size: size == 40 ? 18 : 16, weight: .bold))
            .foregroundStyle(isDictating ? Color.red : Color.accentColor)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .modifier(GlassCircleModifier(glassStyle: "clear"))
            .gesture(longPress.exclusively(before: doubleTap.exclusively(before: singleTap)))
            .accessibilityAddTraits(.isButton)
    }

    private var singleRowBody: some View {
        ChatInputGlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                plusMenuButton

                VStack(spacing: 0) {
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    HStack(spacing: 4) {
                        if showPlanModeToggle {
                            planModeToggle
                        }
                        textInputView
                        if dictationAvailable {
                            micButton(size: 36)
                        }
                        actionButton
                    }
                }
                .frame(minHeight: 40)
                .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
                .modifier(WaitingGlowModifier(isActive: agentWaiting, glowPhase: glowPhase))

                historyMenuButton
            }
        }
        .onChange(of: agentWaiting) { waiting in
            if waiting {
                withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                    glowPhase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    glowPhase = false
                }
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
                    if showPlanModeToggle {
                        planModeToggle
                    }
                    if dictationAvailable {
                        micButton(size: 40)
                    }
                    Spacer()
                    twoRowActionButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
            .modifier(WaitingGlowModifier(isActive: agentWaiting, glowPhase: glowPhase))
        }
        .onChange(of: agentWaiting) { waiting in
            if waiting {
                withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                    glowPhase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    glowPhase = false
                }
            }
        }
    }

    // MARK: - Plan Mode Toggle

    private var planModeToggle: some View {
        Menu {
            Button {
                planMode = false
            } label: {
                if !planMode { Label("Edit", systemImage: "checkmark") }
                else { Text("Edit") }
            }
            Button {
                planMode = true
            } label: {
                if planMode { Label("Plan", systemImage: "checkmark") }
                else { Text("Plan") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: planMode ? "eye" : "pencil")
                    .font(.system(size: 14, weight: .semibold))
                Text(planMode ? "Plan" : "Edit")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(height: 36)
            .padding(.horizontal, 10)
            .modifier(GlassPillModifier())
        }
        .animation(.easeInOut(duration: 0.15), value: planMode)
    }

    // MARK: - Shared Subviews

    private var plusMenuButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photos", systemImage: "photo")
            }
            if onFetchTodoItems != nil {
                Button {
                    showTodoPicker = true
                } label: {
                    Label("Pick to do", systemImage: "list.bullet.clipboard")
                }
            }
            if onAddTodoItem != nil {
                Button {
                    onAddTodoItem?()
                } label: {
                    Label("New to do", systemImage: "checklist")
                }
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

    private var agentWaiting: Bool {
        isAgentRunning && !isAgentPaused
    }

    private var textInputView: some View {
        // While waiting, the TextField placeholder is blanked and the
        // shimmering overlay below renders the copy instead.
        TextField(agentWaiting ? "" : isAgentPaused ? "Agent is paused, add new instruction…" : "Message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.leading, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .leading) {
                if agentWaiting && text.isEmpty {
                    Text("Waiting on agent…")
                        .ripulShimmer(base: Color(nsColor: .placeholderTextColor))
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
            .onSubmit {
                submitMessage()
            }
            .onChange(of: text) { newValue in
                handleAtDetection(newValue)
            }
    }

    private func macNoteButton(onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 28)
                .background(Color.purple, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Send note (not sent to agent)")
    }

    @ViewBuilder
    private var actionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    macNoteButton(onTap: onSubmitNote)
                }
                if hasContent {
                    Button {
                        submitMessage()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 28)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
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
            }
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 6)
        } else if isAgentPaused {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    macNoteButton(onTap: onSubmitNote)
                }
                Button {
                    submitMessage()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 28)
                        .background(Color.green, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 6)
        } else if hasContent {
            HStack(spacing: 4) {
                if let onSubmitNote {
                    macNoteButton(onTap: onSubmitNote)
                }
                Button {
                    submitMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 28)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private var twoRowActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    Button { onSubmitNote() } label: {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.purple)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                            .modifier(GlassCircleModifier(glassStyle: nil))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
                if hasContent {
                    Button { submitMessage() } label: {
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
            }
        } else if isAgentPaused {
            HStack(spacing: 4) {
                if hasContent, let onSubmitNote {
                    Button { onSubmitNote() } label: {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.purple)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                            .modifier(GlassCircleModifier(glassStyle: nil))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
                Button {
                    submitMessage()
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
            }
        } else if hasContent {
            HStack(spacing: 4) {
                if let onSubmitNote {
                    Button { onSubmitNote() } label: {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.purple)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                            .modifier(GlassCircleModifier(glassStyle: nil))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
                Button {
                    submitMessage()
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
    }

    @ViewBuilder
    private var historyMenuButton: some View {
        if let history = messageHistory, history.hasMessages {
            Button {
                showHistorySheet = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
            .sheet(isPresented: $showHistorySheet) {
                HistorySheet(history: history) { msg in
                    text = msg
                    showHistorySheet = false
                }
            }
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

// MARK: - History Sheet (cross-platform)

@available(iOS 16.0, macOS 14.0, *)
struct HistorySheet: View {
    @ObservedObject var history: MessageHistory
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let favs = history.favoriteMessages
                let recent = history.nonFavoriteRecentMessages
                if !favs.isEmpty {
                    Section("Favorites") {
                        ForEach(favs.prefix(15), id: \.self) { msg in
                            historyRow(msg)
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent.prefix(15), id: \.self) { msg in
                            historyRow(msg)
                        }
                    }
                }
            }
            .navigationTitle("Recent Prompts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #else
        .presentationDetents([.medium, .large], selection: .constant(.large))
        #endif
    }

    private func historyRow(_ msg: String) -> some View {
        Button {
            onSelect(msg)
        } label: {
            HStack {
                if history.isFavorite(msg) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                }
                Text(msg)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                history.remove(msg)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                history.toggleFavorite(msg)
            } label: {
                Label(
                    history.isFavorite(msg) ? "Unfavorite" : "Favorite",
                    systemImage: history.isFavorite(msg) ? "star.slash.fill" : "star.fill"
                )
            }
            .tint(.yellow)
        }
    }
}

// MARK: - Todo Picker Sheet

/// Native list picker for inserting an existing todo's text into the chat
/// composer. Current chat's todos render in a "This chat" section on top;
/// everything else falls into "Other chats". Fetches on appear via the
/// supplied closure (which wraps `AgentBridge.listTodoItems()`).
@available(iOS 16.0, macOS 14.0, *)
struct TodoPickerSheet: View {
    let onFetch: (() async -> RipulTodoItemsResult)?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var items: [RipulTodoItem] = []
    @State private var currentChatId: String? = nil

    private var thisChatItems: [RipulTodoItem] {
        guard let currentChatId else { return [] }
        return items.filter { $0.chatId == currentChatId && !$0.completed }
    }

    private var otherChatItems: [RipulTodoItem] {
        items.filter { ($0.chatId ?? "") != (currentChatId ?? "__none__") && !$0.completed }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if thisChatItems.isEmpty && otherChatItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No to do items")
                            .font(.headline)
                        Text("Create one from the + menu to pick it later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !thisChatItems.isEmpty {
                            Section("This chat") {
                                ForEach(thisChatItems) { item in
                                    todoRow(item, showChatName: false)
                                }
                            }
                        }
                        if !otherChatItems.isEmpty {
                            Section("Other chats") {
                                ForEach(otherChatItems) { item in
                                    todoRow(item, showChatName: true)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pick to do")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 400)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .task {
            guard let onFetch else { loading = false; return }
            let result = await onFetch()
            items = result.items
            currentChatId = result.currentChatId
            loading = false
        }
    }

    private func todoRow(_ item: RipulTodoItem, showChatName: Bool) -> some View {
        Button {
            onSelect(item.text)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                if showChatName, let chatName = item.chatName, !chatName.isEmpty {
                    Text(chatName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Waiting Glow Effect

@available(iOS 15.0, macOS 14.0, *)
private struct WaitingGlowModifier: ViewModifier {
    let isActive: Bool
    let glowPhase: Bool

    // Stroke-opacity pulse only — no .shadow. An animating blur radius over the
    // glass pill forces the compositor to re-blur the region every frame for the
    // entire agent run (sustained GPU heat, thermal audit R2-2).
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(
                        Color.orange.opacity(isActive ? (glowPhase ? 0.35 : 0.12) : 0),
                        lineWidth: 1.25
                    )
            )
    }
}

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

    /// Fires when layout gives the view a new width, so the composer height can
    /// be remeasured against the width the text actually wraps at (first layout
    /// after a remake, rotation). Width-only: height writes back into the
    /// SwiftUI frame, so keying on height would recurse.
    var onLayoutWidthChange: (() -> Void)?
    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            onLayoutWidthChange?()
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Hardware-keyboard Return (no Shift) sends the message; Shift+Return inserts a
    /// newline. Wired by NoAutofillTextView to the submit action. iPhone (non-Catalyst)
    /// keeps the default behaviour where Return inserts a newline.
    var onReturnKey: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleReturnKey))
        send.wantsPriorityOverSystemBehavior = true
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleShiftReturnKey))
        newline.wantsPriorityOverSystemBehavior = true
        return [send, newline]
    }

    @objc private func handleReturnKey() { onReturnKey?() }
    @objc private func handleShiftReturnKey() { insertText("\n") }
    #endif
}

/// UITextView wrapper that completely disables autofill suggestions.
@available(iOS 15.0, *)
struct NoAutofillTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var onTextChange: ((String) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

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
        textView.returnKeyType = .default
        textView.enablesReturnKeyAutomatically = false

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

        // A remade view can start with multi-line text already in it (draft
        // restored, session switch) — the first real layout is when the wrap
        // width becomes known, so measure there rather than at width 0.
        textView.onLayoutWidthChange = { [weak textView, weak coordinator = context.coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.recalcHeight(textView)
        }

        return textView
    }

    func updateUIView(_ textView: ChatTextView, context: Context) {
        context.coordinator.parent = self
        #if targetEnvironment(macCatalyst)
        textView.onReturnKey = onSubmit
        #endif
        // Keep placeholder text in sync with SwiftUI state
        if context.coordinator.placeholderLabel?.text != placeholder {
            context.coordinator.placeholderLabel?.text = placeholder
        }

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
            let width = textView.bounds.width
            // Before the first layout the wrap width is unknown — any measure
            // would be garbage (one giant line). Skip; the width-change hook
            // remeasures once layout runs.
            guard textView.text.isEmpty || width > 0 else { return }
            // sizeThatFits forces layout of the FULL text. contentSize can
            // under-report it when the view isn't first responder (TextKit only
            // guarantees layout of the visible viewport), which is what shrank
            // a multi-line composer on blur.
            let target = textView.text.isEmpty
                ? parent.minHeight
                : min(max(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height,
                          parent.minHeight),
                      parent.maxHeight)
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

        func textViewDidBeginEditing(_ textView: UITextView) {
            // Tapping into a collapsed multi-line box must re-expand it the
            // same way typing does — remeasure now, not on the next keystroke.
            recalcHeight(textView)
            parent.onFocusChanged?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChanged?(false)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
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

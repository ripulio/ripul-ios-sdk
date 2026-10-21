import SwiftUI
import UniformTypeIdentifiers

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
/// A photo or a file attached in the composer. Still named for images, like
/// the page's `imageAttachments` it becomes, though it now carries any file
/// FileAttachmentHelper accepts.
public struct NativeImageAttachment: Identifiable {
    public let id: String
    public let mediaType: String
    public let data: String // base64
    public let thumbnail: PlatformImage
    /// The file's own name, which the agent's copy keeps. A photo has none.
    public let name: String?

    public init(id: String, mediaType: String, data: String, thumbnail: PlatformImage, name: String? = nil) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.thumbnail = thumbnail
        self.name = name
    }

    static func restore(_ files: [[String: String]]) -> [NativeImageAttachment] {
        files.compactMap { file in
            guard let encoded = file["data"], let mediaType = file["mediaType"] else { return nil }
            let name = file["name"]
            let thumbnail: PlatformImage
            if mediaType.hasPrefix("image/"), let data = Data(base64Encoded: encoded), let image = PlatformImage(data: data) {
                thumbnail = image
            } else {
                thumbnail = FileAttachmentHelper.thumbnail(for: mediaType, name: name)
            }
            return NativeImageAttachment(id: UUID().uuidString, mediaType: mediaType,
                data: encoded, thumbnail: thumbnail, name: name)
        }
    }

    /// A photo shows as its picture; any other file as a chip with its name.
    public var isImage: Bool { mediaType.hasPrefix("image/") }

    public func toDictionary() -> [String: String] {
        var dictionary = ["id": id, "mediaType": mediaType, "data": data]
        if let name { dictionary["name"] = name }
        return dictionary
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

/// A teammate for the @ picker — someone the signed-in account shares a team
/// with who is not yet in this chat. Picking one inserts the mention AND
/// invites them (the same owner-issued, email-keyed invitation as the share
/// sheet's "Invite by Email"). `id` is the roster's `human-<userId>`.
public struct TeammateSuggestion: Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let description: String?

    public init(id: String, name: String, email: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.description = description
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

/// A conversation selected from the composer's Chats section.
public struct ChatSuggestion: Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let token: String
    public init(id: String, name: String, description: String? = nil, token: String) {
        self.id = id; self.name = name; self.description = description; self.token = token
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
            let token = ns.substring(with: match.range)
            let aliasText = uniqueAlias(for: label, token: token, aliases: aliases)
            aliases[aliasText] = token
            out.replaceCharacters(in: match.range, with: aliasText)
        }
        return out as String
    }

    static func uniqueAlias(for label: String, token: String, aliases: [String: String]) -> String {
        if let existing = aliases.first(where: { $0.value == token })?.key { return existing }
        let base = alias(for: label)
        var candidate = base
        var number = 2
        while aliases[candidate] != nil {
            candidate = "\(base) (\(number))"
            number += 1
        }
        return candidate
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
        AtClassToggleSpec(key: "chats", label: "Chats", icon: "bubble.left.and.bubble.right"),
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
    @Environment(\.ripulComposerChrome) private var composerChrome
    @Environment(\.composerCollapse) private var composerCollapse
    @State private var composerFocused = false
    private var chromeInteraction: Bool {
        composerFocused || isDictating || showPhotoPicker || showCamera || showTodoPicker || showHistorySheet
            || showAtSuggestions || showSlashMenu
    }
    @Binding var text: String
    @Binding var imageAttachments: [NativeImageAttachment]
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isAgentRunning: Bool
    let isAgentPaused: Bool
    let onSubmit: () -> Void
    var onTypingChange: ((Bool) -> Void)?
    @ObservedObject var contextStore: RipulComposerContextStore
    var contextSessionID: String?
    var contextOptions: [RipulComposerContext]
    /// Send a human note (not sent to agent, for human-to-human communication).
    var onSubmitNote: (() -> Void)?
    var conversationMode: String
    /// The message being replied to, shown above the field until sent or cancelled.
    var replyTarget: RipulReplyTarget?
    var onCancelReply: (() -> Void)?
    var runningSendLabel: String
    var composerActions: [RipulComposerAction]
    var composerActionPending: Bool
    var onComposerAction: ((String) -> Void)?
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    let onAddArtefact: (() -> Void)?
    let onAddTodoItem: (() -> Void)?
    /// Fetches the user's todo items (with current-chat id for grouping) when
    /// the "Pick to do" menu entry is tapped. A selected todo's text is appended
    /// to this view's own `$text` binding — the native composer is the source
    /// of truth, not the hidden web composer.
    let onFetchTodoItems: (() async -> RipulTodoItemsResult)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    var chatInputLayout: String?
    /// Optional callback to query remote host for file suggestions.
    /// When provided, typing `@` followed by text triggers file autocomplete.
    var onQueryFiles: ((String) async -> [FileSuggestion])?
    /// Optional callback to fetch UI element suggestions from the current page.
    var onQueryElements: (() async -> [ElementSuggestion])?
    /// Optional: the `@` overlay's Element row. Picking it replaces the typed
    /// `@…` and hands off to the host, which opens the View Explorer and
    /// brings the chosen element back as a composer context chip. The host
    /// returns the element's name ("Element A"), which lands where the `@`
    /// was, or nil when nothing was picked.
    var onPickElement: (() async -> String?)?
    /// Optional callback to fetch chat participant suggestions (agents + humans).
    /// When provided, the `@` category overlay shows a "People" row that lists them.
    var onQueryParticipants: (() async -> [ParticipantSuggestion])?
    /// Optional callback to fetch repo branch suggestions (the chat's repo).
    /// When provided, the `@` overlay shows a "Branches" section; picking one
    /// inserts its `[context: …]` token, resolved to live branch facts at send.
    var onQueryChats: ((String) async -> [ChatSuggestion])?
    var onQueryBranches: ((String) async -> [BranchSuggestion])?
    /// Optional callback to fetch teammates not yet in this chat. When provided,
    /// the `@` overlay shows a "Team" section under People; picking one inserts
    /// the mention and hands the row to `onInviteTeammate`.
    var onQueryTeammates: (() async -> [TeammateSuggestion])?
    /// Invite a picked teammate into the chat. Returns a user-facing error, or nil.
    var onInviteTeammate: ((TeammateSuggestion) async -> String?)?
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
    @State private var microphoneWarning: String?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var attachmentError: String?
    @State private var dropTargeted = false
    @State private var showCamera = false
    @State private var textHeight: CGFloat = 36
    @State private var fileSuggestions: [FileSuggestion] = []
    @State private var fileQueryTask: Task<Void, Never>?
    @State private var fileSuggestionsHeight: CGFloat = 0
    /// The character index where the `@` trigger was typed
    @State private var atTriggerIndex: String.Index?
    @State private var showAtSuggestions = false
    /// The @ list's row the keyboard is on, an index into `atPicks`.
    @State private var atHighlight = 0
    @State private var allElementSuggestions: [ElementSuggestion] = []
    @State private var elementSuggestions: [ElementSuggestion] = []
    @State private var allParticipantSuggestions: [ParticipantSuggestion] = []
    @State private var participantSuggestions: [ParticipantSuggestion] = []
    @State private var branchSuggestions: [BranchSuggestion] = []
    @State private var allBranchSuggestions: [BranchSuggestion] = []
    @State private var chatSuggestions: [ChatSuggestion] = []
    @State private var chatQueryTask: Task<Void, Never>?
    @State private var chatsLoading = false
    @State private var allTeammateSuggestions: [TeammateSuggestion] = []
    @State private var teammateSuggestions: [TeammateSuggestion] = []
    /// Outcome of the last teammate invitation, shown briefly above the field.
    @State private var atNotice: String?
    @State private var atNoticeTask: Task<Void, Never>?
    /// Classes hidden via the toggle chips (persisted in UserDefaults).
    @State private var hiddenClasses: Set<String> = Set(AtClassToggleSpec.all.filter { AtClassToggles.isHidden($0.key) }.map(\.key))
    @State private var showHistorySheet = false
    @State private var historyDraftAttachments: [NativeImageAttachment] = []
    @State private var showTodoPicker = false
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
        onTypingChange: ((Bool) -> Void)? = nil,
        onSubmitNote: (() -> Void)? = nil,
        conversationMode: String = "agent",
        replyTarget: RipulReplyTarget? = nil,
        onCancelReply: (() -> Void)? = nil,
        runningSendLabel: String = "Send",
        composerActions: [RipulComposerAction] = [],
        composerActionPending: Bool = false,
        onComposerAction: ((String) -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        onAddArtefact: (() -> Void)? = nil,
        onAddTodoItem: (() -> Void)? = nil,
        onFetchTodoItems: (() async -> RipulTodoItemsResult)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil,
        chatInputLayout: String? = nil,
        onQueryFiles: ((String) async -> [FileSuggestion])? = nil,
        onQueryElements: (() async -> [ElementSuggestion])? = nil,
        onPickElement: (() async -> String?)? = nil,
        onQueryParticipants: (() async -> [ParticipantSuggestion])? = nil,
        onQueryTeammates: (() async -> [TeammateSuggestion])? = nil,
        onInviteTeammate: ((TeammateSuggestion) async -> String?)? = nil,
        onQueryChats: ((String) async -> [ChatSuggestion])? = nil,
        onQueryBranches: ((String) async -> [BranchSuggestion])? = nil,
        addressedParticipants: Binding<[String]> = .constant([]),
        onFocusChanged: ((Bool) -> Void)? = nil,
        onPlusLongPress: (() -> Void)? = nil,
        onQuerySlashCommands: (() async -> [SlashCommandInfo])? = nil,
        onSubmitSlashCommand: ((String) -> Void)? = nil,
        speechProvider: Any? = nil,
        onEnterVoiceMode: ((Bool) -> Bool)? = nil,
        contextStore: RipulComposerContextStore? = nil,
        contextSessionID: String? = nil,
        contextOptions: [RipulComposerContext] = RipulComposerContext.standard
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onTypingChange = onTypingChange
        self.onSubmitNote = onSubmitNote
        self.conversationMode = conversationMode
        self.replyTarget = replyTarget
        self.onCancelReply = onCancelReply
        self.runningSendLabel = runningSendLabel
        self.composerActions = composerActions
        self.composerActionPending = composerActionPending
        self.onComposerAction = onComposerAction
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.onAddArtefact = onAddArtefact
        self.onAddTodoItem = onAddTodoItem
        self.onFetchTodoItems = onFetchTodoItems
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
        self.chatInputLayout = chatInputLayout
        self.onQueryFiles = onQueryFiles
        self.onQueryElements = onQueryElements
        self.onPickElement = onPickElement
        self.onQueryParticipants = onQueryParticipants
        self.onQueryChats = onQueryChats
        self.onQueryBranches = onQueryBranches
        self.onQueryTeammates = onQueryTeammates
        self.onInviteTeammate = onInviteTeammate
        self._addressedParticipants = addressedParticipants
        self.onFocusChanged = onFocusChanged
        self.onPlusLongPress = onPlusLongPress
        self.onQuerySlashCommands = onQuerySlashCommands
        self.onSubmitSlashCommand = onSubmitSlashCommand
        self.speechProvider = speechProvider
        self.onEnterVoiceMode = onEnterVoiceMode
        self.contextStore = contextStore ?? RipulComposerContextStore()
        self.contextSessionID = contextSessionID
        self.contextOptions = contextOptions
    }

    /// Dropped images and files join the attachments, four at a time like
    /// the picker. Anything that cannot be attached is named in the alert.
    private func attachDroppedFiles(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        guard providers.count <= 4 else {
            attachmentError = "Drop up to four files or images at a time."
            return
        }
        Task { @MainActor in
            let (attachments, refused) = await PhotoAttachmentHelper.process(dropped: providers)
            imageAttachments.append(contentsOf: attachments)
            if !refused.isEmpty { attachmentError = refused.joined(separator: "\n") }
        }
    }

    /// Files chosen in the Files picker: images are resized like photos, and
    /// anything that cannot be attached is named in the alert.
    private func attachChosenFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard urls.count <= 4 else {
                attachmentError = "Choose up to four files at a time."
                return
            }
            var refused: [String] = []
            for url in urls {
                do {
                    imageAttachments.append(try FileAttachmentHelper.attachment(fromFileAt: url))
                } catch {
                    refused.append(error.localizedDescription)
                }
            }
            if !refused.isEmpty { attachmentError = refused.joined(separator: "\n") }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                attachmentError = error.localizedDescription
            }
        }
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
                        messageHistory?.composerModality = "voice"
                        text = dictationBase.isEmpty ? partial : dictationBase + " " + partial
                    case .committed(let segment):
                        messageHistory?.composerModality = "voice"
                        dictationBase = dictationBase.isEmpty ? segment : dictationBase + " " + segment
                        text = dictationBase
                    case .audioLevel, .connectionReady, .recovery:
                        break
                    case .error, .audioGap:
                        break
                    case .ended:
                        isDictating = false
                    }
                }
                isDictating = true
            } catch {
                isDictating = false
                microphoneWarning = error.localizedDescription
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
            .font(.ripulIcon(size: size == 40 ? 18 : 16, weight: .bold))
            .foregroundStyle(isDictating ? Color.ripul(.danger) : Color.accentColor)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .modifier(GlassCircleModifier(glassStyle: "clear"))
            .gesture(longPress.exclusively(before: doubleTap.exclusively(before: singleTap)))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Microphone")
            .accessibilityIdentifier("NativeChatInput.microphone")
    }

    public var body: some View {
        VStack(spacing: 4) {
            if let atNotice {
                atNoticeBanner(atNotice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
            #if targetEnvironment(macCatalyst)
            // The labels already draw circular glass. Mac idiom's automatic
            // button style adds a second, rectangular bezel around them.
            .buttonStyle(.plain)
            #endif
            // Drops on the editor arrive through its paste delegate; this
            // catches the rest of the composer, and image-only drags.
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
                attachDroppedFiles(providers)
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(composerChrome == nil ? .easeInOut(duration: 0.15) : nil, value: textHeight)
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .onChange(of: chromeInteraction) { active in
            composerChrome?.setInteraction("input", active: active)
        }
        .onAppear { composerChrome?.setInteraction("input", active: chromeInteraction) }
        .onChange(of: composerChrome != nil) { _ in
            composerChrome?.setInteraction("input", active: chromeInteraction)
        }
        .onDisappear { composerChrome?.setInteraction("input", active: false) }
        .onChange(of: contextSessionID) { _ in
            dismissAtOverlay()
        }
        .onChange(of: text) { newValue in
            if newValue.isEmpty { messageHistory?.composerModality = "keyboard" }
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
        .modifier(SpeechInputWarningModifier(message: $microphoneWarning))
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: FileAttachmentHelper.allowedContentTypes,
                      allowsMultipleSelection: true) { attachChosenFiles($0) }
        .alert("Couldn't attach", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
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
        .ripulSheet(isPresented: $showTodoPicker) {
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
        guard onQueryFiles != nil || onQueryElements != nil || onPickElement != nil || onQueryParticipants != nil || onQueryBranches != nil || onQueryChats != nil || onQueryTeammates != nil else { return }

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

        if afterAt.contains("\n") || afterAt.count > 120 || (afterAt.contains(" ") && !showAtSuggestions) || contextAliases.keys.contains(where: { afterAt.hasPrefix(String($0.dropFirst()) + " ") }) {
            dismissAtOverlay()
            return
        }

        let wasOpen = showAtSuggestions
        // New text means new results: the keyboard starts at the top again.
        atHighlight = 0
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
            if !hiddenClasses.contains("people"), let queryTeammates = onQueryTeammates {
                Task {
                    let results = await queryTeammates()
                    await MainActor.run {
                        allTeammateSuggestions = results
                        teammateSuggestions = filterTeammates(by: afterAt, all: results)
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
            teammateSuggestions = filterTeammates(by: afterAt, all: allTeammateSuggestions)
            branchSuggestions = filterBranches(by: afterAt, all: allBranchSuggestions)
            elementSuggestions = filterElements(by: afterAt, all: allElementSuggestions)
        }

        // Re-query the complete catalogue for each search, not just the initial
        // recent page. Cancellation prevents an old query replacing new results.
        chatQueryTask?.cancel()
        if !hiddenClasses.contains("chats"), let queryChats = onQueryChats {
            chatsLoading = true
            chatQueryTask = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                let results = await queryChats(afterAt)
                guard !Task.isCancelled, showAtSuggestions else { return }
                chatSuggestions = results
                chatsLoading = false
            }
        } else { chatsLoading = false; chatSuggestions = [] }

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

    private func filterTeammates(by query: String, all: [TeammateSuggestion]) -> [TeammateSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
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
        teammateSuggestions = []
        allTeammateSuggestions = []
        branchSuggestions = []
        allBranchSuggestions = []
        chatSuggestions = []
        chatsLoading = false
        chatQueryTask?.cancel()
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

    /// The Element row opens a pick rather than naming something already
    /// known: the typed `@…` goes now, and the element's name ("@Element A")
    /// takes its place once the pick returns — so "compare @Element A with
    /// @Element B" reads the way it was typed. The `@` query is always the
    /// last word, so the name goes on the end.
    private func selectElementPick() {
        guard let onPickElement else { return }
        if let triggerIdx = atTriggerIndex {
            text = String(text[text.startIndex..<triggerIdx])
        }
        dismissAtOverlay()
        dismissKeyboard()
        let field = $text
        Task { @MainActor in
            guard let reference = await onPickElement() else { return }
            let current = field.wrappedValue
            let gap = current.isEmpty || current.last?.isWhitespace == true ? "" : " "
            field.wrappedValue = current + gap + "@" + reference + " "
        }
    }

    /// Offered for a bare `@` and for anything typed toward "element".
    private var elementPickShown: Bool {
        guard onPickElement != nil else { return false }
        let query = afterAtText.lowercased()
        return query.isEmpty || "element".hasPrefix(query) || "pick".hasPrefix(query)
    }

    /// A person's name as an @ token. A mention ends at the first space, so
    /// "Sandsend Retreats" went out as "@Sandsend Retreats" and only "Sandsend"
    /// was drawn as the mention. The web composer flattens spaces to `_` and
    /// the message renderer turns them back (participantMentions.ts).
    static func mentionToken(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }

    private func selectParticipantSuggestion(_ suggestion: ParticipantSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + Self.mentionToken(suggestion.name) + " "
        } else {
            text += "@" + Self.mentionToken(suggestion.name) + " "
        }
        if !addressedParticipants.contains(suggestion.id) {
            addressedParticipants.append(suggestion.id)
        }
        dismissAtOverlay()
    }

    private func selectTeammateSuggestion(_ suggestion: TeammateSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + Self.mentionToken(suggestion.name) + " "
        } else {
            text += "@" + Self.mentionToken(suggestion.name) + " "
        }
        if !addressedParticipants.contains(suggestion.id) {
            addressedParticipants.append(suggestion.id)
        }
        dismissAtOverlay()
        guard let onInviteTeammate else { return }
        let who = suggestion.name.replacingOccurrences(of: "_", with: " ")
        Task {
            let error = await onInviteTeammate(suggestion)
            await MainActor.run {
                showAtNotice(error.map { "Couldn't invite \(who): \($0)" } ?? "Invited \(who) to this chat")
            }
        }
    }

    private func selectChatSuggestion(_ suggestion: ChatSuggestion) {
        // Keep two chats with the same title independently addressable.
        let alias = ContextMentionAliasing.uniqueAlias(for: suggestion.name, token: suggestion.token, aliases: contextAliases)
        contextAliases[alias] = suggestion.token
        if let triggerIdx = atTriggerIndex {
            text = String(text[text.startIndex..<triggerIdx]) + alias + " "
        } else { text += alias + " " }
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
        onTypingChange?(false)
        guard !composerActionPending else { return }
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
        if key == "chats" { handleAtDetection(text) }
    }

    /// Fast show/hide chips for whole classes of suggestions, pinned atop the
    /// overlay. Persistence mirrors the web composer's atMenuClassToggles.
    private var classToggleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
            ForEach(AtClassToggleSpec.all) { spec in
                Button {
                    toggleClass(spec.key)
                } label: {
                    Label(spec.label, systemImage: spec.icon)
                        .font(.ripul(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(hiddenClasses.contains(spec.key) ? Color.clear : Color.accentColor.opacity(0.18)))
                        .overlay(Capsule().stroke(hiddenClasses.contains(spec.key) ? Color.ripul(.textSecondary).opacity(0.35) : Color.accentColor, lineWidth: 1))
                        .foregroundStyle(hiddenClasses.contains(spec.key) ? Color.ripul(.textSecondary) : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        }
    }

    private func chatRow(_ suggestion: ChatSuggestion) -> some View {
        Button { selectChatSuggestion(suggestion) } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.ripul(.textSecondary)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name).font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text)).lineLimit(2)
                    if let description = suggestion.description {
                        Text(description).font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary)).lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Composer.chatSuggestion")
    }

    private func branchRow(_ suggestion: BranchSuggestion) -> some View {
        Button {
            selectBranchSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if let description = suggestion.description, !description.isEmpty {
                        Text(description)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if suggestion.remote {
                    Image(systemName: "cloud")
                        .font(.ripulIcon(size: 11))
                        .foregroundStyle(.ripul(.textSecondary))
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

    /// The @ list's rows in the order the overlay draws them, so the arrow
    /// keys walk what is on screen. Each pick runs the row's own tap action.
    private var atPicks: [(id: String, select: () -> Void)] {
        var picks: [(id: String, select: () -> Void)] = []
        if elementPickShown { picks.append(("pick", { selectElementPick() })) }
        if !hiddenClasses.contains("people") {
            picks += participantSuggestions.map { s in ("p:\(s.id)", { selectParticipantSuggestion(s) }) }
            picks += teammateSuggestions.map { s in ("t:\(s.id)", { selectTeammateSuggestion(s) }) }
        }
        if !hiddenClasses.contains("chats") {
            picks += chatSuggestions.map { s in ("c:\(s.id)", { selectChatSuggestion(s) }) }
        }
        if !hiddenClasses.contains("repo") {
            picks += branchSuggestions.map { s in ("b:\(s.id)", { selectBranchSuggestion(s) }) }
        }
        if !hiddenClasses.contains("files") {
            picks += fileSuggestions.map { s in ("f:\(s.id)", { selectFileSuggestion(s) }) }
        }
        picks += elementSuggestions.map { s in ("e:\(s.id)", { selectElementSuggestion(s) }) }
        return picks
    }

    /// A hardware key while the @ list is open: the arrows move the highlight,
    /// Return and Tab pick it, Escape closes the list.
    private func handleSuggestionKey(_ key: ChatTextView.SuggestionKey) {
        let picks = atPicks
        switch key {
        case .up, .down:
            guard !picks.isEmpty else { return }
            let step = key == .up ? -1 : 1
            atHighlight = (min(atHighlight, picks.count - 1) + step + picks.count) % picks.count
        case .pick:
            guard picks.indices.contains(atHighlight) else { dismissAtOverlay(); return }
            picks[atHighlight].select()
        case .dismiss:
            dismissAtOverlay()
        }
    }

    /// Marks the highlighted row and gives it an id to scroll to.
    private func atRow<Row: View>(_ id: String, highlighted: String?, @ViewBuilder _ row: () -> Row) -> some View {
        row()
            .background(id == highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
            .id(id)
    }

    private var unifiedSuggestionsOverlay: some View {
        let picks = atPicks
        let highlighted = picks.indices.contains(atHighlight) ? picks[atHighlight].id : nil
        return VStack(spacing: 0) {
            classToggleRow
            let peopleShown = !participantSuggestions.isEmpty && !hiddenClasses.contains("people")
            let teamShown = !teammateSuggestions.isEmpty && !hiddenClasses.contains("people")
            let chatsShown = (!chatSuggestions.isEmpty || chatsLoading) && !hiddenClasses.contains("chats")
            let branchesShown = !branchSuggestions.isEmpty && !hiddenClasses.contains("repo")
            let filesShown = !fileSuggestions.isEmpty && !hiddenClasses.contains("files")
            let hasResults = elementPickShown || peopleShown || teamShown || chatsShown || branchesShown || filesShown || !elementSuggestions.isEmpty
            if !hasResults {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 20)
                    Text(hiddenClasses.contains("people") && hiddenClasses.contains("chats") && hiddenClasses.contains("repo") && hiddenClasses.contains("files") && elementSuggestions.isEmpty ? "All classes hidden — use the toggles above" : (afterAtText.isEmpty ? "Search chats, people, branches, files, and UI elements" : "No matches for \u{201C}\(afterAtText)\u{201D}"))
                        .font(.ripul(size: 14))
                        .foregroundStyle(.ripul(.textSecondary))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if elementPickShown {
                            suggestionSectionHeader("Element")
                            atRow("pick", highlighted: highlighted) { elementPickRow }
                            if peopleShown || teamShown || chatsShown || branchesShown || filesShown || !elementSuggestions.isEmpty {
                                Divider()
                            }
                        }
                        if peopleShown {
                            suggestionSectionHeader("People")
                            ForEach(participantSuggestions) { suggestion in
                                atRow("p:\(suggestion.id)", highlighted: highlighted) { participantRow(suggestion) }
                                if suggestion.id != participantSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if teamShown {
                            if peopleShown {
                                Divider()
                            }
                            suggestionSectionHeader("Team")
                            ForEach(teammateSuggestions) { suggestion in
                                atRow("t:\(suggestion.id)", highlighted: highlighted) { teammateRow(suggestion) }
                                if suggestion.id != teammateSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if chatsShown {
                            if peopleShown || teamShown { Divider() }
                            suggestionSectionHeader("Chats")
                            if chatsLoading { ProgressView().padding(8) }
                            ForEach(chatSuggestions) { suggestion in
                                atRow("c:\(suggestion.id)", highlighted: highlighted) { chatRow(suggestion) }
                                if suggestion.id != chatSuggestions.last?.id { Divider().padding(.leading, 40) }
                            }
                        }
                        if branchesShown {
                            if peopleShown || teamShown {
                                Divider()
                            }
                            suggestionSectionHeader("Branches")
                            ForEach(branchSuggestions) { suggestion in
                                atRow("b:\(suggestion.id)", highlighted: highlighted) { branchRow(suggestion) }
                                if suggestion.id != branchSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if filesShown {
                            if peopleShown || teamShown || chatsShown || branchesShown {
                                Divider()
                            }
                            suggestionSectionHeader("Files")
                            ForEach(fileSuggestions) { suggestion in
                                atRow("f:\(suggestion.id)", highlighted: highlighted) { fileRow(suggestion) }
                                if suggestion.id != fileSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if !elementSuggestions.isEmpty {
                            if peopleShown || teamShown || chatsShown || branchesShown || filesShown {
                                Divider()
                            }
                            suggestionSectionHeader("UI Elements")
                            ForEach(elementSuggestions) { suggestion in
                                atRow("e:\(suggestion.id)", highlighted: highlighted) { elementRow(suggestion) }
                                if suggestion.id != elementSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .onChange(of: highlighted) { id in
                    if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                }
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.ripul(system: .black).opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    private func suggestionSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.ripul(size: 11, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
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
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if let group = suggestion.group, !group.isEmpty {
                        Text(group)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
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

    private var elementPickRow: some View {
        Button {
            selectElementPick()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick an element")
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    Text("Choose it on screen with View Explorer")
                        .font(.ripul(size: 11))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
                Spacer()
                Text("Pick")
                    .font(.ripul(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("NativeChatInput.at.element")
    }

    private func teammateRow(_ suggestion: TeammateSuggestion) -> some View {
        Button {
            selectTeammateSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    Text(suggestion.description ?? "Invite to this chat")
                        .font(.ripul(size: 11))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
                Spacer()
                Text("Invite")
                    .font(.ripul(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("NativeChatInput.at.teammate")
    }

    /// One line above the field, gone after a few seconds: what happened to
    /// the invitation the last teammate pick sent.
    private func atNoticeBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.ripul(.textSecondary))
            Text(message)
                .font(.ripul(size: 12))
                .foregroundStyle(.ripul(.textSecondary))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("NativeChatInput.at.notice")
    }

    private func showAtNotice(_ message: String) {
        atNoticeTask?.cancel()
        withAnimation { atNotice = message }
        atNoticeTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { atNotice = nil } }
        }
    }

    private func fileRow(_ suggestion: FileSuggestion) -> some View {
        Button {
            selectFileSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.isDirectory ? "folder.fill" : (AutocompleteConstants.category(for: "files")?.sfSymbol ?? "doc.text.fill"))
                    .foregroundStyle(suggestion.isDirectory ? Color.ripul(.info) : Color.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.fileName)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if suggestion.path != suggestion.fileName {
                        Text(suggestion.path)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
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
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.componentName)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if suggestion.dataUi != suggestion.componentName {
                        Text(suggestion.dataUi)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
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
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 20)
                    Text(slashCommandsLoaded
                         ? (slashFilter.isEmpty ? "No commands available" : "No commands matching \u{201C}\(slashFilter)\u{201D}")
                         : "Loading commands…")
                        .font(.ripul(size: 14))
                        .foregroundStyle(.ripul(.textSecondary))
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
        .shadow(color: Color.ripul(system: .black).opacity(0.15), radius: 8, y: -2)
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
                            .font(.ripulIcon(size: 12, weight: .semibold))
                            .foregroundStyle(.ripul(.textSecondary))
                            .frame(width: 20)
                        Text("/\(command.command)")
                            .font(.ripul(size: 14, weight: .semibold))
                            .foregroundStyle(.ripul(.text))
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
                                .font(.ripulIcon(size: 12))
                                .foregroundStyle(.ripul(.textSecondary))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.ripul(size: 14, weight: .medium))
                                    .foregroundStyle(.ripul(.text))
                                    .lineLimit(1)
                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.ripul(size: 11))
                                        .foregroundStyle(.ripul(.textSecondary))
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
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("/\(command.command)")
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    Text(command.description)
                        .font(.ripul(size: 11))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
                Spacer()
                if !command.options.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.ripulIcon(size: 12))
                        .foregroundStyle(.ripul(.textSecondary))
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
            HStack(alignment: .bottom, spacing: 8 * (1 - composerCollapse)) {
                if !BundledAgentRuntime.isEnabled { plusMenuButton.modifier(ComposerFold(horizontal: true)) }

                // Group adjacent glass surfaces so they share the same sampling region.
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ComposerContextChips(store: contextStore, session: contextSessionID)
                        if let replyTarget {
                            ReplyTargetStrip(target: replyTarget, onCancel: onCancelReply)
                        }
                        if !imageAttachments.isEmpty { imageThumbsRow }
                    }.modifier(ComposerFold())
                    HStack(spacing: 4 * (1 - composerCollapse)) {

                        textInputView
                        if !BundledAgentRuntime.isEnabled { ComposerContextButton(store: contextStore, session: contextSessionID, options: contextOptions, size: 36).modifier(ComposerFold(horizontal: true)) }
                        if dictationAvailable {
                            micButton(size: 36).modifier(ComposerFold(horizontal: true))
                        }
                        actionButton.modifier(ComposerFold(horizontal: true))
                    }
                }
                .padding(.vertical, 6 * composerCollapse)
                .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
                .modifier(WaitingGlowModifier(isActive: agentWaiting))

                historyMenuButton.modifier(ComposerFold(horizontal: true))
            }
        }
    }

    // MARK: - Two Row Layout (buttons below text area)

    private var twoRowBody: some View {
        ChatInputGlassGroup {
            VStack(spacing: 6 * (1 - composerCollapse)) {
                // Full-width text area
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ComposerContextChips(store: contextStore, session: contextSessionID)
                        if let replyTarget {
                            ReplyTargetStrip(target: replyTarget, onCancel: onCancelReply)
                        }
                        if !imageAttachments.isEmpty { imageThumbsRow }
                    }.modifier(ComposerFold())
                    textInputView
                        .padding(.trailing, 8)
                }

                // Buttons row below (inside the shared glass bounding box)
                HStack(spacing: 8) {
                    if !BundledAgentRuntime.isEnabled { plusMenuButton }
                    historyMenuButton

                    ComposerContextButton(store: contextStore, session: contextSessionID, options: contextOptions, size: 40)
                    if dictationAvailable {
                        micButton(size: 40)
                    }
                    Spacer()
                    twoRowActionButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .modifier(ComposerFold())
            }
            .padding(.vertical, 6 * composerCollapse)
            .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
            .modifier(WaitingGlowModifier(isActive: agentWaiting))
        }
    }

    // MARK: - Shared Subviews

    private var plusMenuButton: some View {
        Menu { MenuIcons {
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
            // PDFs, Word, PowerPoint, spreadsheets, code and other text, and
            // images kept as files (FileAttachmentHelper).
            Button {
                dismissKeyboard()
                showFilePicker = true
            } label: {
                #if targetEnvironment(macCatalyst)
                Label("Choose Files…", systemImage: "doc")
                #else
                Label("Files", systemImage: "doc")
                #endif
            }
            if onFetchTodoItems != nil {
                Button {
                    dismissKeyboard()
                    showTodoPicker = true
                } label: {
                    Label("Pick to do", systemImage: "list.bullet.clipboard")
                }
            }
            if let onAddArtefact {
                Button(action: onAddArtefact) { Label("Artefact", systemImage: "square.stack.3d.up") }
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
        }} label: {
            Image(systemName: "plus")
                .font(.ripulIcon(size: 20, weight: .medium))
                .foregroundStyle(.ripul(.text))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
        }
        #if targetEnvironment(macCatalyst)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help("Attachments and actions")
        #endif
        .accessibilityLabel("Attachments and actions")
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                onPlusLongPress?()
            }
        )
    }

    private var agentWaiting: Bool {
        isAgentRunning && !isAgentPaused && conversationMode != "group"
    }

    // Matches ChatTextView's font so the shimmer overlay sits exactly where
    // the UIKit placeholder label would.
    private var placeholderFont: Font {
        .ripul(size: UIFont.ripul(.body).pointSize + 1, weight: .semibold)
    }

    /// Up recalls history only at the start of a message: a single line, or a
    /// recalled message still unedited (so a multi-line one can be stepped
    /// past). Once the user's own text runs to a second line, the arrows move
    /// the caret. Down only steps back toward the draft while browsing.
    private func canRecallHistory(up: Bool, singleLine: Bool) -> Bool {
        guard let history = messageHistory, history.hasMessages else { return false }
        let showingRecalled = history.browsingEntry == text
        return up ? singleLine || showingRecalled : showingRecalled
    }

    private func recallHistory(up: Bool) {
        guard let history = messageHistory else { return }
        // An edited recall is the user's text now: keep it as the draft that
        // Down returns to, rather than continuing from the old position.
        if let entry = history.browsingEntry, entry != text { history.resetCursor() }
        if history.browsingEntry == nil { historyDraftAttachments = imageAttachments }
        if let recalled = up ? history.navigateUp(currentText: text) : history.navigateDown() {
            text = recalled
            imageAttachments = history.recalledAttachments.map(NativeImageAttachment.restore) ?? historyDraftAttachments
        }
    }

    private var textInputView: some View {
        NoAutofillTextView(
            text: $text,
            height: $textHeight,
            // While waiting, the UIKit placeholder is blanked and the
            // shimmering SwiftUI overlay below renders the copy instead.
            placeholder: agentWaiting ? "" : conversationMode == "group" ? "Message the group · @Agent to ask" : isAgentPaused ? "Agent is paused, add new instruction…" : "Message...",
            onSubmit: {
                // This callback is a hardware-keyboard command (including
                // iPhone Mirroring). Keep focus for the next message. The
                // onscreen Return inserts a newline; Send buttons dismiss.
                submitMessage()
            },
            onTextChange: { newText in
                onTypingChange?(!newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if newText.isEmpty {
                    dismissAtOverlay()
                    dismissSlashOverlay()
                } else {
                    handleAtDetection(newText)
                    handleSlashDetection(newText)
                }
            },
            onFocusChanged: { focused in
                composerFocused = focused
                if !focused { onTypingChange?(false) }
                if focused { composerChrome?.requestExpand?() }
                onFocusChanged?(focused)
            },
            onPasteImages: { images in
                let attachments = images.compactMap { PhotoAttachmentHelper.makeAttachment(from: $0) }
                guard !attachments.isEmpty else { return false }
                imageAttachments.append(contentsOf: attachments)
                return true
            },
            onDropFiles: { attachDroppedFiles($0) },
            canRecallHistory: messageHistory == nil ? nil : { up, singleLine in
                canRecallHistory(up: up, singleLine: singleLine)
            },
            onRecallHistory: { up in recallHistory(up: up) },
            suggestionsOpen: showAtSuggestions,
            onSuggestionKey: { handleSuggestionKey($0) },
            freezesHeight: composerCollapse > 0
        )
        .frame(maxWidth: .infinity, minHeight: textHeight + (36 - textHeight) * composerCollapse, maxHeight: textHeight + (36 - textHeight) * composerCollapse, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if agentWaiting && text.isEmpty {
                Text("Waiting on agent…").ripulText()
                    .font(placeholderFont)
                    .ripulShimmer(base: Color.ripul(system: .placeholderText))
                    .padding(.leading, 12)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty || !contextStore.attachments(for: contextSessionID).isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent {
                    ComposerActionButtons(actions: composerActions, pending: composerActionPending, onAction: onComposerAction)
                }
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
                        .font(.ripulIcon(size: 16, weight: .bold))
                        .foregroundStyle(.ripul(.warning))
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
                        .font(.ripulIcon(size: 16, weight: .bold))
                        .foregroundStyle(.ripul(.success))
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
                        .accessibilityLabel("Send message")
                        .font(.ripulIcon(size: 16, weight: .bold))
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
                .font(.ripulIcon(size: size == 40 ? 18 : 16, weight: .bold))
                .foregroundStyle(.ripul(system: .systemPurple))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .modifier(GlassCircleModifier(glassStyle: glassStyle))
        }
    }

    // Send-to-agent button shown while a turn is running (when there's typed
    // content). Routes onSubmit -> bridge.submitMessage -> __ripulSubmitMessage.
    // The web app hands it to the running task at its next step where the agent
    // can take one (steering, logging/utils/midTaskSend.ts), else FIFO-queues it
    // for CLI sessions (or injects it as mid-run context for in-process agents).
    // The composer action "After this task" is the explicit wait.
    private func sendButton(size: CGFloat, glassStyle: String?) -> some View {
        Button {
            dismissKeyboard()
            submitMessage()
        } label: {
            Image(systemName: "arrow.up")
                        .accessibilityLabel(runningSendLabel)
                .font(.ripulIcon(size: size == 40 ? 18 : 16, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .modifier(GlassCircleModifier(glassStyle: glassStyle))
        }
        .help(runningSendLabel)
        .disabled(composerActionPending)
    }

    @ViewBuilder
    private var twoRowActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty || !contextStore.attachments(for: contextSessionID).isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent {
                    ComposerActionButtons(actions: composerActions, pending: composerActionPending, onAction: onComposerAction)
                }
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
                        .font(.ripulIcon(size: 18, weight: .bold))
                        .foregroundStyle(.ripul(.warning))
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
                        .font(.ripulIcon(size: 18, weight: .bold))
                        .foregroundStyle(.ripul(.success))
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
                        .accessibilityLabel("Send message")
                        .font(.ripulIcon(size: 18, weight: .bold))
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
                    .font(.ripulIcon(size: 18, weight: .medium))
                    .foregroundStyle(.ripul(.text))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
            }
            .ripulSheet(isPresented: $showHistorySheet) {
                HistorySheet(history: history) { msg in
                    text = msg.text
                    imageAttachments = NativeImageAttachment.restore(history.attachments(for: msg))
                    history.resetCursor()
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
                        if attachment.isImage {
                            Image(uiImage: attachment.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            fileChip(attachment)
                        }

                        Button {
                            imageAttachments.removeAll { $0.id == attachment.id }
                            selectedPhotos = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.ripulIcon(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.ripul(system: .white), .ripul(.neutral))
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

    /// A file other than a photo: its symbol and its name, as tall as a thumbnail.
    private func fileChip(_ attachment: NativeImageAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: FileAttachmentHelper.symbolName(for: attachment.mediaType, name: attachment.name))
                .font(.ripulIcon(size: 20))
                .foregroundStyle(.ripul(.textSecondary))
            Text(attachment.name ?? "File")
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.text))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 8)
        .frame(width: 140, height: 56, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.ripul(system: .secondarySystemBackground)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attached file \(attachment.name ?? "")")
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
    var onTypingChange: ((Bool) -> Void)?
    @ObservedObject var contextStore: RipulComposerContextStore
    var contextSessionID: String?
    var contextOptions: [RipulComposerContext]
    /// Send a human note (not sent to agent, for human-to-human communication).
    var onSubmitNote: (() -> Void)?
    var conversationMode: String
    /// The message being replied to, shown above the field until sent or cancelled.
    var replyTarget: RipulReplyTarget?
    var onCancelReply: (() -> Void)?
    var runningSendLabel: String
    var composerActions: [RipulComposerAction]
    var composerActionPending: Bool
    var onComposerAction: ((String) -> Void)?
    let onPause: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onQuickCommands: (() -> Void)?
    let onAddArtefact: (() -> Void)?
    let onAddTodoItem: (() -> Void)?
    /// Fetches the user's todo items (with current-chat id for grouping) when
    /// the "Pick to do" menu entry is tapped. A selected todo's text is appended
    /// to this view's own `$text` binding — the native composer is the source
    /// of truth, not the hidden web composer.
    let onFetchTodoItems: (() async -> RipulTodoItemsResult)?
    var messageHistory: MessageHistory?
    var chatInputGlassStyle: String?
    var chatInputLayout: String?
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
    var onQueryChats: ((String) async -> [ChatSuggestion])?
    var onQueryBranches: ((String) async -> [BranchSuggestion])?
    /// Optional callback to fetch teammates not yet in this chat. When provided,
    /// the `@` overlay shows a "Team" section under People; picking one inserts
    /// the mention and hands the row to `onInviteTeammate`.
    var onQueryTeammates: (() async -> [TeammateSuggestion])?
    /// Invite a picked teammate into the chat. Returns a user-facing error, or nil.
    var onInviteTeammate: ((TeammateSuggestion) async -> String?)?
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
    @State private var microphoneWarning: String?
    @State private var showPhotoPicker = false
    @FocusState private var isFocused: Bool
    @State private var fileSuggestions: [FileSuggestion] = []
    @State private var fileQueryTask: Task<Void, Never>?
    /// The character index where the `@` trigger was typed
    @State private var atTriggerIndex: String.Index?
    @State private var showHistorySheet = false
    @State private var historyDraftAttachments: [NativeImageAttachment] = []
    @State private var showTodoPicker = false
    @State private var showAtSuggestions = false
    @State private var allElementSuggestions: [ElementSuggestion] = []
    @State private var elementSuggestions: [ElementSuggestion] = []
    @State private var allParticipantSuggestions: [ParticipantSuggestion] = []
    @State private var participantSuggestions: [ParticipantSuggestion] = []
    @State private var branchSuggestions: [BranchSuggestion] = []
    @State private var allBranchSuggestions: [BranchSuggestion] = []
    @State private var chatSuggestions: [ChatSuggestion] = []
    @State private var chatQueryTask: Task<Void, Never>?
    @State private var chatsLoading = false
    @State private var allTeammateSuggestions: [TeammateSuggestion] = []
    @State private var teammateSuggestions: [TeammateSuggestion] = []
    /// Outcome of the last teammate invitation, shown briefly above the field.
    @State private var atNotice: String?
    @State private var atNoticeTask: Task<Void, Never>?
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
        onTypingChange: ((Bool) -> Void)? = nil,
        onSubmitNote: (() -> Void)? = nil,
        conversationMode: String = "agent",
        replyTarget: RipulReplyTarget? = nil,
        onCancelReply: (() -> Void)? = nil,
        runningSendLabel: String = "Send",
        composerActions: [RipulComposerAction] = [],
        composerActionPending: Bool = false,
        onComposerAction: ((String) -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        onNewChat: (() -> Void)? = nil,
        onQuickCommands: (() -> Void)? = nil,
        onAddArtefact: (() -> Void)? = nil,
        onAddTodoItem: (() -> Void)? = nil,
        onFetchTodoItems: (() async -> RipulTodoItemsResult)? = nil,
        messageHistory: MessageHistory? = nil,
        chatInputGlassStyle: String? = nil,
        chatInputLayout: String? = nil,
        onQueryFiles: ((String) async -> [FileSuggestion])? = nil,
        onQueryElements: (() async -> [ElementSuggestion])? = nil,
        onQueryParticipants: (() async -> [ParticipantSuggestion])? = nil,
        onQueryTeammates: (() async -> [TeammateSuggestion])? = nil,
        onInviteTeammate: ((TeammateSuggestion) async -> String?)? = nil,
        onQueryChats: ((String) async -> [ChatSuggestion])? = nil,
        onQueryBranches: ((String) async -> [BranchSuggestion])? = nil,
        addressedParticipants: Binding<[String]> = .constant([]),
        onFocusChanged: ((Bool) -> Void)? = nil,
        speechProvider: Any? = nil,
        onEnterVoiceMode: ((Bool) -> Bool)? = nil,
        contextStore: RipulComposerContextStore? = nil,
        contextSessionID: String? = nil,
        contextOptions: [RipulComposerContext] = RipulComposerContext.standard
    ) {
        self._text = text
        self._imageAttachments = imageAttachments
        self._selectedPhotos = selectedPhotos
        self.isAgentRunning = isAgentRunning
        self.isAgentPaused = isAgentPaused
        self.onSubmit = onSubmit
        self.onTypingChange = onTypingChange
        self.onSubmitNote = onSubmitNote
        self.conversationMode = conversationMode
        self.replyTarget = replyTarget
        self.onCancelReply = onCancelReply
        self.runningSendLabel = runningSendLabel
        self.composerActions = composerActions
        self.composerActionPending = composerActionPending
        self.onComposerAction = onComposerAction
        self.onPause = onPause
        self.onNewChat = onNewChat
        self.onQuickCommands = onQuickCommands
        self.onAddArtefact = onAddArtefact
        self.onAddTodoItem = onAddTodoItem
        self.onFetchTodoItems = onFetchTodoItems
        self.messageHistory = messageHistory
        self.chatInputGlassStyle = chatInputGlassStyle
        self.chatInputLayout = chatInputLayout
        self.onQueryFiles = onQueryFiles
        self.onQueryElements = onQueryElements
        self.onQueryParticipants = onQueryParticipants
        self.onQueryChats = onQueryChats
        self.onQueryBranches = onQueryBranches
        self.onQueryTeammates = onQueryTeammates
        self.onInviteTeammate = onInviteTeammate
        self._addressedParticipants = addressedParticipants
        self.onFocusChanged = onFocusChanged
        self.speechProvider = speechProvider
        self.onEnterVoiceMode = onEnterVoiceMode
        self.contextStore = contextStore ?? RipulComposerContextStore()
        self.contextSessionID = contextSessionID
        self.contextOptions = contextOptions
    }

    // MARK: - @ Mention Suggestions

    /// Detect `@` followed by typing and populate a single ranked suggestion list
    /// (participants first, then files, then UI elements).
    private func handleAtDetection(_ value: String) {
        guard onQueryFiles != nil || onQueryElements != nil || onQueryParticipants != nil || onQueryBranches != nil || onQueryChats != nil || onQueryTeammates != nil else { return }

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

        if afterAt.contains("\n") || afterAt.count > 120 || (afterAt.contains(" ") && !showAtSuggestions) || contextAliases.keys.contains(where: { afterAt.hasPrefix(String($0.dropFirst()) + " ") }) {
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
            if !hiddenClasses.contains("people"), let queryTeammates = onQueryTeammates {
                Task {
                    let results = await queryTeammates()
                    await MainActor.run {
                        allTeammateSuggestions = results
                        teammateSuggestions = filterTeammates(by: afterAt, all: results)
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
            teammateSuggestions = filterTeammates(by: afterAt, all: allTeammateSuggestions)
            branchSuggestions = filterBranches(by: afterAt, all: allBranchSuggestions)
            elementSuggestions = filterElements(by: afterAt, all: allElementSuggestions)
        }

        // Re-query the complete catalogue for each search, not just the initial
        // recent page. Cancellation prevents an old query replacing new results.
        chatQueryTask?.cancel()
        if !hiddenClasses.contains("chats"), let queryChats = onQueryChats {
            chatsLoading = true
            chatQueryTask = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                let results = await queryChats(afterAt)
                guard !Task.isCancelled, showAtSuggestions else { return }
                chatSuggestions = results
                chatsLoading = false
            }
        } else { chatsLoading = false; chatSuggestions = [] }

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

    private func filterTeammates(by query: String, all: [TeammateSuggestion]) -> [TeammateSuggestion] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
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
        teammateSuggestions = []
        allTeammateSuggestions = []
        branchSuggestions = []
        allBranchSuggestions = []
        chatSuggestions = []
        chatsLoading = false
        chatQueryTask?.cancel()
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

    /// A person's name as an @ token. A mention ends at the first space, so
    /// "Sandsend Retreats" went out as "@Sandsend Retreats" and only "Sandsend"
    /// was drawn as the mention. The web composer flattens spaces to `_` and
    /// the message renderer turns them back (participantMentions.ts).
    static func mentionToken(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }

    private func selectParticipantSuggestion(_ suggestion: ParticipantSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + Self.mentionToken(suggestion.name) + " "
        } else {
            text += "@" + Self.mentionToken(suggestion.name) + " "
        }
        if !addressedParticipants.contains(suggestion.id) {
            addressedParticipants.append(suggestion.id)
        }
        dismissAtOverlay()
    }

    private func selectTeammateSuggestion(_ suggestion: TeammateSuggestion) {
        if let triggerIdx = atTriggerIndex {
            let before = String(text[text.startIndex..<triggerIdx])
            text = before + "@" + Self.mentionToken(suggestion.name) + " "
        } else {
            text += "@" + Self.mentionToken(suggestion.name) + " "
        }
        if !addressedParticipants.contains(suggestion.id) {
            addressedParticipants.append(suggestion.id)
        }
        dismissAtOverlay()
        guard let onInviteTeammate else { return }
        let who = suggestion.name.replacingOccurrences(of: "_", with: " ")
        Task {
            let error = await onInviteTeammate(suggestion)
            await MainActor.run {
                showAtNotice(error.map { "Couldn't invite \(who): \($0)" } ?? "Invited \(who) to this chat")
            }
        }
    }

    private func selectChatSuggestion(_ suggestion: ChatSuggestion) {
        // Keep two chats with the same title independently addressable.
        let alias = ContextMentionAliasing.uniqueAlias(for: suggestion.name, token: suggestion.token, aliases: contextAliases)
        contextAliases[alias] = suggestion.token
        if let triggerIdx = atTriggerIndex {
            text = String(text[text.startIndex..<triggerIdx]) + alias + " "
        } else { text += alias + " " }
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
        onTypingChange?(false)
        guard !composerActionPending else { return }
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
        if key == "chats" { handleAtDetection(text) }
    }

    /// Fast show/hide chips for whole classes of suggestions, pinned atop the
    /// overlay. Persistence mirrors the web composer's atMenuClassToggles.
    private var classToggleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
            ForEach(AtClassToggleSpec.all) { spec in
                Button {
                    toggleClass(spec.key)
                } label: {
                    Label(spec.label, systemImage: spec.icon)
                        .font(.ripul(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(hiddenClasses.contains(spec.key) ? Color.clear : Color.accentColor.opacity(0.18)))
                        .overlay(Capsule().stroke(hiddenClasses.contains(spec.key) ? Color.ripul(.textSecondary).opacity(0.35) : Color.accentColor, lineWidth: 1))
                        .foregroundStyle(hiddenClasses.contains(spec.key) ? Color.ripul(.textSecondary) : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        }
    }

    private func chatRow(_ suggestion: ChatSuggestion) -> some View {
        Button { selectChatSuggestion(suggestion) } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.ripul(.textSecondary)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name).font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text)).lineLimit(2)
                    if let description = suggestion.description {
                        Text(description).font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary)).lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Composer.chatSuggestion")
    }

    private func branchRow(_ suggestion: BranchSuggestion) -> some View {
        Button {
            selectBranchSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if let description = suggestion.description, !description.isEmpty {
                        Text(description)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if suggestion.remote {
                    Image(systemName: "cloud")
                        .font(.ripulIcon(size: 11))
                        .foregroundStyle(.ripul(.textSecondary))
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
            let teamShown = !teammateSuggestions.isEmpty && !hiddenClasses.contains("people")
            let chatsShown = (!chatSuggestions.isEmpty || chatsLoading) && !hiddenClasses.contains("chats")
            let branchesShown = !branchSuggestions.isEmpty && !hiddenClasses.contains("repo")
            let filesShown = !fileSuggestions.isEmpty && !hiddenClasses.contains("files")
            let hasResults = peopleShown || teamShown || chatsShown || branchesShown || filesShown || !elementSuggestions.isEmpty
            if !hasResults {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 20)
                    Text(hiddenClasses.contains("people") && hiddenClasses.contains("chats") && hiddenClasses.contains("repo") && hiddenClasses.contains("files") && elementSuggestions.isEmpty ? "All classes hidden — use the toggles above" : (afterAtText.isEmpty ? "Search chats, people, branches, files, and UI elements" : "No matches for \u{201C}\(afterAtText)\u{201D}"))
                        .font(.ripul(size: 14))
                        .foregroundStyle(.ripul(.textSecondary))
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
                        if teamShown {
                            if peopleShown {
                                Divider()
                            }
                            suggestionSectionHeader("Team")
                            ForEach(teammateSuggestions) { suggestion in
                                teammateRow(suggestion)
                                if suggestion.id != teammateSuggestions.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        if chatsShown {
                            if peopleShown || teamShown { Divider() }
                            suggestionSectionHeader("Chats")
                            if chatsLoading { ProgressView().padding(8) }
                            ForEach(chatSuggestions) { suggestion in
                                chatRow(suggestion)
                                if suggestion.id != chatSuggestions.last?.id { Divider().padding(.leading, 40) }
                            }
                        }
                        if branchesShown {
                            if peopleShown || teamShown {
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
                            if peopleShown || teamShown || chatsShown || branchesShown {
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
                            if peopleShown || teamShown || chatsShown || branchesShown || filesShown {
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
        .shadow(color: Color.ripul(system: .black).opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 16)
    }

    private func suggestionSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.ripul(size: 11, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
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
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if let group = suggestion.group, !group.isEmpty {
                        Text(group)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
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

    private func teammateRow(_ suggestion: TeammateSuggestion) -> some View {
        Button {
            selectTeammateSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    Text(suggestion.description ?? "Invite to this chat")
                        .font(.ripul(size: 11))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
                Spacer()
                Text("Invite")
                    .font(.ripul(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("NativeChatInput.at.teammate")
    }

    /// One line above the field, gone after a few seconds: what happened to
    /// the invitation the last teammate pick sent.
    private func atNoticeBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.ripul(.textSecondary))
            Text(message)
                .font(.ripul(size: 12))
                .foregroundStyle(.ripul(.textSecondary))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("NativeChatInput.at.notice")
    }

    private func showAtNotice(_ message: String) {
        atNoticeTask?.cancel()
        withAnimation { atNotice = message }
        atNoticeTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { atNotice = nil } }
        }
    }

    private func fileRow(_ suggestion: FileSuggestion) -> some View {
        Button {
            selectFileSuggestion(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.isDirectory ? "folder.fill" : (AutocompleteConstants.category(for: "files")?.sfSymbol ?? "doc.text.fill"))
                    .foregroundStyle(suggestion.isDirectory ? Color.ripul(.info) : Color.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.fileName)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if suggestion.path != suggestion.fileName {
                        Text(suggestion.path)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
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
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.componentName)
                        .font(.ripul(size: 14, weight: .medium))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(1)
                    if suggestion.dataUi != suggestion.componentName {
                        Text(suggestion.dataUi)
                            .font(.ripul(size: 11))
                            .foregroundStyle(.ripul(.textSecondary))
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
            } else if let atNotice {
                atNoticeBanner(atNotice)
                    .offset(y: -8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: imageAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isAgentRunning)
        .onChange(of: contextSessionID) { _ in
            dismissAtOverlay()
        }
        .animation(.easeInOut(duration: 0.2), value: isTwoRow)
        .onChange(of: text) { newValue in
            if newValue.isEmpty { messageHistory?.composerModality = "keyboard" }
            if isDictating && newValue.isEmpty {
                dictationBase = ""
            }
            collapseIncomingContextTokens(newValue)
        }
        .animation(.easeInOut(duration: 0.2), value: showAtSuggestions)
        .modifier(SpeechInputWarningModifier(message: $microphoneWarning))
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .ripulSheet(isPresented: $showTodoPicker) {
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
            if !focused { onTypingChange?(false) }
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
            if let history = messageHistory, history.browsingEntry == nil { historyDraftAttachments = imageAttachments }
            if let history = messageHistory,
               let previous = history.navigateUp(currentText: text) {
                text = previous
                imageAttachments = history.recalledAttachments.map(NativeImageAttachment.restore) ?? historyDraftAttachments
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if let history = messageHistory,
               let next = history.navigateDown() {
                text = next
                imageAttachments = history.recalledAttachments.map(NativeImageAttachment.restore) ?? historyDraftAttachments
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
                        messageHistory?.composerModality = "voice"
                        text = dictationBase.isEmpty ? partial : dictationBase + " " + partial
                    case .committed(let segment):
                        messageHistory?.composerModality = "voice"
                        dictationBase = dictationBase.isEmpty ? segment : dictationBase + " " + segment
                        text = dictationBase
                    case .audioLevel, .connectionReady, .recovery:
                        break
                    case .error, .audioGap:
                        break
                    case .ended:
                        isDictating = false
                    }
                }
                isDictating = true
            } catch {
                isDictating = false
                microphoneWarning = error.localizedDescription
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
            .font(.ripulIcon(size: size == 40 ? 18 : 16, weight: .bold))
            .foregroundStyle(isDictating ? Color.ripul(.danger) : Color.accentColor)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .modifier(GlassCircleModifier(glassStyle: "clear"))
            .gesture(longPress.exclusively(before: doubleTap.exclusively(before: singleTap)))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Microphone")
            .accessibilityIdentifier("NativeChatInput.microphone")
    }

    private var singleRowBody: some View {
        ChatInputGlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                if !BundledAgentRuntime.isEnabled { plusMenuButton }

                VStack(spacing: 0) {
                    ComposerContextChips(store: contextStore, session: contextSessionID)
                    if let replyTarget {
                        ReplyTargetStrip(target: replyTarget, onCancel: onCancelReply)
                    }
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    HStack(spacing: 4) {

                        textInputView
                        if !BundledAgentRuntime.isEnabled { ComposerContextButton(store: contextStore, session: contextSessionID, options: contextOptions, size: 36) }
                        if dictationAvailable {
                            micButton(size: 36)
                        }
                        actionButton
                    }
                }
                .frame(minHeight: 40)
                .modifier(GlassChatInputBackground(glassStyle: resolvedChatInputGlassStyle))
                .modifier(WaitingGlowModifier(isActive: agentWaiting))

                historyMenuButton
            }
        }
    }

    // MARK: - Two Row Layout (buttons below text area)

    private var twoRowBody: some View {
        ChatInputGlassGroup {
            VStack(spacing: 6) {
                VStack(spacing: 0) {
                    ComposerContextChips(store: contextStore, session: contextSessionID)
                    if let replyTarget {
                        ReplyTargetStrip(target: replyTarget, onCancel: onCancelReply)
                    }
                    if !imageAttachments.isEmpty {
                        imageThumbsRow
                    }
                    textInputView
                        .padding(.trailing, 8)
                }
                .frame(minHeight: 40)

                // Buttons row below (inside the shared glass bounding box)
                HStack(spacing: 8) {
                    if !BundledAgentRuntime.isEnabled { plusMenuButton }
                    historyMenuButton

                    ComposerContextButton(store: contextStore, session: contextSessionID, options: contextOptions, size: 40)
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
            .modifier(WaitingGlowModifier(isActive: agentWaiting))
        }
    }

    // MARK: - Shared Subviews

    private var plusMenuButton: some View {
        Menu { MenuIcons {
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
            if let onAddArtefact {
                Button(action: onAddArtefact) { Label("Artefact", systemImage: "square.stack.3d.up") }
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
        }} label: {
            Image(systemName: "plus")
                .font(.ripulIcon(size: 20, weight: .medium))
                .foregroundStyle(.ripul(.textSecondary))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 40, height: 40)
        .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
    }

    private var agentWaiting: Bool {
        isAgentRunning && !isAgentPaused && conversationMode != "group"
    }

    private var textInputView: some View {
        // While waiting, the TextField placeholder is blanked and the
        // shimmering overlay below renders the copy instead.
        TextField(agentWaiting ? "" : conversationMode == "group" ? "Message the group · @Agent to ask" : isAgentPaused ? "Agent is paused, add new instruction…" : "Message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.leading, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .leading) {
                if agentWaiting && text.isEmpty {
                    Text("Waiting on agent…").ripulText()
                        .ripulShimmer(base: Color(nsColor: .placeholderTextColor))
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
            .onSubmit {
                submitMessage()
            }
            .onChange(of: text) { newValue in
                if isFocused { onTypingChange?(!newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                handleAtDetection(newValue)
            }
    }

    private func macNoteButton(onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "bubble.left.fill")
                .font(.ripulIcon(size: 14, weight: .bold))
                .foregroundStyle(.ripul(.onAccent))
                .frame(width: 34, height: 28)
                .background(Color.ripul(system: .systemPurple), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Send note (not sent to agent)")
    }

    @ViewBuilder
    private var actionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty || !contextStore.attachments(for: contextSessionID).isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent {
                    ComposerActionButtons(actions: composerActions, pending: composerActionPending, onAction: onComposerAction)
                }
                if hasContent, let onSubmitNote {
                    macNoteButton(onTap: onSubmitNote)
                }
                if hasContent {
                    Button {
                        submitMessage()
                    } label: {
                        Image(systemName: "arrow.up")
                        .accessibilityLabel(runningSendLabel)
                            .font(.ripulIcon(size: 14, weight: .bold))
                            .foregroundStyle(.ripul(.onAccent))
                            .frame(width: 34, height: 28)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    onPause?()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.ripulIcon(size: 14, weight: .bold))
                        .foregroundStyle(.ripul(.onAccent))
                        .frame(width: 34, height: 28)
                        .background(Color.ripul(.warning), in: Capsule())
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
                        .font(.ripulIcon(size: 14, weight: .bold))
                        .foregroundStyle(.ripul(.onAccent))
                        .frame(width: 34, height: 28)
                        .background(Color.ripul(.success), in: Capsule())
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
                        .accessibilityLabel("Send message")
                        .font(.ripulIcon(size: 14, weight: .bold))
                        .foregroundStyle(.ripul(.onAccent))
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
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty || !contextStore.attachments(for: contextSessionID).isEmpty
        if isAgentRunning && !isAgentPaused {
            HStack(spacing: 4) {
                if hasContent {
                    ComposerActionButtons(actions: composerActions, pending: composerActionPending, onAction: onComposerAction)
                }
                if hasContent, let onSubmitNote {
                    Button { onSubmitNote() } label: {
                        Image(systemName: "bubble.left.fill")
                            .font(.ripulIcon(size: 18, weight: .bold))
                            .foregroundStyle(.ripul(system: .systemPurple))
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
                        .accessibilityLabel(runningSendLabel)
                            .font(.ripulIcon(size: 18, weight: .bold))
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
                        .font(.ripulIcon(size: 18, weight: .bold))
                        .foregroundStyle(.ripul(.warning))
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
                            .font(.ripulIcon(size: 18, weight: .bold))
                            .foregroundStyle(.ripul(system: .systemPurple))
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
                        .font(.ripulIcon(size: 18, weight: .bold))
                        .foregroundStyle(.ripul(.success))
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
                            .font(.ripulIcon(size: 18, weight: .bold))
                            .foregroundStyle(.ripul(system: .systemPurple))
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
                        .accessibilityLabel("Send message")
                        .font(.ripulIcon(size: 18, weight: .bold))
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
                    .font(.ripulIcon(size: 18, weight: .medium))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .modifier(GlassCircleModifier(glassStyle: isTwoRow ? nil : resolvedChatInputGlassStyle))
            .ripulSheet(isPresented: $showHistorySheet) {
                HistorySheet(history: history) { msg in
                    text = msg.text
                    imageAttachments = NativeImageAttachment.restore(history.attachments(for: msg))
                    history.resetCursor()
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
                                .font(.ripulIcon(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.ripul(system: .white), .ripul(.neutral))
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
    let onSelect: (MessageHistory.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(id: String, title: String, entries: [MessageHistory.Entry])] {
        let entries = history.entries.reversed().filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                || $0.chatTitle.localizedCaseInsensitiveContains(search)
                || $0.attachmentNames.contains { $0.localizedCaseInsensitiveContains(search) }
        }
        var result: [(id: String, title: String, entries: [MessageHistory.Entry])] = []
        for entry in entries {
            let id = entry.chatID ?? "unassigned"
            if let index = result.firstIndex(where: { $0.id == id }) { result[index].entries.append(entry) }
            else { result.append((id, entry.chatTitle, [entry])) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.id) { group in
                    Section(themed: group.title) {
                        ForEach(group.entries) { msg in historyRow(msg) }
                    }.ripulThemedListRows()
                }
            }.ripulThemedList()
            .searchable(text: $search, prompt: "Search prompts, chats and files")
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
        .ripulSheet(.page, detents: [.medium, .large], selection: .constant(.large))
        #endif
    }

    private func historyRow(_ msg: MessageHistory.Entry) -> some View {
        Button {
            onSelect(msg)
        } label: {
            HStack {
                if msg.favorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.ripul(system: .systemYellow))
                        .font(.ripulIcon(.caption2))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.text.isEmpty ? "Attachments" : msg.text)
                        .lineLimit(3)
                        .foregroundStyle(.ripul(.text))
                    if !msg.attachmentNames.isEmpty {
                        Label(msg.attachmentNames.joined(separator: ", "), systemImage: "paperclip")
                            .lineLimit(2)
                    }
                    HStack {
                        Label(msg.modality == "voice" ? "Voice" : msg.modality == "unknown" ? "Earlier prompt" : "Keyboard",
                              systemImage: msg.modality == "voice" ? "mic" : "keyboard")
                        Text(msg.sentAt, style: .date)
                        Text(msg.sentAt, style: .time)
                    }
                }
                .font(.ripul(.caption))
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
                    msg.favorite ? "Unfavorite" : "Favorite",
                    systemImage: msg.favorite ? "star.slash.fill" : "star.fill"
                )
            }
            .tint(Color.ripul(system: .systemYellow))
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
                            .font(.ripulIcon(.largeTitle))
                            .foregroundStyle(.ripul(.textSecondary))
                        Text("No to do items").ripulText()
                            .font(.ripul(.headline))
                        Text("Create one from the + menu to pick it later.")
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !thisChatItems.isEmpty {
                            Section(themed: "This chat") {
                                ForEach(thisChatItems) { item in
                                    todoRow(item, showChatName: false)
                                }
                            }.ripulThemedListRows()
                        }
                        if !otherChatItems.isEmpty {
                            Section(themed: "Other chats") {
                                ForEach(otherChatItems) { item in
                                    todoRow(item, showChatName: true)
                                }
                            }.ripulThemedListRows()
                        }
                    }.ripulThemedList()
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
        .ripulSheet(.page, detents: [.medium, .large])
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
                    .foregroundStyle(.ripul(.text))
                if showChatName, let chatName = item.chatName, !chatName.isEmpty {
                    Text(chatName)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
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

    // Stroke-opacity pulse only — no .shadow. An animating blur radius over the
    // glass pill forces the compositor to re-blur the region every frame for the
    // entire agent run (sustained GPU heat, thermal audit R2-2). The pulse runs
    // in the render server (see RenderServerAnimations): a SwiftUI
    // repeatForever re-rendered the composer every frame for the whole turn.
    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !PerfSwitch.isOff("glow") {
                    RenderServerPulseStroke(cornerRadius: 22, lineWidth: 1.25, color: .ripul(.warning),
                                            low: 0.12, high: 0.35, duration: 6)
                }
            }
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
                    // Keep the readability blur inside the same shape as the
                    // composer glass, never across the surrounding chat lane.
                    .background {
                        if glassStyle != "regular" {
                            RoundedRectangle(cornerRadius: 22)
                                .fill(.ultraThinMaterial)
                                .opacity(0.6)
                        }
                    }
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
extension ChatTextView: UITextPasteDelegate {
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          transform item: UITextPasteItem) {
        let provider = item.itemProvider
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            item.setDefaultResult()
            return
        }
        item.setNoResult()
        DispatchQueue.main.async { self.takeDroppedFile(provider) }
    }
}

/// UITextView subclass that suppresses the iOS autofill toolbar above the keyboard.
class ChatTextView: UITextView {
    /// Return true only after images have become composer attachments. Reading
    /// clipboard contents happens in the explicit Paste action, never on focus.
    var onPasteImages: (([UIImage]) -> Bool)?

    override func paste(_ sender: Any?) {
        if isEditable, let onPasteImages, let images = UIPasteboard.general.images,
           !images.isEmpty, onPasteImages(images) {
            return
        }
        super.paste(sender)
    }

    /// Images and files dropped on the editor. UIKit sends text drops through
    /// the paste delegate, which would insert a Finder file's path as text;
    /// those items go here instead, and text still drops in as text.
    var onDropFiles: (([NSItemProvider]) -> Void)? {
        didSet { pasteDelegate = onDropFiles == nil ? nil : self }
    }
    private var droppedFiles: [NSItemProvider] = []

    private func takeDroppedFile(_ provider: NSItemProvider) {
        droppedFiles.append(provider)
        guard droppedFiles.count == 1 else { return }
        // One drop transforms each of its items in turn: hand them over together.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let providers = droppedFiles
            droppedFiles = []
            onDropFiles?(providers)
        }
    }

    override func resignFirstResponder() -> Bool {
        NativeComposerFocusTrace.shared.record("editor.resign.request", view: self, stack: true)
        let resigned = super.resignFirstResponder()
        NativeComposerFocusTrace.shared.record("editor.resign.result", view: self, values: ["resigned": resigned])
        return resigned
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        NativeComposerFocusTrace.shared.record("editor.window", view: self,
            values: ["leaving": newWindow == nil], stack: isFirstResponder && newWindow == nil)
        super.willMove(toWindow: newWindow)
    }

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
        if action == #selector(paste(_:)), isEditable, onPasteImages != nil,
           UIPasteboard.general.hasImages {
            return true
        }
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

    /// Key commands come from hardware keyboards, including iPhone Mirroring.
    /// Onscreen Return still uses UITextView's normal newline insertion.
    var onReturnKey: (() -> Void)?
    /// Hardware Up/Down recall sent messages. Asked with the arrow's direction
    /// and whether the text sits on one visual line; when it answers false the
    /// arrow is left to move the caret, so multi-line text navigates normally.
    var canRecallHistory: ((_ up: Bool, _ singleLine: Bool) -> Bool)?
    var onRecallHistory: ((_ up: Bool) -> Void)?
    /// While the @ list is open, the arrows, Return, Tab and Escape drive it
    /// instead of the caret, history and send.
    enum SuggestionKey { case up, down, pick, dismiss }
    var suggestionsOpen = false
    var onSuggestionKey: ((SuggestionKey) -> Void)?

    /// Start and end of the text share a visual line; a soft wrap counts as a
    /// second line, the same as a newline.
    private var isSingleLine: Bool {
        guard hasText else { return true }
        return abs(caretRect(for: beginningOfDocument).minY - caretRect(for: endOfDocument).minY) < 1
    }

    override var keyCommands: [UIKeyCommand]? {
        // Let an input method use Return to confirm its marked text instead
        // of accidentally sending an unfinished composition.
        guard isEditable, markedTextRange == nil, onReturnKey != nil else { return super.keyCommands }
        if suggestionsOpen, onSuggestionKey != nil {
            let keys: [(String, Selector)] = [
                (UIKeyCommand.inputUpArrow, #selector(handleSuggestionUp)),
                (UIKeyCommand.inputDownArrow, #selector(handleSuggestionDown)),
                ("\r", #selector(handleSuggestionPick)), ("\t", #selector(handleSuggestionPick)),
                (UIKeyCommand.inputEscape, #selector(handleSuggestionDismiss)),
            ]
            return keys.map { input, action in
                let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
                command.wantsPriorityOverSystemBehavior = true
                return command
            } + (super.keyCommands ?? [])
        }
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleReturnKey))
        send.wantsPriorityOverSystemBehavior = true
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleShiftReturnKey))
        newline.wantsPriorityOverSystemBehavior = true
        var commands = [send, newline]
        // Offered only when recall applies: an arrow without a command falls
        // through to the text view's own caret movement.
        if let canRecallHistory {
            let singleLine = isSingleLine
            for (input, up) in [(UIKeyCommand.inputUpArrow, true), (UIKeyCommand.inputDownArrow, false)]
            where canRecallHistory(up, singleLine) {
                let recall = UIKeyCommand(input: input, modifierFlags: [],
                                          action: up ? #selector(handleHistoryUp) : #selector(handleHistoryDown))
                recall.wantsPriorityOverSystemBehavior = true
                commands.append(recall)
            }
        }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func handleReturnKey() {
        guard isEditable, markedTextRange == nil else { return }
        onReturnKey?()
    }
    @objc private func handleShiftReturnKey() {
        guard isEditable, markedTextRange == nil else { return }
        insertText("\n")
    }
    @objc private func handleSuggestionUp() { onSuggestionKey?(.up) }
    @objc private func handleSuggestionDown() { onSuggestionKey?(.down) }
    @objc private func handleSuggestionPick() { onSuggestionKey?(.pick) }
    @objc private func handleSuggestionDismiss() { onSuggestionKey?(.dismiss) }
    @objc private func handleHistoryUp() { onRecallHistory?(true) }
    @objc private func handleHistoryDown() { onRecallHistory?(false) }
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
    var onPasteImages: (([UIImage]) -> Bool)?
    var onDropFiles: (([NSItemProvider]) -> Void)?
    var canRecallHistory: ((_ up: Bool, _ singleLine: Bool) -> Bool)?
    var onRecallHistory: ((_ up: Bool) -> Void)?
    var suggestionsOpen = false
    var onSuggestionKey: ((ChatTextView.SuggestionKey) -> Void)?
    var freezesHeight = false

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ChatTextView {
        let textView = ChatTextView()
        textView.accessibilityIdentifier = "NativeChatInput.editor"
        textView.delegate = context.coordinator
        let bodySize = UIFont.ripul(.body).pointSize
        textView.font = .ripul(size: bodySize + 1, weight: .semibold)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .default
        textView.enablesReturnKeyAutomatically = false

        // Let Apple's vibrancy handle text color adaptation
        textView.textColor = .ripul(.text)

        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .yes
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []

        // Placeholder
        let label = UILabel()
        label.text = placeholder
        label.font = textView.font
        label.textColor = .ripul(system: .placeholderText)
        label.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8)
        ])
        context.coordinator.placeholderLabel = label
        context.coordinator.followTheme(textView)

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
        let wasFrozen = context.coordinator.parent.freezesHeight
        context.coordinator.parent = self
        if wasFrozen && !freezesHeight { context.coordinator.recalcHeight(textView) }
        textView.onPasteImages = onPasteImages
        if (textView.onDropFiles == nil) != (onDropFiles == nil) { textView.onDropFiles = onDropFiles }
        textView.onReturnKey = onSubmit
        textView.canRecallHistory = canRecallHistory
        textView.onRecallHistory = onRecallHistory
        textView.suggestionsOpen = suggestionsOpen
        textView.onSuggestionKey = onSuggestionKey
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

        private weak var themedTextView: UITextView?

        init(_ parent: NoAutofillTextView) {
            self.parent = parent
        }

        /// The fonts are read once when the view is made, so a new theme document would
        /// reach the text and its placeholder only at the next launch. Read them again
        /// when the theme changes.
        func followTheme(_ textView: UITextView) {
            themedTextView = textView
            NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange),
                                                   name: .ripulThemeDidChange, object: nil)
        }

        @objc private func themeDidChange() {
            guard let textView = themedTextView else { return }
            let font = UIFont.ripul(size: UIFont.ripul(.body).pointSize + 1, weight: .semibold) // theme-mapping: the font makeUIView gives it, read again
            textView.font = font
            placeholderLabel?.font = font
            textView.invalidateIntrinsicContentSize()
            recalcHeight(textView)
        }

        func recalcHeight(_ textView: UITextView) {
            guard !parent.freezesHeight else { return }
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
                    guard !self.parent.freezesHeight else { return }
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
            NativeComposerFocusTrace.shared.record("editor.begin", view: textView)
            // Tapping into a collapsed multi-line box must re-expand it the
            // same way typing does — remeasure now, not on the next keystroke.
            recalcHeight(textView)
            parent.onFocusChanged?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            NativeComposerFocusTrace.shared.record("editor.end", view: textView)
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

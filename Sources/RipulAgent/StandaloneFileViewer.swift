#if os(iOS)
import SwiftUI

/// Sheet-hosted file viewer that runs the web Monaco viewer in its own
/// WKWebView, isolated from the main chat bridge. This is what FilesScreen
/// presents when the user taps a file — it avoids the "chat flash" that
/// happened when we opened the viewer on the main chat web view, and lets
/// the user return to Files (not chat) when the sheet is dismissed.
///
/// The web side boots in file-viewer-only mode via the `fileViewerPath` hash
/// param (see AgentConfiguration). localStorage (and therefore the relay
/// pairing) is shared with the main web view through `WKWebsiteDataStore
/// .default()`, so file reads flow through the same paired machine.
///
/// Ported from the native app (`iOS/StandaloneFileViewer.swift`) for the M8
/// whole-screen extraction. `siteKey`/`baseURL` are injectable so hosts
/// without a site key (e.g. the developer console) can still use the viewer.
@available(iOS 15.0, *)
public struct StandaloneFileViewer: View {
    let filePath: String
    let chatId: String?
    /// Optional 1-based line to scroll to on open (e.g. from a grep hit).
    var line: Int? = nil
    /// Main bridge with an authenticated relay — used to pre-fetch file
    /// content that is then injected into the viewer's own (unauthenticated)
    /// web view.
    var readBridge: AgentBridge?
    /// Site key for the viewer's web boot config. The first-party Ripul app
    /// passes its own key; a developer console passes nil.
    var siteKey: String? = nil
    var baseURL: URL = AgentConfiguration.defaultBaseURL

    @StateObject private var viewerBridge = AgentBridge()
    @Environment(\.colorScheme) private var colorScheme

    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var matchTotal = 0
    @State private var matchCurrent = 0
    @FocusState private var searchFocused: Bool

    public init(
        filePath: String,
        chatId: String?,
        line: Int? = nil,
        readBridge: AgentBridge? = nil,
        siteKey: String? = nil,
        baseURL: URL = AgentConfiguration.defaultBaseURL
    ) {
        self.filePath = filePath
        self.chatId = chatId
        self.line = line
        self.readBridge = readBridge
        self.siteKey = siteKey
        self.baseURL = baseURL
    }

    private var configuration: AgentConfiguration {
        var config = AgentConfiguration(
            baseURL: baseURL,
            path: "/popup",
            siteKey: siteKey,
            theme: colorScheme == .dark ? .dark : .light,
            nativeApp: true,
            hideHeader: true,
            hideTabSwitcher: true,
            hideChatInput: true
        )
        config.fileViewerPath = filePath
        config.fileViewerChatId = chatId
        config.fileViewerLine = line
        return config
    }

    public var body: some View {
        ZStack(alignment: .top) {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()

            AgentWebView(configuration: configuration, bridge: viewerBridge)
                .ignoresSafeArea()

            if isSearching {
                searchBar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFileViewerToggleSearch)) { _ in
            if isSearching { exitSearchMode() } else { enterSearchMode() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFileViewerZoomIn)) { _ in
            viewerBridge.fileViewerZoomIn()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFileViewerZoomOut)) { _ in
            viewerBridge.fileViewerZoomOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFileViewerZoomReset)) { _ in
            viewerBridge.fileViewerZoomReset()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFileViewerToggleWordWrap)) { _ in
            viewerBridge.fileViewerToggleWordWrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFileViewerToggleRaw)) { _ in
            viewerBridge.fileViewerToggleRaw()
        }
        .task {
            // Pre-fetch file content via the main bridge's authenticated relay, then
            // inject it into the viewer's separate (unauthenticated) web view. The
            // inject* calls now wait for that web view to finish mounting before
            // delivering, so there's no fixed-delay race.
            guard let readBridge else {
                viewerBridge.injectFileError("No bridge available")
                return
            }
            let content = await readBridge.readRemoteFile(path: filePath, chatId: chatId)
            // Diagnostic on the MAIN web view (captured by device_console_logs): proves
            // whether the read result actually returned to native.
            readBridge.logToWebConsole("[FVNATIVE] readRemoteFile -> " + (content.map { "len=\($0.count)" } ?? "nil"))
            guard let content else {
                viewerBridge.injectFileError("Could not read file — host may be disconnected")
                return
            }
            viewerBridge.injectFileContent(content)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .uiKitIdentifier("StandaloneFileViewer.search.icon")

                TextField("Find in file", text: $searchQuery)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .font(.body)
                    .foregroundColor(Color(uiColor: .label))
                    .uiKitIdentifier("StandaloneFileViewer.search.textField")
                    .onChange(of: searchQuery) { _, newValue in
                        Task { await runFind(newValue) }
                    }
                    .onSubmit {
                        Task { await runFindNext() }
                    }

                if matchTotal > 0 {
                    Text("\(matchCurrent) of \(matchTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                        .uiKitIdentifier("StandaloneFileViewer.search.matchCount")
                } else if !searchQuery.isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                        .uiKitIdentifier("StandaloneFileViewer.search.noMatches")
                }

                Button {
                    Task { await runFindPrev() }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .disabled(matchTotal == 0)
                .uiKitIdentifier("StandaloneFileViewer.search.prevButton")

                Button {
                    Task { await runFindNext() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .disabled(matchTotal == 0)
                .uiKitIdentifier("StandaloneFileViewer.search.nextButton")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )

            Button("Done") {
                exitSearchMode()
            }
            .uiKitIdentifier("StandaloneFileViewer.search.doneButton")
            .font(.body)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func enterSearchMode() {
        isSearching = true
        searchQuery = ""
        matchTotal = 0
        matchCurrent = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocused = true
        }
    }

    private func exitSearchMode() {
        searchFocused = false
        isSearching = false
        searchQuery = ""
        matchTotal = 0
        matchCurrent = 0
        Task { _ = await viewerBridge.fileViewerFind(query: "") }
    }

    private func runFind(_ query: String) async {
        let result = await viewerBridge.fileViewerFind(query: query)
        await MainActor.run {
            matchTotal = result.total
            matchCurrent = result.current
        }
    }

    private func runFindNext() async {
        let result = await viewerBridge.fileViewerFindNext()
        await MainActor.run {
            matchTotal = result.total
            matchCurrent = result.current
        }
    }

    private func runFindPrev() async {
        let result = await viewerBridge.fileViewerFindPrev()
        await MainActor.run {
            matchTotal = result.total
            matchCurrent = result.current
        }
    }
}

public extension Notification.Name {
    static let ripulFileViewerToggleSearch = Notification.Name("ripulFileViewerToggleSearch")
    static let ripulFileViewerZoomIn = Notification.Name("ripulFileViewerZoomIn")
    static let ripulFileViewerZoomOut = Notification.Name("ripulFileViewerZoomOut")
    static let ripulFileViewerZoomReset = Notification.Name("ripulFileViewerZoomReset")
    static let ripulFileViewerToggleWordWrap = Notification.Name("ripulFileViewerToggleWordWrap")
    static let ripulFileViewerToggleRaw = Notification.Name("ripulFileViewerToggleRaw")
}
#endif

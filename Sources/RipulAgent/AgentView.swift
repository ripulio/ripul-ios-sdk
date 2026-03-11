import SwiftUI

#if canImport(PhotosUI)
import PhotosUI
#endif

#if os(iOS)
import UIKit
#endif

@available(iOS 16.0, macOS 14.0, *)
@MainActor
public struct AgentView<TopBar: View>: View {
    public let configuration: AgentConfiguration
    public var tools: [NativeTool] = []
    public weak var searchClickDelegate: SearchClickDelegate?
    public weak var linkOpenDelegate: LinkOpenDelegate?
    public var onMinimize: (() -> Void)?
    private let topBar: ((AgentBridge) -> TopBar)?

    @StateObject private var bridge: AgentBridge
    private let skipBridgeSetup: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var readyConfig: AgentConfiguration?
    @State private var chatMessage = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageAttachments: [NativeImageAttachment] = []
    @State private var showingQuickCommands = false
    @State private var showingDebugCommands = false

    #if os(iOS)
    @StateObject private var keyboard = KeyboardObserver()
    #endif

    #if os(macOS)
    @StateObject private var messageHistory = MessageHistory()
    #endif

    /// Creates an AgentView that manages its own bridge internally.
    public init(
        configuration: AgentConfiguration,
        tools: [NativeTool] = [],
        searchClickDelegate: SearchClickDelegate? = nil,
        linkOpenDelegate: LinkOpenDelegate? = nil,
        onMinimize: (() -> Void)? = nil,
        @ViewBuilder topBar: @escaping (AgentBridge) -> TopBar
    ) {
        self.configuration = configuration
        self.tools = tools
        self.searchClickDelegate = searchClickDelegate
        self.linkOpenDelegate = linkOpenDelegate
        self.onMinimize = onMinimize
        self.topBar = topBar
        self._bridge = StateObject(wrappedValue: AgentBridge())
        self.skipBridgeSetup = false
    }

    /// Creates an AgentView using an externally-managed bridge.
    /// The caller is responsible for registering tools and setting delegates on the bridge.
    public init(
        configuration: AgentConfiguration,
        bridge: AgentBridge,
        onMinimize: (() -> Void)? = nil,
        @ViewBuilder topBar: @escaping (AgentBridge) -> TopBar
    ) {
        self.configuration = configuration
        self.tools = []
        self.searchClickDelegate = nil
        self.linkOpenDelegate = nil
        self.onMinimize = onMinimize
        self.topBar = topBar
        self._bridge = StateObject(wrappedValue: bridge)
        self.skipBridgeSetup = true
    }

    public var body: some View {
        ZStack(alignment: .top) {
            #if os(iOS)
            (colorScheme == .dark ? Color(uiColor: .black) : Color(uiColor: .white))
                .ignoresSafeArea(edges: .top)
            #else
            Color.clear
            #endif

            if let config = readyConfig {
                #if os(iOS)
                GeometryReader { geo in
                    AgentWebView(configuration: config, bridge: bridge)
                        .frame(height: keyboard.height > 0
                            ? geo.size.height - keyboard.height + 30
                            : geo.size.height)
                }
                .ignoresSafeArea()
                #else
                AgentWebView(configuration: config, bridge: bridge)
                #endif
            }

            if let topBar {
                topBar(bridge)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if bridge.showScrollToBottom {
                    ScrollToBottomButton {
                        bridge.scrollToBottom()
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                chatInput
            }
            .padding(.horizontal, 12)
            #if os(iOS)
            .padding(.bottom, keyboard.height > 0 ? keyboard.height + 4 : 8)
            #else
            .padding(.bottom, 8)
            #endif
            .animation(.spring(duration: 0.3), value: bridge.showScrollToBottom)
        }
        #if os(iOS)
        .ignoresSafeArea(.keyboard)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        #endif
        .onChange(of: colorScheme) { newScheme in
            let theme: AgentTheme = newScheme == .dark ? .dark : .light
            bridge.setTheme(theme)
        }
        .onChange(of: bridge.wantsMinimize) { wantsMinimize in
            if wantsMinimize {
                if let onMinimize {
                    onMinimize()
                } else {
                    dismiss()
                }
            }
        }
        .onChange(of: selectedPhotos) { newItems in
            Task {
                imageAttachments = await PhotoAttachmentHelper.process(newItems)
            }
        }
        .onChange(of: chatMessage) { newValue in
            if newValue.lowercased().hasPrefix(debugCommandTrigger) {
                chatMessage = ""
                showingDebugCommands = true
            }
        }
        .onChange(of: bridge.pendingInputText) { text in
            if let text {
                chatMessage = text
                bridge.pendingInputText = nil
            }
        }
        .sheet(isPresented: $showingQuickCommands) {
            QuickCommandsSheet(bridge: bridge)
        }
        .sheet(isPresented: $showingDebugCommands) {
            QuickCommandsSheet(bridge: bridge, debugMode: true)
        }
        .sheet(item: $bridge.pendingUserInteraction) { question in
            UserInteractionSheet(question: question) { answer in
                bridge.respondToUserInteraction(answer: answer)
            }
        }
        .task {
            if !skipBridgeSetup {
                bridge.register(tools)
                bridge.searchClickDelegate = searchClickDelegate
                bridge.linkOpenDelegate = linkOpenDelegate
            }

            var config = configuration
            if let siteKey = config.siteKey, config.siteKeyConfig == nil {
                let result = await SiteKeyValidator.validate(
                    siteKey: siteKey, baseURL: config.baseURL
                )
                if let token = result.sessionToken {
                    config.sessionToken = token
                }
                config.siteKeyConfig = result.configJSON
            }
            readyConfig = config
        }
    }

    // MARK: - Chat Input

    private func handleSubmit() {
        let message = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if bridge.isAgentPaused {
            chatMessage = ""
            imageAttachments = []
            selectedPhotos = []
            if message.isEmpty {
                Task { await bridge.resumeAgent() }
            } else {
                recordHistory(message)
                Task { await bridge.submitMessage(message, imageAttachments: nil) }
            }
        } else {
            guard !message.isEmpty || !imageAttachments.isEmpty else { return }
            if !message.isEmpty { recordHistory(message) }
            let images = imageAttachments
            chatMessage = ""
            imageAttachments = []
            selectedPhotos = []
            Task {
                let imgDicts: [[String: String]]? = images.isEmpty ? nil : images.map { $0.toDictionary() }
                await bridge.submitMessage(message, imageAttachments: imgDicts)
            }
        }
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func handleNewChat() {
        chatMessage = ""
        imageAttachments = []
        selectedPhotos = []
        Task { await bridge.startNewChat() }
    }

    private func recordHistory(_ message: String) {
        #if os(macOS)
        messageHistory.record(message)
        #endif
    }

    #if os(iOS)
    private var chatInput: some View {
        NativeChatInput(
            text: $chatMessage,
            imageAttachments: $imageAttachments,
            selectedPhotos: $selectedPhotos,
            isAgentRunning: bridge.isAgentRunning,
            isAgentPaused: bridge.isAgentPaused,
            onSubmit: handleSubmit,
            onPause: { Task { await bridge.interruptAgent() } },
            onNewChat: handleNewChat,
            onQuickCommands: { showingQuickCommands = true },
            chatInputGlassStyle: bridge.chatInputGlassStyle
        )
    }
    #elseif os(macOS)
    private var chatInput: some View {
        NativeChatInput(
            text: $chatMessage,
            imageAttachments: $imageAttachments,
            selectedPhotos: $selectedPhotos,
            isAgentRunning: bridge.isAgentRunning,
            isAgentPaused: bridge.isAgentPaused,
            onSubmit: handleSubmit,
            onPause: { Task { await bridge.interruptAgent() } },
            onNewChat: handleNewChat,
            onQuickCommands: { showingQuickCommands = true },
            messageHistory: messageHistory,
            chatInputGlassStyle: bridge.chatInputGlassStyle
        )
    }
    #endif
}

// MARK: - Convenience inits without top bar

@available(iOS 16.0, macOS 14.0, *)
public extension AgentView where TopBar == EmptyView {
    /// Creates an AgentView with no top bar, managing its own bridge.
    init(
        configuration: AgentConfiguration,
        tools: [NativeTool] = [],
        searchClickDelegate: SearchClickDelegate? = nil,
        linkOpenDelegate: LinkOpenDelegate? = nil,
        onMinimize: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.tools = tools
        self.searchClickDelegate = searchClickDelegate
        self.linkOpenDelegate = linkOpenDelegate
        self.onMinimize = onMinimize
        self.topBar = nil
        self._bridge = StateObject(wrappedValue: AgentBridge())
        self.skipBridgeSetup = false
    }

    /// Creates an AgentView with no top bar, using an externally-managed bridge.
    init(
        configuration: AgentConfiguration,
        bridge: AgentBridge,
        onMinimize: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.tools = []
        self.searchClickDelegate = nil
        self.linkOpenDelegate = nil
        self.onMinimize = onMinimize
        self.topBar = nil
        self._bridge = StateObject(wrappedValue: bridge)
        self.skipBridgeSetup = true
    }
}

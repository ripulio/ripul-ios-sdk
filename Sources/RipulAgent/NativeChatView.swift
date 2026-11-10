import SwiftUI
import Combine
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct NativeChatFileReferenceGroup: Identifiable {
    let id = UUID()
    let references: [NativeChatFileReference]
    let chatId: String
}

/// Full-featured native SwiftUI chat scroller ("Native Chat (beta)").
///
/// Renders `NativeChatMessageStore.rows` — the grouped and enriched representation
/// of the conversation forwarded by `nativeChatMessageForwarder.ts` — using native
/// SwiftUI components:
/// - `NativeToolStripContent` for badged tool lozenge strips with 20s idle collapse
/// - `ToolCallDetailsSheet` via `bridge.toolCallDetails` when tapping a tool lozenge
/// - `NativeTaskRunRow` for sub-agent and workflow runs
/// - `NativeToolCodeBlock` (`HighlightSwift`) for syntax-highlighted fenced code blocks
/// - Interactive `askUser` single-choice, multi-choice, date, and free-text cards
/// - User bubbles with swipe-to-reply, reply quotes, attachments, context tags, and group avatars
/// - Assistant cards with respondent model/token/cost metadata disclosure and action lozenges
/// - Conversation time/day gaps, user notes/artefact references, system status, errors, and CLI seams
@available(iOS 16.0, macOS 14.0, *)
public struct NativeChatView: View {
    @ObservedObject private var store: NativeChatMessageStore
    private let bridge: AgentBridge?
    private let topInset: CGFloat
    /// The clearance below the rows with the composer open, and folded to its pill when
    /// a host passes the fold (`ComposerFoldState`).
    private let bottomInset: CGFloat
    private let foldedBottomInset: CGFloat?
    private let fold: ComposerFoldState?

    @State private var activeToolbarMessageId: String? = nil
    @State private var highlightedMessageId: String? = nil
    @State private var zoomedImage: NativeChatImageAttachment? = nil
    @State private var fileReferences: NativeChatFileReferenceGroup?
    @State private var pendingFileReference: (href: String, chatId: String)?
    @State private var pendingLoadMoreAnchorId: String? = nil
    @State private var isLoadingMore: Bool = false
    @State private var displayedRows: [NativeChatRow]
    @State private var displayedTruncatedCount: Int
    @State private var rowActions = NativeChatRowActions()
    /// Made once for the view's life, with its coordinator: `StateObject` runs
    /// its closure only the first time. A coordinator made in `init` was made,
    /// and given every row, each time the screen above was drawn again (any
    /// change to the bridge), then thrown away.
    @StateObject private var windowBand: NativeChatWindowBand
    private var scrollCoordinator: NativeChatScrollCoordinator { windowBand.coordinator }
    @Environment(\.dynamicTypeSize) private var windowTextSize
    /// False while the chat is not on screen (its tab behind Home, say): new
    /// rows are held and drawn when it is shown. A chat left open behind Home
    /// drew each streamed message as it came, 58-102 ms frames under a finger
    /// scrolling Home on Peter's Duo (5 November 2026; docs/main-thread.md, rule 5).
    @Environment(\.screenIsShown) private var screenIsShown
    /// How thinking is shown, the page's setting. Handed to each row rather
    /// than read from the environment, so the rows' `.equatable()` gate sees it.
    @State private var thinkingMode: ThinkingDisplayMode
    #if os(iOS)
    /// The owned UIKit list and its one viewport owner (docs/plans/native-chat-viewport-owner.md).
    /// `ripul.nativeChatPerf.ownedList` set to NO brings back the SwiftUI scroller and its
    /// coordinator, for an A/B; read when the chat is shown.
    /// Held, not observed: this body draws nothing from the handle, and as a state object
    /// each change of following (a fling reaching the end or leaving it) ran it in full. A
    /// fling settling at the end on Peter's Duo showed a 35 ms frame with nothing else
    /// named in it (9 November 2026). Its one publication reaches `updatePinnedToBottom`
    /// through `onReceive`.
    @State private var listHandle = NativeChatListHandle()
    @State private var usesOwnedList: Bool
    /// The chat `displayedRows` belong to, handed to the list with them.
    @State private var ownedChatId: String?
    /// The list's edges beside the system's tab rail, where its rows keep no gutter.
    @State private var ownedRailEdges: Edge.Set = []
    /// Until when new rows wait for the composer's clearance to finish dropping.
    @State private var ownedHoldUntil: CFTimeInterval = 0
    @State private var ownedFlushScheduled = false
    #endif

    public init(store: NativeChatMessageStore, bridge: AgentBridge? = nil, topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        self.init(store: store, bridge: bridge, topInset: topInset, bottomInset: bottomInset,
                  foldedBottomInset: nil, fold: nil)
    }

    init(store: NativeChatMessageStore, bridge: AgentBridge?, topInset: CGFloat, bottomInset: CGFloat,
         foldedBottomInset: CGFloat?, fold: ComposerFoldState?) {
        self.store = store
        self.bridge = bridge
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.foldedBottomInset = foldedBottomInset
        self.fold = fold
        self._thinkingMode = State(initialValue: bridge?.navigationStore.thinkingDisplayMode ?? .open)
        self._displayedRows = State(initialValue: store.rows)
        self._displayedTruncatedCount = State(initialValue: store.truncatedCount)
        self._windowBand = StateObject(wrappedValue: NativeChatWindowBand(rows: store.rows))
        #if os(iOS)
        self._usesOwnedList = State(initialValue: Self.ownedListSetting)
        self._ownedChatId = State(initialValue: store.currentChatId)
        #endif
    }

    public var body: some View {
        let _ = ChatSlideProbe.markBody("NativeChatView") { Self._printChanges() }
        scroller
            .environment(\.openURL, OpenURLAction { url in
                if let reference = NativeChatContextMentions.reference(in: url), let bridge {
                    bridge.send([
                        "type": "agent-framework:nativeChat:action",
                        "op": "openChatReference",
                        "chatId": store.currentChatId ?? "",
                        "ref": reference,
                    ])
                    return .handled
                }
                if bridge != nil, let references = NativeChatFileReferences.references(in: url) {
                    let chatId = store.currentChatId ?? ""
                    if references.count == 1 { openHostFile(references[0].href, chatId: chatId) }
                    else { fileReferences = NativeChatFileReferenceGroup(references: references, chatId: chatId) }
                    return .handled
                }
                if let bridge, NativeChatFileReferences.isFileURL(url, pageURL: bridge.attachedWebView?.url) {
                    openHostFile(url.absoluteString, chatId: store.currentChatId ?? "")
                    return .handled
                }
                if RipulSecureConnection.open(url) { return .handled }
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    return .handled
                    #elseif os(macOS)
                    NSWorkspace.shared.open(url)
                    return .handled
                    #endif
                }
                return .systemAction
            })
            .ripulSheet(item: $zoomedImage) { attachment in
                NativeChatImageZoomSheet(attachment: attachment) {
                    zoomedImage = nil
                }
            }
            .ripulSheet(item: $fileReferences, onDismiss: {
                if let pending = pendingFileReference {
                    pendingFileReference = nil
                    openHostFile(pending.href, chatId: pending.chatId)
                }
            }) { group in
                NativeChatFileReferencesSheet(references: group.references) { reference in
                    pendingFileReference = (reference.href, group.chatId)
                    fileReferences = nil
                }
            }
            .onChange(of: store.currentChatId) { _ in
                pendingFileReference = nil
                fileReferences = nil
            }
    }

    private func openHostFile(_ href: String, chatId: String) {
        bridge?.send(["type": "agent-framework:nativeChat:action", "op": "openFileReference", "chatId": chatId, "href": href])
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            #if os(iOS)
            if usesOwnedList { ownedList } else { scrollView(proxy: proxy) }
            #else
            scrollView(proxy: proxy)
            #endif
        }
        .overlay(alignment: .top) {
            // Retry is an empty-load state. A stale failure from a background
            // refresh must never cover a conversation that is already readable.
            if !displayedRows.isEmpty, store.loadingState.phase == .loading {
                loadingState
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.top, topInset + 8)
            }
        }
        .onDisappear {
            handleDisappear()
        }
        .onChange(of: store.truncatedCount) { _, newCount in
            handleTruncatedCountChanged(newCount)
        }
        // The owned list hears of the composer folding from its own leaf.
        .onChange(of: ownsList ? bottomInset : scrollerBottomInset) { old, new in
            scrollCoordinator.entryTrace("bottomInset \(Int(old))->\(Int(new))")
            handleBottomInsetChanged(dropping: new < old)
        }
        .onChange(of: topInset) { old, inset in
            scrollCoordinator.entryTrace("topInset \(Int(old))->\(Int(inset))")
            // Set on appear; the bar's window clearance can arrive after it.
            scrollCoordinator.topInset = inset
        }
        .onChange(of: store.rows) { _, newRows in
            handleStoreRowsChanged(newRows)
        }
        // Shown again: the rows held while it was not, once a slide that
        // brings it in has landed, so the catch-up is not drawn mid-slide.
        .onChange(of: screenIsShown) { _, shown in
            guard shown else { return }
            ChatSlideProbe.afterSlide("nativeChat.catchUp") { flushHeldRows() }
        }
        .onChange(of: windowTextSize) { _, size in
            scrollCoordinator.windowTextMetrics = Self.windowMetrics(size, thinkingMode)
        }
        .onReceive(thinkingSettings) { setting in
            let mode = ThinkingDisplayMode(setting: setting)
            guard mode != thinkingMode else { return }
            // Re-key the row heights before the rows redraw, as a text size
            // change does, so the row being read stays where it is.
            scrollCoordinator.windowTextMetrics = Self.windowMetrics(windowTextSize, mode)
            thinkingMode = mode
        }
        #if os(iOS)
        // Settings > Debug > Native Chat Performance promises a switch takes effect in the
        // chat that is open: the other scroller appears, and its own appear handler places it.
        .onReceive(NotificationCenter.default.publisher(for: NativeChatPerformance.changed)) { _ in
            let owned = Self.ownedListSetting
            if owned != usesOwnedList { usesOwnedList = owned }
        }
        #endif
        .modifier(NativeChatScrollerIdentifier(active: !ownsList))
    }

    #if os(iOS)
    /// Settings > Debug > Native Chat Performance > Owned chat list. A launch argument's
    /// "NO" (`-ripul.nativeChatPerf.ownedList NO`) is read as well as a stored Bool.
    private static var ownedListSetting: Bool {
        let key = NativeChatPerformance.key(.ownedList)
        return NativeChatPerformance.isEnabled(.ownedList)
            && (UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key))
    }
    #endif

    /// The clearance below the rows as the SwiftUI scroller takes it: folded while the
    /// composer is. Read only on that scroller's path; the owned list reads the fold in
    /// `OwnedListClearance`, so a fold does not run this body.
    private var scrollerBottomInset: CGFloat {
        guard let fold, let foldedBottomInset, fold.collapsed else { return bottomInset }
        return foldedBottomInset
    }

    /// The owned list is on (iPhone and Catalyst, unless switched off).
    private var ownsList: Bool {
        #if os(iOS)
        return usesOwnedList
        #else
        return false
        #endif
    }

    /// The page's thinking setting as the bridge hears it; nothing without a bridge.
    private var thinkingSettings: AnyPublisher<String, Never> {
        bridge?.navigationStore.$showThinkingMode.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    /// Everything besides width and scale that sets how tall rows draw: the
    /// text size and how thinking is shown. The window's height ledger is keyed
    /// by it, so a change to either measures rows again.
    private static func windowMetrics(_ textSize: DynamicTypeSize, _ thinking: ThinkingDisplayMode) -> String {
        "\(textSize)|thinking:\(thinking.rawValue)"
    }

    private func scrollView(proxy: ScrollViewProxy) -> some View {
        rowActions.configure(
            onToggleToolbar: { id in toggleToolbar(for: id) },
            onReply: { msg in startReply(to: msg) },
            onScrollToMessage: { targetId in scrollToMessage(id: targetId, highlight: true, proxy: proxy) },
            onNavigateUserMessage: { id, dir in navigateUserMessage(from: id, direction: dir, proxy: proxy) },
            onZoomImage: { img in zoomedImage = img }
        )
        return ScrollView {
            scrollContent
        }
        .modifier(NativeChatScrollActivity(model: bridge?.scrollButton))
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // A turn of the phone: only the rows near the screen are laid out inside it
        // (`beginSizeTransition`). Not on the Mac, where a drag passes every width.
        .background(SizeTransitionReader { [scrollCoordinator] current, new in
            guard new.width != current.width else { return }
            scrollCoordinator.beginSizeTransition()
        })
        #endif
        .modifier(NativeDefaultBottomScrollAnchor(
            shouldAnchorBottom: scrollCoordinator.isPinnedToBottom && store.pendingScrollRestoration?.following != false && scrollCoordinator.activeRestoration == nil
        ))
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onChanged { _ in
                if activeToolbarMessageId != nil {
                    activeToolbarMessageId = nil
                }
            }
        )
        .onAppear {
            handleAppear(proxy: proxy)
        }
        .onChange(of: store.currentChatId) { oldID, _ in
            handleChatIdChanged(previousChatID: oldID, proxy: proxy)
        }
        .onChange(of: displayedRows) { oldRows, newRows in
            handleDisplayedRowsChanged(oldRows: oldRows, newRows: newRows, proxy: proxy)
        }
        .onReceive(store.scrollCommands) { cmd in
            handleScrollCommand(cmd, proxy: proxy)
        }
    }

    #if os(iOS)
    /// The owned list (docs/plans/native-chat-viewport-owner.md): one UIKit layout pass
    /// lays the rows out and places the offset, `NativeChatViewport` deciding where.
    /// Nothing here writes the offset or holds rows back for it.
    private var ownedList: some View {
        rowActions.configure(
            onToggleToolbar: { id in toggleToolbar(for: id) },
            onReply: { msg in startReply(to: msg) },
            onScrollToMessage: { targetId in showOwnedMessage(id: targetId, highlight: true) },
            onNavigateUserMessage: { id, dir in navigateOwnedUserMessage(from: id, direction: dir) },
            onZoomImage: { img in zoomedImage = img }
        )
        return OwnedListClearance(content: ownedListContent, handle: listHandle,
                                  foldedBottomInset: foldedBottomInset, fold: fold,
                                  onFold: { holdOwnedRowsWhileClearanceDrops(seconds: 0.4) })
            .reportRailEdges { edges in
                if ownedRailEdges != edges { ownedRailEdges = edges }
            }
            .overlay(alignment: .top) {
                if displayedRows.isEmpty {
                    Group {
                        if store.loadingState.phase == .ready {
                            emptyState
                        } else {
                            loadingState
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                        }
                    }
                    .padding(.top, NativeChatListScroller.edgePadding + (topInset > 0 ? topInset + NativeChatListScroller.rowSpacing : 0))
                    .padding(.horizontal, RailGutters.standard)
                }
            }
            .onAppear { handleOwnedAppear() }
            .onChange(of: store.currentChatId) { oldID, _ in
                handleOwnedChatChanged(previousChatID: oldID)
            }
            .onReceive(store.scrollCommands) { command in
                handleOwnedScrollCommand(command)
            }
            // A turn later: the first value arrives as SwiftUI subscribes, mid-update.
            .onReceive(listHandle.$isFollowing.removeDuplicates().receive(on: DispatchQueue.main)) { following in
                updatePinnedToBottom(following)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                holdOwnedRowsWhileClearanceDrops(seconds: 0.45)
            }
    }

    /// A send drops the composer's clearance twice: the keyboard going down, then the
    /// composer shrinking as its text clears. While the chat follows its end, new rows
    /// wait until the drop is over, so the sent message glides up once, above the
    /// composer as it will rest, rather than up behind the tall composer and then down
    /// with it (Peter, 5 November 2026: "anything over 1 line just appears").
    private func holdOwnedRowsWhileClearanceDrops(seconds: CFTimeInterval) {
        guard listHandle.isFollowingNow else { return }
        ownedHoldUntil = max(ownedHoldUntil, CACurrentMediaTime() + seconds)
    }

    /// Publishes the store's rows once the clearance has stopped dropping; a second drop
    /// (the composer after the keyboard) waits again.
    private func publishOwnedRowsAfterClearanceDrop() {
        guard !ownedFlushScheduled else { return }
        ownedFlushScheduled = true
        let wait = max(0, ownedHoldUntil - CACurrentMediaTime()) + 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            ownedFlushScheduled = false
            publishStoreRows()
        }
    }

    private var ownedListContent: NativeChatListScroller.Content {
        var content = NativeChatListScroller.Content()
        content.chatId = ownedChatId
        content.rows = displayedRows
        var states: [String: Int] = [:]
        if let id = activeToolbarMessageId { states[id, default: 0] |= 1 }
        if let id = highlightedMessageId { states[id, default: 0] |= 2 }
        content.rowStates = states
        if displayedTruncatedCount > 0 || isLoadingMore {
            content.header = AnyView(loadMoreBanner)
            content.headerKey = "\(displayedTruncatedCount)|\(isLoadingMore)"
        }
        content.topInset = topInset
        content.bottomInset = bottomInset
        content.leadingGutter = ownedRailEdges.contains(.leading) ? 0 : RailGutters.standard
        content.trailingGutter = ownedRailEdges.contains(.trailing) ? 0 : RailGutters.standard
        content.textMetrics = Self.windowMetrics(windowTextSize, thinkingMode)
        let store = store, bridge = bridge, actions = rowActions, thinking = thinkingMode
        let toolbar = activeToolbarMessageId, highlighted = highlightedMessageId
        content.makeRow = { row in
            AnyView(NativeChatRowContainerView(
                row: row,
                isToolbarOpen: toolbar == row.id,
                isHighlighted: highlighted == row.id,
                thinkingMode: thinking,
                store: store,
                bridge: bridge,
                actions: actions
            )
            .equatable())
        }
        return content
    }

    private func handleOwnedAppear() {
        // The web chat can change the setting (its panels' close button folds
        // them all) while this view is away; catch up whenever it is shown.
        if let bridge { Task { await bridge.syncShowThinking() } }
        listHandle.onNearTop = { requestLoadMore() }
        listHandle.onUserScroll = {
            if activeToolbarMessageId != nil { activeToolbarMessageId = nil }
        }
        listHandle.onRest = { syncOwnedPositionToWeb() }
        listHandle.onScrollActivityChanged = { [weak model = bridge?.scrollButton] moving in
            if model?.isScrolling != moving { model?.isScrolling = moving }
        }
        listHandle.onTrace = { [weak bridge] line in bridge?.handleConsoleLog(line) }
        let handle = listHandle, store = store, bridge = bridge
        store.captureLiveScrollSnapshot = { [weak handle, weak store, weak bridge] in
            guard let handle, let store else { return nil }
            return Self.ownedSnapshot(store: store, bridge: bridge, handle: handle)
        }
        if displayedTruncatedCount != store.truncatedCount {
            displayedTruncatedCount = store.truncatedCount
        }
        publishOwnedRows(store.rows)
        if let pending = store.pendingScrollRestoration {
            store.pendingScrollRestoration = nil
            restoreOwned(pending)
        } else {
            listHandle.enter()
        }
    }

    private func handleOwnedChatChanged(previousChatID: String?) {
        pendingLoadMoreAnchorId = nil
        isLoadingMore = false
        // Initial identity hydration can retain the very same mounted messages.
        // A genuine switch (including an unrelated first backfill) starts fresh.
        let previousIDs = Set(displayedRows.map(\.id))
        let isHydration = previousChatID == nil && store.rows.contains { previousIDs.contains($0.id) }
        if !isHydration { rowActions.rowStateRegistry.clear() }
        displayedTruncatedCount = store.truncatedCount
        // The list enters the new chat when its rows arrive with the chat's id.
        publishOwnedRows(store.rows)
        if let pending = store.pendingScrollRestoration {
            store.pendingScrollRestoration = nil
            restoreOwned(pending)
        }
    }

    /// Rows as they come: the list keeps what is on screen still through any change,
    /// so nothing is held for a coast, a jump or a restoration. Only a send's clearance
    /// drop holds them, for the sent message's glide.
    private func publishOwnedRows(_ rows: [NativeChatRow]) {
        let chatId = store.currentChatId
        let sameChat = chatId == ownedChatId
        if sameChat, !displayedRows.isEmpty, CACurrentMediaTime() < ownedHoldUntil {
            publishOwnedRowsAfterClearanceDrop()
            return
        }
        if !sameChat { ownedChatId = chatId }
        guard displayedRows != rows else { return }
        // The person's own message at the tail: the chat follows again.
        if sameChat, let last = rows.last, last.id != displayedRows.last?.id,
           case .user(let message) = last, message.isOwnMessage {
            listHandle.scrollToBottom(animated: true)
        }
        displayedRows = rows
    }

    private func handleOwnedScrollCommand(_ command: NativeChatScrollCommand) {
        switch command {
        case .enter:
            listHandle.enter()
        case .bottom(let animated):
            listHandle.scrollToBottom(animated: animated)
        case .userMessage(let direction):
            let userIds = ownedUserMessageIds()
            guard let target = direction == "down" ? userIds.last : userIds.first else { return }
            showOwnedMessage(id: target, highlight: true)
        case .message(let id, let highlight):
            showOwnedMessage(id: id, highlight: highlight)
        case .restore(let position):
            store.pendingScrollRestoration = nil
            restoreOwned(position)
        }
    }

    /// The web chat's place: its row held where the page had it, or the end.
    private func restoreOwned(_ position: NativeChatScrollPosition) {
        store.lastScrollSnapshot = position
        guard !position.following, let webRowId = position.webRowId,
              let rowID = store.resolveNativeRowId(forWebRowId: webRowId) else {
            listHandle.enter()
            return
        }
        listHandle.hold(rowID: rowID, screenOffset: position.offset, chatId: position.chatId)
    }

    private func showOwnedMessage(id: String, highlight: Bool) {
        listHandle.show(rowID: id, chatId: store.currentChatId)
        if highlight { highlightMessage(id: id) }
    }

    private func navigateOwnedUserMessage(from currentId: String, direction: String) {
        let userIds = ownedUserMessageIds()
        guard let index = userIds.firstIndex(of: currentId) else { return }
        let target = direction == "up" ? max(0, index - 1) : min(userIds.count - 1, index + 1)
        showOwnedMessage(id: userIds[target], highlight: true)
    }

    private func ownedUserMessageIds() -> [String] {
        store.rows.compactMap { row -> String? in
            if case .user(let message) = row { return message.id }
            return nil
        }
    }

    /// Where the reader is, for the page: following, or the first row below the bar.
    private static func ownedSnapshot(store: NativeChatMessageStore, bridge: AgentBridge?,
                                      handle: NativeChatListHandle) -> NativeChatScrollPosition? {
        let chatId = store.currentChatId ?? bridge?.currentSourceChatId ?? ""
        guard !chatId.isEmpty, !store.rows.isEmpty, let position = handle.position() else {
            return store.lastScrollSnapshot
        }
        guard !position.following, let rowID = position.rowID else {
            return NativeChatScrollPosition(chatId: chatId, webRowId: nil, offset: 0, following: true)
        }
        return NativeChatScrollPosition(chatId: chatId, webRowId: store.resolveWebRowId(forNativeRowId: rowID),
                                        offset: position.screenOffset, following: false)
    }

    private func syncOwnedPositionToWeb() {
        guard let snapshot = Self.ownedSnapshot(store: store, bridge: bridge, handle: listHandle) else { return }
        store.lastScrollSnapshot = snapshot
        bridge?.send(NativeChatScrollCoordinator.syncPayload(snapshot))
    }
    #endif

    private func handleDisappear() {
        #if os(iOS)
        if usesOwnedList {
            syncOwnedPositionToWeb()
            return
        }
        #endif
        scrollCoordinator.stopFollowAnimation()
        if let snap = scrollCoordinator.captureSnapshot() {
            store.lastScrollSnapshot = snap
            scrollCoordinator.sendSyncToWeb(snap)
        }
    }

    private func handleChatIdChanged(previousChatID: String?, proxy: ScrollViewProxy) {
        pendingLoadMoreAnchorId = nil
        isLoadingMore = false
        // Initial identity hydration can retain the very same mounted messages.
        // A genuine switch (including an unrelated first backfill) starts fresh.
        let previousIDs = Set(displayedRows.map(\.id))
        let isHydration = previousChatID == nil && store.rows.contains { previousIDs.contains($0.id) }
        if !isHydration { rowActions.rowStateRegistry.clear() }
        scrollCoordinator.resetForChatSwitch()
        displayedTruncatedCount = store.truncatedCount
        displayedRows = store.rows
        // The window takes the new chat's rows before it plans its end, so the
        // last chat's tail is never the band the new chat opens on.
        scrollCoordinator.updateWindowRows(displayedRows)
        consumePendingRestorationOrScrollBottom(proxy: proxy)
    }

    private func handleTruncatedCountChanged(_ newCount: Int) {
        if isLoadingMore {
            isLoadingMore = false
        }
        // Not on screen: taken with the rows when it is shown.
        guard screenIsShown else { return }
        #if os(iOS)
        if usesOwnedList {
            // The owned list lays out a banner change with its rows; nothing is held.
            if displayedTruncatedCount != newCount { displayedTruncatedCount = newCount }
            return
        }
        #endif
        if scrollCoordinator.shouldHoldRowPublication {
            scrollCoordinator.scheduleFlushHeldRowsAtRest()
        } else {
            if displayedTruncatedCount != newCount {
                displayedTruncatedCount = newCount
            }
            scrollCoordinator.scheduleAutoLoadCheck(delay: 0.25)
        }
    }

    private func handleBottomInsetChanged(dropping: Bool) {
        #if os(iOS)
        // The owned list takes a clearance change as its own displacement, in its layout.
        if usesOwnedList {
            if dropping { holdOwnedRowsWhileClearanceDrops(seconds: 0.4) }
            return
        }
        #endif
        guard scrollCoordinator.isPinnedToBottom, !scrollCoordinator.isRestoring else { return }
        scrollCoordinator.followTheKeyboard(dropping: dropping)
        scrollCoordinator.requestFollow()
    }

    private func handleStoreRowsChanged(_ newRows: [NativeChatRow]) {
        if isLoadingMore {
            isLoadingMore = false
        }
        // Not on screen: held, as through a coast, and drawn when it is shown.
        if !screenIsShown {
            store.invalidateDirtyRowTracking()
            return
        }
        #if os(iOS)
        if usesOwnedList {
            // Nothing is held: the list keeps what is on screen still through any change.
            if displayedTruncatedCount != store.truncatedCount { displayedTruncatedCount = store.truncatedCount }
            publishOwnedRows(newRows)
            return
        }
        #endif
        if scrollCoordinator.shouldHoldRowPublication {
            store.invalidateDirtyRowTracking()
            scrollCoordinator.scheduleFlushHeldRowsAtRest()
            return
        }
        if scrollCoordinator.holdsTailChange(from: displayedRows, to: newRows) {
            store.invalidateDirtyRowTracking()
            return
        }
        if displayedTruncatedCount != store.truncatedCount {
            displayedTruncatedCount = store.truncatedCount
        }
        #if os(iOS) && DEBUG
        if !displayedRows.isEmpty, newRows.count > displayedRows.count + 4 {
            scrollCoordinator.probeLanding(from: displayedRows.count, to: newRows.count)
        }
        #endif
        if displayedRows != newRows {
            displayedRows = newRows
        }
        scrollCoordinator.scheduleAutoLoadCheck(delay: 0.25)
    }

    private var scrollContent: some View {
        // Eager VStack for the active windowed chat rows so off-screen panels
        // above the viewport are already measured and rendered in the scroll
        // buffer — preventing top-of-viewport layout jumps when scrolling back up.
        VStack(alignment: .leading, spacing: 10) {
            if topInset > 0 {
                Color.clear.frame(height: topInset)
            }
            if displayedTruncatedCount > 0 || isLoadingMore {
                loadMoreBanner
            }
            if displayedRows.isEmpty {
                if store.loadingState.phase == .ready {
                    emptyState
                } else {
                    loadingState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            } else {
                if windowBand.snapshot.enabled {
                    VStack(alignment: .leading, spacing: 0) {
                        if windowBand.snapshot.top > 0 {
                            Color.clear.frame(height: windowBand.snapshot.top)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            chatRows(windowBand.snapshot.rows)
                        }
                        if windowBand.snapshot.bottom > 0 {
                            Color.clear.frame(height: windowBand.snapshot.bottom)
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: NativeChatFramesKey.self, value: [
                            "__rows": geo.frame(in: .named("NativeChatVStack")),
                            "__window:\(windowBand.snapshot.serial)": .zero
                        ])
                    })
                } else {
                    chatRows(displayedRows)
                }
            }
            if scrollerBottomInset > 0 {
                Color.clear.frame(height: max(0, scrollerBottomInset - Self.composerGapTrim))
            }
            // Bottom anchor placed AFTER bottomInset so scrolling to bottom
            // clears the floating ChatComposer and keyboard.
            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchor)
        }
        // Beside the system's tab rail the safe area already keeps a margin.
        .railGutters(12)
        .padding(.vertical, 12)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: NativeChatFramesKey.self,
                    value: ["__content": CGRect(origin: .zero, size: geo.size)]
                )
            }
        )
        .coordinateSpace(name: "NativeChatVStack")
        .onPreferenceChange(NativeChatFramesKey.self) { frames in
            scrollCoordinator.reconcileFrames(frames)
        }
        .background(
            NativeScrollViewIntrospector(coordinator: scrollCoordinator)
        )
    }

    private func handleAppear(proxy: ScrollViewProxy) {
        scrollCoordinator.bindRowStateRegistry(rowActions.rowStateRegistry)
        scrollCoordinator.configureWindow(rows: displayedRows, publication: windowBand)
        scrollCoordinator.windowTextMetrics = Self.windowMetrics(windowTextSize, thinkingMode)
        scrollCoordinator.shownAt = Date()
        // The web chat can change the setting (its panels' close button folds
        // them all) while this view is away; catch up whenever it is shown.
        if let bridge { Task { await bridge.syncShowThinking() } }
        scrollCoordinator.configure(
            store: store,
            bridge: bridge,
            topInset: topInset,
            onPinnedChange: { pinned in updatePinnedToBottom(pinned) },
            onNearTopLoadMore: { force in requestLoadMore(force: force) },
            onFlushHeldRows: { flushHeldRows() },
            onReleaseHeldTailRows: {
                publishStoreRows()
                // A jump that follows needs the held rows in the window now,
                // not at SwiftUI's next update.
                scrollCoordinator.updateWindowRows(store.rows)
            }
        )
        let coordinator = scrollCoordinator
        store.captureLiveScrollSnapshot = { [weak coordinator] in
            coordinator?.captureSnapshot()
        }
        if displayedTruncatedCount != store.truncatedCount {
            displayedTruncatedCount = store.truncatedCount
        }
        if displayedRows != store.rows {
            displayedRows = store.rows
        }
        if !displayedRows.isEmpty {
            consumePendingRestorationOrScrollBottom(proxy: proxy)
        }
    }

    private func handleDisplayedRowsChanged(oldRows: [NativeChatRow], newRows: [NativeChatRow], proxy: ScrollViewProxy) {
        scrollCoordinator.updateWindowRows(newRows)
        #if !os(iOS)
        if let anchorId = pendingLoadMoreAnchorId {
            pendingLoadMoreAnchorId = nil
            proxy.scrollTo(anchorId, anchor: .top)
            return
        }
        #else
        pendingLoadMoreAnchorId = nil
        #endif
        if store.pendingScrollRestoration != nil {
            consumePendingRestorationOrScrollBottom(proxy: proxy)
            return
        }
        if scrollCoordinator.activeRestoration != nil {
            scrollCoordinator.applyActiveRestorationStep()
            return
        }
        if oldRows.isEmpty && !newRows.isEmpty {
            openAtEnd(proxy: proxy)
            return
        }
        // If the user just sent a message at the tail, re-engage auto-follow.
        if let lastNew = newRows.last, lastNew.id != oldRows.last?.id,
           case .user(let msg) = lastNew, msg.isOwnMessage {
            scrollCoordinator.setFollowing(true)
        }
        guard scrollCoordinator.isPinnedToBottom else { return }
        scrollCoordinator.requestFollow()
        #if !os(iOS)
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
        #endif
    }

    private func chatRows(_ rows: [NativeChatRow]) -> some View {
        let markerOnly = scrollCoordinator.useMarkerFrames
        return ForEach(rows) { row in
            NativeChatRowContainerView(
                row: row,
                isToolbarOpen: activeToolbarMessageId == row.id,
                isHighlighted: highlightedMessageId == row.id,
                thinkingMode: thinkingMode,
                store: store,
                bridge: bridge,
                actions: rowActions
            )
            .equatable()
            .id(row.id)
            .background(
                NativeChatRowMarker(id: row.id, coordinator: scrollCoordinator)
            )
            .background(
                Group {
                    if !markerOnly {
                        GeometryReader { rowGeo in
                            Color.clear.preference(
                                key: NativeChatFramesKey.self,
                                value: [row.id: rowGeo.frame(in: .named("NativeChatVStack"))]
                            )
                        }
                    }
                }
            )
        }
    }

    private func toggleToolbar(for messageId: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if activeToolbarMessageId == messageId {
                activeToolbarMessageId = nil
            } else {
                activeToolbarMessageId = messageId
            }
        }
    }

    private func startReply(to message: NativeChatMessage) {
        let rawText = message.askUser?.question.isEmpty == false ? (message.askUser?.question ?? "") : message.content
        let collapsed = rawText
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = collapsed.count > 200 ? String(collapsed.prefix(199)) + "…" : collapsed
        let sender: String?
        if message.role == .user {
            sender = message.senderLabel ?? "You"
        } else {
            sender = message.respondent?.label ?? message.senderLabel ?? "Assistant"
        }
        let chatId = message.chatId ?? bridge?.currentSourceChatId ?? ""
        bridge?.setLocalReplyTarget(
            chatId: chatId,
            correlationId: message.id,
            senderDisplayName: sender,
            excerpt: excerpt,
            role: message.role.rawValue
        )
        bridge?.send([
            "type": "agent-framework:nativeChat:action",
            "op": "setReplyTarget",
            "chatId": chatId,
            "target": [
                "correlationId": message.id,
                "senderDisplayName": sender ?? "",
                "excerpt": excerpt,
                "role": message.role.rawValue,
            ],
        ])
        activeToolbarMessageId = nil
    }

    private func handleScrollCommand(_ command: NativeChatScrollCommand, proxy: ScrollViewProxy) {
        // A jump may target a row that is still held below the screen.
        scrollCoordinator.releaseHeldTailRows()
        switch command {
        case .enter:
            openAtEnd(proxy: proxy)
        case .bottom(let animated):
            scrollCoordinator.setFollowing(true)
            scrollCoordinator.requestFollow(forceInstant: !animated)
            #if !os(iOS)
            if !animated {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            #endif
        case .userMessage(let direction):
            let userIds = store.rows.compactMap { row -> String? in
                if case .user(let m) = row { return m.id }
                return nil
            }
            guard !userIds.isEmpty else { return }
            let targetId = direction == "down" ? userIds.last! : userIds.first!
            scrollToMessage(id: targetId, highlight: true, proxy: proxy)
        case .message(let id, let highlight):
            scrollToMessage(id: id, highlight: highlight, proxy: proxy)
        case .restore(let position):
            store.pendingScrollRestoration = nil
            scrollCoordinator.startRestoration(position, proxy: proxy)
        }
    }

    private func navigateUserMessage(from currentId: String, direction: String, proxy: ScrollViewProxy) {
        let userIds = store.rows.compactMap { row -> String? in
            if case .user(let m) = row { return m.id }
            return nil
        }
        guard let idx = userIds.firstIndex(of: currentId) else { return }
        let targetIdx = direction == "up" ? max(0, idx - 1) : min(userIds.count - 1, idx + 1)
        let targetId = userIds[targetIdx]
        scrollToMessage(id: targetId, highlight: true, proxy: proxy)
    }

    private func scrollToMessage(id: String, highlight: Bool, proxy: ScrollViewProxy) {
        scrollCoordinator.releaseHeldTailRows()
        scrollCoordinator.endRestoration()
        scrollCoordinator.setFollowing(false)
        if scrollCoordinator.stageWindowNavigation(id: id, completion: {
            if highlight { highlightMessage(id: id) }
        }) { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
        if highlight { highlightMessage(id: id) }
    }

    private func highlightMessage(id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            highlightedMessageId = id
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if highlightedMessageId == id {
                withAnimation(.easeOut(duration: 0.35)) {
                    highlightedMessageId = nil
                }
            }
        }
    }

    private func updatePinnedToBottom(_ pinned: Bool) {
        if pinned {
            if bridge?.scrollButton.show != false {
                bridge?.scrollButton.show = false
            }
            if bridge?.scrollButton.unreadCount != 0 {
                bridge?.scrollButton.unreadCount = 0
            }
        } else if !store.rows.isEmpty {
            if bridge?.scrollButton.show != true {
                bridge?.scrollButton.show = true
            }
        }
    }

    /// A chat that is entered (a switch, its first rows, the view appearing, the
    /// app's `.enter`) opens at its end and is held there while it settles.
    private func openAtEnd(proxy: ScrollViewProxy) {
        #if !os(iOS)
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        #endif
        scrollCoordinator.pinEntryToEnd()
        DispatchQueue.main.async {
            #if !os(iOS)
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            #endif
            scrollCoordinator.requestFollow(forceInstant: true)
        }
    }

    private func flushHeldRows() {
        #if os(iOS)
        if usesOwnedList {
            publishStoreRows()
            return
        }
        #endif
        // Rows held through a coast stay held when they only change what is
        // below the screen of a reader away from the tail.
        if scrollCoordinator.holdsTailChange(from: displayedRows, to: store.rows) { return }
        publishStoreRows()
    }

    private func publishStoreRows() {
        if displayedTruncatedCount != store.truncatedCount {
            displayedTruncatedCount = store.truncatedCount
        }
        #if os(iOS)
        if usesOwnedList {
            publishOwnedRows(store.rows)
            return
        }
        #endif
        if displayedRows != store.rows {
            displayedRows = store.rows
        }
    }

    private func consumePendingRestorationOrScrollBottom(proxy: ScrollViewProxy) {
        guard !displayedRows.isEmpty else { return }
        if let pending = store.pendingScrollRestoration {
            store.pendingScrollRestoration = nil
            scrollCoordinator.startRestoration(pending, proxy: proxy)
            return
        }
        if scrollCoordinator.activeRestoration != nil {
            scrollCoordinator.applyActiveRestorationStep()
            return
        }
        openAtEnd(proxy: proxy)
    }

    private static let bottomAnchor = "native-chat-bottom-anchor"
    /// Taken off the composer's clearance: this stack's own trailing space (its
    /// spacing around the clearance and anchor, and its bottom padding, 33 pt)
    /// comes on top of the clearance's gap, which left the last message about
    /// 49 pt above the composer's glass. Peter, 5 November 2026: "the gap is a
    /// bit big, halve it". About 24 pt now.
    private static let composerGapTrim: CGFloat = 25

    private func requestLoadMore(force: Bool = false) {
        guard (force || store.truncatedCount > 0), !isLoadingMore else { return }
        isLoadingMore = true
        #if !os(iOS)
        pendingLoadMoreAnchorId = displayedRows.first?.id
        #endif
        let chatId = store.currentChatId ?? bridge?.currentSourceChatId ?? ""
        bridge?.send([
            "type": "agent-framework:nativeChat:action",
            "op": "loadMore",
            "chatId": chatId,
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if isLoadingMore {
                isLoadingMore = false
                scrollCoordinator.scheduleAutoLoadCheck(delay: 0.25)
            }
        }
    }

    private var loadMoreBanner: some View {
        Button {
            requestLoadMore()
        } label: {
            HStack(spacing: 8) {
                if isLoadingMore {
                    RenderServerSpinner(size: 16)
                }
                Text(isLoadingMore ? "Loading earlier messages…" : "Load \(displayedTruncatedCount) more messages")
                    .font(.ripul(.footnote, weight: .medium))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ripul(.text).opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMore)
        .accessibilityIdentifier("NativeChatView.loadMore")
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            if store.loadingState.phase == .failed {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.ripulIcon(size: 24))
                    .foregroundStyle(.ripul(.textSecondary))
            } else if store.loadingState.fraction == nil {
                ProgressView()
                    .accessibilityLabel("Loading chat")
            }
            Text(store.loadingState.label)
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
                .accessibilityIdentifier("NativeChatView.loadingLabel")
            if let fraction = store.loadingState.fraction, store.loadingState.phase == .loading {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Chat loading progress")
                    .accessibilityIdentifier("NativeChatView.loadingProgress")
            }
            if let detail = store.loadingState.detail {
                Text(detail)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .monospacedDigit()
            }
            if store.loadingState.phase == .failed, let bridge {
                Button("Retry") {
                    guard let chatId = store.currentChatId else { return }
                    store.applyLoadingState(.loading, chatId: chatId)
                    bridge.send(["type": "agent-framework:nativeChat:action", "op": "retryLoad", "chatId": chatId])
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("NativeChatView.retryLoad")
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChatView.loading")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.ripulIcon(size: 28))
                .foregroundStyle(.ripul(.textTertiary))
            Text("No messages in this conversation yet.")
                .accessibilityIdentifier("NativeChatView.empty")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

/// The SwiftUI scroller's identifier. The owned list's scroll view carries it itself: put
/// on the list and its overlay, which make no one element, it replaced the identifiers of
/// the empty and loading states inside (`NativeChatView.empty` read "NativeChatView.scroller").
private struct NativeChatScrollerIdentifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.accessibilityIdentifier("NativeChatView.scroller") } else { content }
    }
}

#if os(iOS)
/// The owned list given the composer's clearance, folded or open. The fold is read here
/// and not in `NativeChatView`, so the composer folding as the chat scrolls away from its
/// end, and unfolding as it comes back, lays the list out again without running the
/// chat's body (`ComposerFoldState`). `onFold` holds new rows while the clearance drops,
/// as a drop the chat's body sees does.
private struct OwnedListClearance: View {
    let content: NativeChatListScroller.Content
    let handle: NativeChatListHandle
    let foldedBottomInset: CGFloat?
    let fold: ComposerFoldState?
    let onFold: () -> Void

    var body: some View {
        let folded = fold?.collapsed == true ? foldedBottomInset : nil
        var clearance = content
        if let folded { clearance.bottomInset = folded }
        return NativeChatList(content: clearance, handle: handle)
            .onChange(of: folded) { _, folded in
                if let folded, folded < content.bottomInset { onFold() }
            }
    }
}
#endif

/// Leaf publication: one assignment per band/data/filler change, never per scroll tick.
@available(iOS 16.0, macOS 14.0, *)
@MainActor
final class NativeChatWindowBand: ObservableObject {
    struct Snapshot {
        var enabled = false
        var rows: [NativeChatRow] = []
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var serial: UInt64 = 0
    }
    @Published var snapshot = Snapshot()
    let coordinator = NativeChatScrollCoordinator()

    init(rows: [NativeChatRow]) {
        coordinator.configureWindow(rows: rows, publication: self)
    }
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
final class NativeChatRowActions {
    let rowStateRegistry = NativeChatRowStateRegistry()
    var onToggleToolbar: ((String) -> Void)?
    var onReply: ((NativeChatMessage) -> Void)?
    var onScrollToMessage: ((String) -> Void)?
    var onNavigateUserMessage: ((String, String) -> Void)?
    var onZoomImage: ((NativeChatImageAttachment) -> Void)?

    init() {}

    func configure(
        onToggleToolbar: @escaping (String) -> Void,
        onReply: @escaping (NativeChatMessage) -> Void,
        onScrollToMessage: @escaping (String) -> Void,
        onNavigateUserMessage: @escaping (String, String) -> Void,
        onZoomImage: @escaping (NativeChatImageAttachment) -> Void
    ) {
        self.onToggleToolbar = onToggleToolbar
        self.onReply = onReply
        self.onScrollToMessage = onScrollToMessage
        self.onNavigateUserMessage = onNavigateUserMessage
        self.onZoomImage = onZoomImage
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatRowContainerView: View, Equatable {
    let row: NativeChatRow
    let isToolbarOpen: Bool
    let isHighlighted: Bool
    var thinkingMode: ThinkingDisplayMode = .open
    let store: NativeChatMessageStore
    let bridge: AgentBridge?
    let actions: NativeChatRowActions

    #if DEBUG
    nonisolated(unsafe) static var debugBodyEvaluationCount: Int = 0
    #endif

    static func == (lhs: NativeChatRowContainerView, rhs: NativeChatRowContainerView) -> Bool {
        lhs.row == rhs.row
            && lhs.isToolbarOpen == rhs.isToolbarOpen
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.thinkingMode == rhs.thinkingMode
    }

    /// The open panel's close button folds every chat's thinking, as the web's
    /// does, and an opened lozenge's pin opens them all. Both change the page's
    /// setting, which comes back to all views.
    private func setThinkingMode(_ mode: ThinkingDisplayMode) {
        guard let bridge else { return }
        Task { await bridge.setShowThinking(mode.rawValue) }
    }

    var body: some View {
        #if DEBUG
        let _ = {
            Self.debugBodyEvaluationCount += 1
        }()
        #endif
        rowContent
            .nativeChatRowStateRoot(registry: actions.rowStateRegistry, rowId: row.id)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row {
        case .gap(let gap):
            NativeConversationGapView(gap: gap)
        case .toolGroup(let group):
            NativeToolGroupRowView(group: group, bridge: bridge)
        case .thinking(let msg):
            // Draws nothing when thinking is hidden; the window then treats
            // the row as one without a slot.
            NativeThinkingPeerView(
                thinking: msg.thinking ?? "",
                isStreaming: msg.isThinkingStreaming,
                mode: thinkingMode,
                onSetMode: setThinkingMode
            )
        case .user(let msg):
            NativeUserMessageRowView(
                message: msg,
                bridge: bridge,
                isToolbarOpen: isToolbarOpen,
                isHighlighted: isHighlighted,
                onToggleToolbar: { actions.onToggleToolbar?(msg.id) },
                onReply: { actions.onReply?(msg) },
                onScrollToMessage: { targetId in actions.onScrollToMessage?(targetId) },
                onNavigateUserMessage: { direction in actions.onNavigateUserMessage?(msg.id, direction) },
                onZoomImage: { img in actions.onZoomImage?(img) }
            )
        case .note(let msg):
            NativeUserNoteRowView(
                message: msg,
                bridge: bridge,
                isToolbarOpen: isToolbarOpen,
                onToggleToolbar: { actions.onToggleToolbar?(msg.id) }
            )
        case .assistant(let msg):
            NativeAssistantMessageRowView(
                message: msg,
                store: store,
                bridge: bridge,
                isToolbarOpen: isToolbarOpen,
                isHighlighted: isHighlighted,
                thinkingMode: thinkingMode,
                onSetThinkingMode: setThinkingMode,
                onToggleToolbar: { actions.onToggleToolbar?(msg.id) },
                onReply: { actions.onReply?(msg) },
                onZoomImage: { img in actions.onZoomImage?(img) }
            )
        case .taskNotification(let msg):
            if let tn = msg.taskNotification {
                NativeTaskNotificationRowView(notification: tn)
            }
        case .systemStatus(let msg):
            NativeSystemStatusRowView(message: msg)
        case .error(let msg):
            NativeErrorRowView(message: msg)
        case .cliEvent(let msg):
            if let event = msg.cliEvent {
                NativeCliEventSeamRowView(messageId: msg.id, event: event)
            }
        }
    }
}

// MARK: - 1. Conversation Gap Row

@available(iOS 16.0, macOS 14.0, *)
private struct NativeConversationGapView: View {
    let gap: NativeChatGap

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.ripul(.separator))
                .frame(height: 1)
            Text(gap.text)
                .font(.ripul(size: 11, weight: .medium))
                .foregroundStyle(.ripul(.textTertiary))
                .lineLimit(1)
                .fixedSize()
            Rectangle()
                .fill(Color.ripul(.separator))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Conversation gap: \(gap.text)")
        .accessibilityIdentifier("NativeChat.gap.\(gap.id)")
    }
}

// MARK: - 2. Tool Group Row (NativeToolStripContent + TaskRuns + AgentComms)

@available(iOS 16.0, macOS 14.0, *)
struct NativeToolGroupRowView: View {
    let group: NativeChatToolGroup
    let bridge: AgentBridge?

    @Environment(\.nativeChatRowStateContext) private var rowStateContext
    @StateObject private var fallbackStripStore = NativeToolStripStore()

    private var activeStripStore: NativeToolStripStore {
        rowStateContext.registry?.toolStripStore(forRow: rowStateContext.rowId, group: group)
            ?? fallbackStripStore
    }

    var body: some View {
        let stripStore = activeStripStore
        VStack(alignment: .leading, spacing: 6) {
            if !group.tools.isEmpty {
                NativeToolStripContent(store: stripStore)
                    .frame(minHeight: 44)
            }

            ForEach(group.taskRuns) { item in
                NativeChatTaskRunEmbedView(item: item) {
                    let currentGroup = stripStore.latestGroup ?? group
                    Self.openToolDetails(for: currentGroup, initialCallId: item.id, bridge: bridge)
                }
            }

            ForEach(group.agentComms) { commsItem in
                NativeChatAgentCommsRowView(
                    item: commsItem,
                    bridge: bridge,
                    chatId: group.chatId
                ) {
                    let currentGroup = stripStore.latestGroup ?? group
                    Self.openToolDetails(for: currentGroup, initialCallId: commsItem.id, bridge: bridge)
                }
                .nativeChatRowStateScope("agentComms:\(commsItem.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            syncStripStore(for: group)
            bindStripHandler(to: stripStore, group: group, presentIfNeeded: true)
        }
        .onDisappear {
            stripStore.hide()
        }
        .onChange(of: group) { oldGroup, newGroup in
            let store = rowStateContext.registry?.toolStripStore(forRow: rowStateContext.rowId, group: newGroup)
                ?? fallbackStripStore
            if oldGroup.tools != newGroup.tools
                || oldGroup.updatedAt != newGroup.updatedAt
                || oldGroup.id != newGroup.id
                || oldGroup.chatId != newGroup.chatId {
                NativeChatRowStateRegistry.syncToolStripStore(store, with: newGroup)
            } else {
                store.latestGroup = newGroup
            }
            bindStripHandler(to: store, group: newGroup, presentIfNeeded: false)
        }
        .accessibilityIdentifier("NativeChat.toolGroup.\(group.id)")
    }

    private func syncStripStore(for targetGroup: NativeChatToolGroup) {
        NativeChatRowStateRegistry.syncToolStripStore(activeStripStore, with: targetGroup)
    }

    private func bindStripHandler(
        to store: NativeToolStripStore,
        group targetGroup: NativeChatToolGroup,
        presentIfNeeded: Bool
    ) {
        store.latestGroup = targetGroup
        let handler: ([String: Any]) -> Void = { [weak store] event in
            let currentGroup = store?.latestGroup ?? targetGroup
            Self.handleStripEvent(event, for: currentGroup, bridge: bridge)
        }
        if presentIfNeeded || !store.isPresented {
            store.present(send: handler)
        } else {
            store.updateHandler(handler)
        }
    }

    static func handleStripEvent(
        _ event: [String: Any],
        for group: NativeChatToolGroup,
        bridge: AgentBridge?
    ) {
        guard let type = event["type"] as? String else { return }
        if type == "agent-framework:toolStrip:select",
           let toolId = event["toolId"] as? String {
            let matchingIds = group.callIdsByToolId[toolId] ?? [toolId]
            let latestCallId = matchingIds.last ?? toolId
            openToolDetails(for: group, initialCallId: latestCallId, bridge: bridge)
        } else if type == "agent-framework:toolStrip:defaultAction",
                  let toolId = event["toolId"] as? String {
            let matchingIds = group.callIdsByToolId[toolId] ?? [toolId]
            let latestCallId = matchingIds.last ?? toolId
            let actionId = event["actionId"] as? String ?? ""
            bridge?.send([
                "type": "agent-framework:nativeChat:action",
                "op": "defaultToolAction",
                "chatId": group.chatId,
                "groupId": group.id,
                "toolId": latestCallId,
                "actionId": actionId,
            ])
        }
    }

    static func openToolDetails(
        for group: NativeChatToolGroup,
        initialCallId: String,
        bridge: AgentBridge?
    ) {
        // 1. Open immediately with our local `ToolCallDetail` snapshots so offline/preview harnesses
        //    and live rows show all calls in the row with the tapped call unfolded right away.
        if !group.calls.isEmpty, let bridge {
            var seenIds = Set<String>()
            let uniqueCalls = group.calls.filter { seenIds.insert($0.id).inserted }
            let title = uniqueCalls.count == 1
                ? (uniqueCalls.first?.commandPresentation?.label ?? uniqueCalls.first?.toolName ?? "Tool call")
                : "Tool calls"
            bridge.toolCallDetails.apply(
                ToolCallDetailsRequest(
                    requestId: "\(group.chatId):\(group.id)",
                    title: title,
                    calls: uniqueCalls,
                    initialCallId: initialCallId,
                    chatId: group.chatId
                ),
                opening: true
            )
        }
        // 2. Also ask the web forwarder to push any fresher details for this group
        bridge?.send([
            "type": "agent-framework:nativeChat:action",
            "op": "openToolDetails",
            "chatId": group.chatId,
            "groupId": group.id,
            "callIds": group.allCallIds,
            "initialCallId": initialCallId,
        ])
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatTaskRunEmbedView: View {
    let item: NativeChatTaskRunItem
    let onOpen: () -> Void

    #if os(iOS)
    @Environment(\.nativeChatRowStateContext) private var rowStateContext
    @StateObject private var fallbackState = NativeTaskRunState()

    private var activeState: NativeTaskRunState {
        rowStateContext.registry?.taskRunState(forRow: rowStateContext.rowId, item: item)
            ?? fallbackState
    }
    #endif

    var body: some View {
        #if os(iOS)
        let state = activeState
        VStack(alignment: .leading, spacing: 0) {
            NativeTaskRunRow(kind: item.kind, state: state)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .onAppear {
            if state.snapshot != item.snapshot {
                state.snapshot = item.snapshot
            }
            state.open = onOpen
        }
        .onChange(of: item.snapshot) { _, next in
            state.snapshot = next
            state.open = onOpen
        }
        #else
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: item.kind == .workflow ? "point.3.connected.trianglepath.dotted" : "sparkles")
                    .foregroundStyle(.ripul(.info))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.snapshot.title).font(.ripul(.subheadline, weight: .semibold))
                    Text(item.snapshot.detail).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.ripulIcon(.caption2)).foregroundStyle(.ripul(.textTertiary))
            }
            .padding(10)
            .background(.ripul(.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        #endif
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatAgentCommsRowView: View {
    let item: NativeChatAgentCommsItem
    var bridge: AgentBridge? = nil
    var chatId: String? = nil
    let onOpen: () -> Void
    @NativeRowState("isExpanded") private var isExpanded = false
    @NativeRowState("showCallDetails") private var showCallDetails = false

    var body: some View {
        let comms = item.presentation
        let isError = comms.status.tone == "error"
        if comms.kind == "present" && !isError {
            NativeChatSessionListView(
                items: comms.sessions ?? [],
                title: comms.title,
                emptyText: comms.status.tone == "pending" ? "Loading chats…" : "No chats to display",
                framed: true,
                bridge: bridge,
                sourceChatId: chatId
            )
            .accessibilityIdentifier("NativeChat.agentComms.\(item.id)")
        } else {
            standardCardBody(comms: comms, isError: isError)
        }
    }

    @ViewBuilder
    private func standardCardBody(comms: AgentCommsPresentation, isError: Bool) -> some View {
        let statusColor: Color = isError
            ? .ripul(.danger)
            : comms.status.tone == "pending"
                ? .ripul(.warning)
                : .ripul(.textSecondary)
        let titleLine = comms.target.name.isEmpty ? comms.verb : "\(comms.verb) \(comms.target.name)"

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isError ? "xmark.circle.fill" : "bubble.left.and.bubble.right.fill")
                        .font(.ripulIcon(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleLine)
                            .font(.ripul(.subheadline, weight: .semibold))
                            .foregroundStyle(.ripul(.text))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if !comms.status.text.isEmpty {
                            Text(comms.status.text)
                                .font(.ripul(.caption))
                                .foregroundStyle(statusColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.ripulIcon(.caption2, weight: .semibold))
                        .foregroundStyle(.ripul(.textTertiary))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let sessions = comms.sessions {
                        NativeChatSessionListView(
                            items: sessions,
                            title: nil,
                            emptyText: comms.kind == "search" ? "No matching chats" : "No other agents",
                            framed: false,
                            bridge: bridge,
                            sourceChatId: chatId
                        )
                    }

                    if let sent = comms.sent, !sent.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sent message")
                                .font(.ripul(.caption2, weight: .semibold))
                                .foregroundStyle(.ripul(.textTertiary))
                            NativeChatMarkdownBody(content: sent)
                                .nativeChatRowStateScope("sent")
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.ripul(.text).opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    if let reply = comms.reply, !reply.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reply")
                                .font(.ripul(.caption2, weight: .semibold))
                                .foregroundStyle(.ripul(.textTertiary))
                            NativeChatMarkdownBody(content: reply)
                                .nativeChatRowStateScope("reply")
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.ripul(.text).opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    if let err = item.detail?.error, !err.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Error")
                                .font(.ripul(.caption2, weight: .semibold))
                                .foregroundStyle(.ripul(.danger))
                            Text(err)
                                .font(.ripul(.caption, family: .code))
                                .foregroundStyle(.ripul(.danger))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.ripul(.danger).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    if let caption = comms.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textTertiary))
                    }

                    if let detail = item.detail {
                        DisclosureGroup("Call details", isExpanded: $showCallDetails) {
                            VStack(alignment: .leading, spacing: 6) {
                                if !detail.arguments.isEmpty {
                                    NativeToolCodeBlock(text: detail.arguments, title: "Arguments", titleFont: .ripul(.caption2, weight: .semibold), syntax: .json)
                                        .nativeChatRowStateScope("args")
                                }
                                if let res = detail.result, !res.isEmpty {
                                    NativeToolCodeBlock(text: res, title: "Result", titleFont: .ripul(.caption2, weight: .semibold), syntax: .automatic)
                                        .nativeChatRowStateScope("result")
                                }
                                Button("Open in sheet", action: onOpen)
                                    .font(.ripul(.caption, weight: .medium))
                                    .foregroundStyle(.ripul(.info))
                                    .buttonStyle(.plain)
                            }
                            .padding(.top, 6)
                        }
                        .font(.ripul(.caption, weight: .medium))
                        .foregroundStyle(.ripul(.textSecondary))
                    } else {
                        Button("Call details", action: onOpen)
                            .font(.ripul(.caption, weight: .medium))
                            .foregroundStyle(.ripul(.info))
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ripul(.text).opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.ripul(.separator), lineWidth: 1)
        )
        .accessibilityIdentifier("NativeChat.agentComms.\(item.id)")
    }
}

// MARK: - 3. Thinking Peer Row / Collapsible Thinking Section

/// A turn's thinking, drawn as the web's `ThinkingPeer` draws it for the same
/// setting: nothing, a lozenge that opens it, or the whole text under a header.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeThinkingPeerView: View {
    let thinking: String
    let isStreaming: Bool
    let mode: ThinkingDisplayMode
    /// Sets every chat's thinking display: the open panel's close button
    /// folds them all, an opened lozenge's pin opens them all.
    let onSetMode: (ThinkingDisplayMode) -> Void

    @NativeRowState("thinking.isExpanded") private var isExpanded: Bool = false

    var body: some View {
        switch mode {
        case .none:
            EmptyView()
        case .folded:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    foldedToggle
                    if isExpanded {
                        Spacer(minLength: 8)
                        pinButton
                    }
                }
                if isExpanded {
                    thinkingPanel(withHeader: false)
                }
            }
        case .open:
            thinkingPanel(withHeader: true)
        }
    }

    /// On an opened lozenge, level with its head: switches to Open, so every
    /// chat's thinking stays open and none needs opening again (Peter, 26
    /// October 2026). It sits where the open panel's close button does, so
    /// the two trade places.
    private var pinButton: some View {
        Button {
            onSetMode(.open)
        } label: {
            Image(systemName: "pin")
                .font(.ripulIcon(size: 11, weight: .semibold))
                .foregroundStyle(.ripul(.textTertiary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .accessibilityLabel("Keep Thinking Open")
        .accessibilityIdentifier("NativeChat.thinking.pin")
    }

    private var foldedToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                statusIcon
                Text(isStreaming ? "Thinking…" : (isExpanded ? "Hide Thinking" : "Show Thinking"))
                    .font(.ripul(.caption, weight: .medium))
                    .foregroundStyle(.ripul(.textSecondary))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.ripulIcon(size: 10, weight: .semibold))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.ripul(.surface))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.ripul(.separator), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("NativeChat.thinking.toggle")
    }

    /// The text on the web's tint, with its accent bar down the leading edge.
    /// Open adds a header: what it is, and a close button. No length: Peter
    /// found a count irrelevant (26 October 2026).
    private func thinkingPanel(withHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if withHeader {
                HStack(spacing: 6) {
                    statusIcon
                    Text(isStreaming ? "Thinking…" : "Thinking")
                        .font(.ripul(.caption, weight: .semibold))
                        .foregroundStyle(.ripul(.info))
                    Spacer(minLength: 8)
                    Button {
                        onSetMode(.folded)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.ripulIcon(size: 10, weight: .semibold))
                            .foregroundStyle(.ripul(.textTertiary))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fold Thinking")
                    .accessibilityIdentifier("NativeChat.thinking.fold")
                }
            }
            NativeChatMarkdownBody(content: thinking)
                .nativeChatRowStateScope("thinking")
                .font(.ripul(.callout))
                .foregroundStyle(.ripul(.textSecondary))
        }
        .padding(.leading, 13)
        .padding([.trailing, .vertical], 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ripul(.info).opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.ripul(.info))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A container of its own, so the close button keeps its identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChat.thinking.content")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isStreaming {
            RenderServerSpinner(color: .ripul(.info), size: 12)
        } else {
            Image(systemName: "brain.head.profile")
                .font(.ripulIcon(size: 11, weight: .semibold))
                .foregroundStyle(.ripul(.info))
        }
    }
}

// MARK: - 4. User Message Row (Quotes, Attachments, Context Tags, Group Avatar, Swipe-to-Reply, Action Lozenges)

@available(iOS 16.0, macOS 14.0, *)
private struct NativeUserMessageRowView: View {
    let message: NativeChatMessage
    let bridge: AgentBridge?
    let isToolbarOpen: Bool
    let isHighlighted: Bool
    let onToggleToolbar: () -> Void
    let onReply: () -> Void
    let onScrollToMessage: (String) -> Void
    let onNavigateUserMessage: (String) -> Void
    let onZoomImage: (NativeChatImageAttachment) -> Void

    @NativeRowState("user.expandedTagId") private var expandedTagId: String? = nil

    private var showsGroupIncomingAvatar: Bool {
        message.isGroupChat && !message.isOwnMessage
    }

    var body: some View {
        VStack(alignment: showsGroupIncomingAvatar ? .leading : .trailing, spacing: 4) {
            if showsGroupIncomingAvatar {
                let senderText = (message.senderLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                NativeAdaptiveGroupBubbleLayout(hasSender: !senderText.isEmpty) {
                    groupBubbleChrome
                    if let sender = message.senderAgent {
                        NativeChatAgentAvatar(sender: sender, sessionList: bridge?.sessionList)
                    } else {
                        NativeParticipantAvatarView(
                            name: message.senderLabel ?? "Participant",
                            avatarUrl: message.avatarUrl,
                            identity: message.senderUserId ?? message.senderLabel ?? "Participant",
                            size: 30
                        )
                    }
                    Text(senderText)
                        .font(.ripul(.caption, weight: .semibold))
                        .foregroundStyle(.ripul(.accent))
                        .lineLimit(1)
                    bubbleInnerContent(includeSenderHeader: false)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onToggleToolbar()
                        }
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 44)
                    bubbleCard
                }
            }
        }
        .modifier(NativeSwipeToReplyModifier(onTrigger: onReply))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChat.userMessage.\(message.id)")
    }

    private var groupBubbleChrome: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.ripul(.accent).opacity(0.75))
                .frame(width: 3)
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ripul(.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ripul(.accent).opacity(0.08))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(bubbleStroke, lineWidth: isHighlighted ? 2 : 1)
        )
        // An incoming bubble's actions start from its left edge, so a short one
        // does not push them off the screen.
        .overlay(alignment: .topLeading) {
            if isToolbarOpen { edgeActions(from: .leading) }
        }
        .overlay(alignment: .bottomTrailing) { edgeTime }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            onToggleToolbar()
        }
    }

    private var bubbleCard: some View {
        HStack(spacing: 0) {
            if showsGroupIncomingAvatar {
                Rectangle()
                    .fill(Color.ripul(.accent).opacity(0.75))
                    .frame(width: 3)
            }

            bubbleInnerContent(includeSenderHeader: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if !showsGroupIncomingAvatar {
                Rectangle()
                    .fill(Color.ripul(.accent))
                    .frame(width: 3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ripul(.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ripul(.accent).opacity(0.08))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(bubbleStroke, lineWidth: isHighlighted ? 2 : 1)
        )
        // What a tap reveals, on the bubble's edges as the web chat has them:
        // over the bubble, so it never moves. Anchored at its right, running left
        // past a short bubble rather than squeezing into it.
        .overlay(alignment: .topTrailing) {
            if isToolbarOpen { edgeActions(from: .trailing) }
        }
        .overlay(alignment: .bottomTrailing) { edgeTime }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            onToggleToolbar()
        }
    }

    private var bubbleStroke: Color {
        isHighlighted ? Color.ripul(.info) : Color.ripul(.separator)
    }

    /// The actions on the bubble's top edge, at their own width from one side.
    private func edgeActions(from side: HorizontalEdge) -> some View {
        HStack(spacing: 6) { userActions }
            .fixedSize()
            .padding(side == .leading ? .leading : .trailing, 10)
            // Centred on the top edge. An overlay shown behind an `if` drops its
            // alignment guides, so it is moved by half a pill instead.
            .offset(y: -NativeEdgeMetrics.pillHeight / 2)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("NativeChat.userToolbar.\(message.id)")
    }

    @ViewBuilder
    private var edgeTime: some View {
        if isToolbarOpen && message.timestamp > 0 {
            NativeEdgeTime(timestamp: message.timestamp, ground: Color.ripul(.surface),
                           tint: Color.ripul(.accent).opacity(0.08), outline: bubbleStroke)
        }
    }

    @ViewBuilder
    private func bubbleInnerContent(includeSenderHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if includeSenderHeader, showsGroupIncomingAvatar, let sender = message.senderLabel, !sender.isEmpty {
                Text(sender)
                    .font(.ripul(.caption, weight: .semibold))
                    .foregroundStyle(.ripul(.accent))
            } else if let sender = message.senderLabel, !sender.isEmpty, message.isGroupChat, !showsGroupIncomingAvatar {
                HStack(spacing: 4) {
                    Text(sender)
                        .font(.ripul(.caption2, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                    if message.isVoice {
                        Image(systemName: "waveform")
                            .font(.ripulIcon(size: 10))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }
            } else if message.isVoice {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.ripulIcon(size: 10))
                    Text("Voice")
                        .font(.ripul(.caption2, weight: .medium))
                }
                .foregroundStyle(.ripul(.textSecondary))
            }

            // Quoted reply banner
            if let quote = message.replyQuote {
                Button {
                    onScrollToMessage(quote.correlationId)
                } label: {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.ripul(.accent))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            if let sender = quote.senderDisplayName, !sender.isEmpty {
                                Text(sender)
                                    .font(.ripul(.caption2, weight: .semibold))
                                    .foregroundStyle(.ripul(.accent))
                            }
                            Text(quote.excerpt)
                                .font(.ripul(.caption))
                                .foregroundStyle(.ripul(.textSecondary))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        Spacer(minLength: 0)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ripul(.text).opacity(0.05))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NativeChat.replyQuote.\(quote.correlationId)")
            }

            // Image attachments
            if !message.imageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.imageAttachments) { img in
                            NativeChatAttachmentThumbnail(attachment: img) {
                                onZoomImage(img)
                            }
                        }
                    }
                }
            }

            // File attachments
            if !message.fileAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.fileAttachments) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.ripulIcon(size: 12))
                                .foregroundStyle(.ripul(.accent))
                            Text(file.name)
                                .font(.ripul(.caption, weight: .medium))
                                .foregroundStyle(.ripul(.text))
                                .lineLimit(1)
                            if let bytes = file.sizeBytes, bytes > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                    .font(.ripul(.caption2))
                                    .foregroundStyle(.ripul(.textTertiary))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.ripul(.text).opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }

            // Context tag pills
            if !message.contextTags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.contextTags) { tag in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        expandedTagId = expandedTagId == tag.id ? nil : tag.id
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: contextTagSymbol(tag.tagName))
                                            .font(.ripulIcon(size: 10))
                                        Text(contextTagDisplayLabel(tag))
                                            .font(.ripul(.caption2, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.ripul(.text).opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let activeId = expandedTagId,
                       let tag = message.contextTags.first(where: { $0.id == activeId }),
                       !tag.content.isEmpty {
                        Text(tag.content)
                            .font(.ripul(.caption2, family: .code))
                            .foregroundStyle(.ripul(.textSecondary))
                            .lineLimit(8)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.ripul(.text).opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }

            // Message prose
            if !message.content.isEmpty {
                NativeChatMarkdownBody(content: message.content, contextMentions: true)
                    .equatable()
            }

            // Context picked in the composer, after the words as on the web
            ForEach(message.contextAttachments) { attachment in
                NativeContextAttachmentCard(attachment: attachment)
                    .nativeChatRowStateScope("contextAttachment:\(attachment.id)")
            }

            // Agent / scheduled delivery status caption
            if let status = message.deliveryStatus, !status.isEmpty {
                Text(status)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
        }
    }

    /// What a tap on the bubble reveals on its top edge.
    @ViewBuilder
    private var userActions: some View {
        NativeMessageActions(message: message, bridge: bridge, includesSpeech: message.senderAgent != nil, onReply: onReply)

        if message.senderAgent == nil {
            NativeBubbleActionLozenge(
                title: nil,
                systemImage: "chevron.up",
                accessibilityLabel: "Previous user message"
            ) {
                onNavigateUserMessage("up")
            }

            NativeBubbleActionLozenge(
                title: nil,
                systemImage: "chevron.down",
                accessibilityLabel: "Next user message"
            ) {
                onNavigateUserMessage("down")
            }
        }
    }

    private func contextTagSymbol(_ tagName: String) -> String {
        switch tagName {
        case "ide_opened_file": return "doc.text"
        case "ide_selection": return "selection.pin.in.out"
        case "context": return "link"
        default: return "info.circle"
        }
    }

    private func contextTagDisplayLabel(_ tag: NativeContextTag) -> String {
        switch tag.tagName {
        case "ide_opened_file":
            let path = tag.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = (path as NSString).lastPathComponent
            return last.isEmpty ? "Opened file" : last
        case "ide_selection":
            return "Selection"
        default:
            return tag.label
        }
    }
}

/// A context attachment sent with a user message: its title and source until
/// tapped, then what was attached. The web's `ComposerContextAttachments` card.
struct NativeContextAttachmentCard: View {
    let attachment: NativeContextAttachment

    @NativeRowState("contextAttachment.isExpanded") private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: attachment.icon.systemImage)
                        .font(.ripulIcon(size: 16))
                        .foregroundStyle(attachment.icon == .instructions ? .ripul(.accent) : .ripul(.textSecondary))
                        .frame(width: 34, height: 34)
                        .background(Color.ripul(.text).opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.title)
                            .font(.ripul(.subheadline, weight: .semibold))
                            .foregroundStyle(.ripul(.text))
                        if !attachment.source.isEmpty {
                            Text(attachment.source)
                                .font(.ripul(.caption))
                                .foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.ripulIcon(size: 12, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides what was attached")

            if isExpanded {
                Rectangle()
                    .fill(.ripul(.separator))
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(attachment.scope)
                        Spacer(minLength: 0)
                        Text("Captured \(attachment.capturedLabel)")
                    }
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    Text(attachment.content.isEmpty ? "No text was included with this attachment." : attachment.content)
                        .font(.ripul(.footnote))
                        .foregroundStyle(.ripul(.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
        }
        .background(.ripul(.surface), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.ripul(.separator), lineWidth: 1)
        )
        // A tap in the card is the card's, not the bubble's (the web stops it too).
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChat.contextAttachment")
    }
}

// MARK: - 5. Assistant Message & Interactive Question Row

@available(iOS 16.0, macOS 14.0, *)
private struct NativeAssistantMessageRowView: View {
    let message: NativeChatMessage
    let store: NativeChatMessageStore
    let bridge: AgentBridge?
    let isToolbarOpen: Bool
    let isHighlighted: Bool
    let thinkingMode: ThinkingDisplayMode
    let onSetThinkingMode: (ThinkingDisplayMode) -> Void
    let onToggleToolbar: () -> Void
    let onReply: () -> Void
    let onZoomImage: (NativeChatImageAttachment) -> Void

    @NativeRowState("assistant.showRespondentMeta") private var showRespondentMeta = false
    @NativeRowState("assistant.selectedTabIndex") private var selectedTabIndex = 0
    @State private var metaCopiedFeedback = false
    @NativeRowState("assistant.multiSelectedValues") private var multiSelectedValues: Set<String> = []
    @NativeRowState("assistant.selectedDate", affectsHeight: false) private var selectedDate: Date = Date()
    @State private var passwordText: String = ""

    private var effectiveTabs: [NativeMessageTab] {
        if !message.tabs.isEmpty { return message.tabs }
        return message.askUser?.tabs ?? []
    }

    private var effectiveTable: NativeMessageTable? {
        message.table ?? message.askUser?.table
    }

    private var isHighContext: Bool {
        (message.respondent?.contextPercent ?? 0) >= 90
    }

    /// This turn's thinking, unless the setting hides it.
    private var shownThinking: String? {
        guard thinkingMode != .none, let thinking = message.thinking, !thinking.isEmpty else { return nil }
        return thinking
    }

    private var isMediaOnly: Bool {
        (!message.imageAttachments.isEmpty || !message.videoAttachments.isEmpty)
            && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (message.askUser?.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (message.askUser?.options.isEmpty ?? true)
            && shownThinking == nil
            && effectiveTable == nil
            && effectiveTabs.isEmpty
    }

    var body: some View {
        if isMediaOnly {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.videoAttachments) { NativeChatVideoView(attachment: $0) }
                NativeAssistantImagesView(attachments: message.imageAttachments, onZoomImage: onZoomImage)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("NativeChat.assistantMessage.\(message.id)")
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                // Expandable turn metadata panel (opened via respondent lozenge in toolbar or top notch)
                if showRespondentMeta, let resp = message.respondent {
                    respondentMetadataPanel(resp)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // This turn's thinking, drawn as the setting says
                if let thinking = shownThinking {
                    NativeThinkingPeerView(
                        thinking: thinking,
                        isStreaming: message.isThinkingStreaming,
                        mode: thinkingMode,
                        onSetMode: onSetThinkingMode
                    )
                }

                // Tab bar when message carries structured tabs
                if !effectiveTabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(effectiveTabs.enumerated()), id: \.offset) { idx, tab in
                                Button {
                                    selectedTabIndex = idx
                                } label: {
                                    Text(tab.label)
                                        .font(.ripul(.caption, weight: selectedTabIndex == idx ? .semibold : .regular))
                                        .foregroundStyle(selectedTabIndex == idx ? Color.ripul(.text) : Color.ripul(.textSecondary))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(selectedTabIndex == idx ? Color.ripul(.accent).opacity(0.18) : Color.ripul(.text).opacity(0.05))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    let clampedIdx = min(max(0, selectedTabIndex), effectiveTabs.count - 1)
                    let activeTab = effectiveTabs[clampedIdx]
                    if activeTab.markdown {
                        NativeChatMarkdownBody(content: activeTab.content, streamsByBlock: true)
                            .equatable()
                            .nativeChatRowStateScope("tab:\(clampedIdx)")
                    } else {
                        NativeToolCodeBlock(text: activeTab.content, title: activeTab.label, syntax: .automatic)
                            .nativeChatRowStateScope("tab:\(clampedIdx)")
                    }
                }

                // Main prose or Interactive Question
                if let ask = message.askUser {
                    interactiveQuestionSection(ask)
                } else if !message.content.isEmpty {
                    NativeChatMarkdownBody(content: message.content, streamsByBlock: true)
                        .equatable()
                        .nativeChatRowStateScope("content")
                } else if shownThinking == nil && effectiveTable == nil && message.imageAttachments.isEmpty && message.videoAttachments.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.ripulIcon(.caption2))
                            .foregroundStyle(.ripul(.textTertiary))
                        Text(message.label ?? message.method ?? "Assistant")
                            .font(.ripul(.footnote, weight: .medium))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }

                // Structured Table when present
                if let table = effectiveTable {
                    NativeChatStructuredTableView(table: table, options: message.askUser?.options ?? [],
                                                  disabled: (message.askUser?.completed ?? false) || (message.askUser?.submitting ?? false)) { option in
                        if let ask = message.askUser { selectOption(option, ask: ask) }
                    }
                }

                ForEach(message.videoAttachments) { NativeChatVideoView(attachment: $0) }

                // Attached / generated images
                if !message.imageAttachments.isEmpty {
                    NativeAssistantImagesView(
                        attachments: message.imageAttachments,
                        onZoomImage: onZoomImage
                    )
                }

                if let speech = message.speech, let call = message.toolCall?.detail {
                    NativeChatSpeechDeliveryView(speech: speech, call: call, chatId: message.chatId, bridge: bridge)
                }

                // Words that went back to another agent as its reply say so: in the
                // chat they look like an answer to whoever is reading.
                if let status = message.deliveryStatus, !status.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.ripulIcon(size: 10))
                        Text(status)
                            .font(.ripul(.caption))
                    }
                    .foregroundStyle(.ripul(.textSecondary))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("NativeChat.assistantDeliveryStatus.\(message.id)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Self.cardGround)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: isHighlighted ? 2 : 1)
            )
            // The respondent label, and what a tap reveals, on the card's edges as
            // the web chat has them: over the card, so it never moves.
            .overlay(alignment: .top) {
                NativeEdgeActions(showsActions: isToolbarOpen) {
                    if isToolbarOpen || showRespondentMeta {
                        respondentActionLozenge
                    } else {
                        respondentNotchLabel
                    }
                } actions: {
                    assistantActions
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("NativeChat.assistantToolbar.\(message.id)")
            }
            .overlay(alignment: .bottomTrailing) {
                if isToolbarOpen && message.timestamp > 0 {
                    NativeEdgeTime(timestamp: message.timestamp, ground: Color.ripul(.canvas),
                                   tint: Self.cardGround, outline: cardStroke)
                }
            }
            .padding(.top, NativeEdgeMetrics.pillHeight / 2)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                onToggleToolbar()
            }
        }
        .modifier(NativeSwipeToReplyModifier(onTrigger: onReply))
        .onAppear {
            if let answered = message.askUser?.selectedValues, !answered.isEmpty {
                multiSelectedValues = Set(answered)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChat.assistantMessage.\(message.id)")
    }

    @ViewBuilder
    private var respondentNotchLabel: some View {
        let resp = message.respondent
        let identity = ModelIdentity.resolve(modelId: resp?.modelId ?? resp?.label ?? message.senderLabel)
        let label = resp?.label ?? identity?.label ?? message.senderLabel ?? "Assistant"
        let glyph = identity?.glyph ?? resp?.icon ?? "✦"
        let tintColor = identity?.color ?? Color.ripul(.textSecondary)

        // At rest, the web chat's compact label: cut into the card's top edge in
        // the card's own fill, only its raised half outlined, in the card's border
        // colour. A patch of the page's colour cut a square hole into the card
        // instead (Peter, 27 Oct 2026). A tap on the card opens it into the pill.
        NativeEdgeCutIn(edge: .top, ground: Color.ripul(.canvas), tint: Self.cardGround, outline: cardStroke) {
            HStack(spacing: 4) {
                respondentGlyph(glyph, size: 10, tint: tintColor)
                Text(label)
                    .font(.ripul(size: 11, weight: .medium))
                    .tracking(0.11)
                    .foregroundStyle(tintColor)
                if let pct = resp?.contextPercent, pct >= 90 {
                    Text("\(pct)%")
                        .font(.ripul(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.ripul(.danger))
                }
            }
        }
        .accessibilityIdentifier("NativeChat.respondentNotch.\(message.id)")
    }

    /// The card's fill, over the chat's canvas.
    private static var cardGround: Color { Color.ripul(.text).opacity(0.055) }

    /// Sending replaces the glyph in the existing edge overlay. Neither the
    /// label nor the card changes size while the answer is being delivered.
    private func respondentGlyph(_ glyph: String, size: CGFloat, tint: Color) -> some View {
        ZStack {
            if let ask = message.askUser, ask.submitting && !ask.completed {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint)
                    .accessibilityLabel("Sending answer")
                    .accessibilityIdentifier("NativeChat.askUser.sending.\(message.id)")
            } else {
                Text(glyph)
                    .font(.ripul(size: size, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 14, height: 14)
    }

    /// The card's border: the cut-ins on its edges are outlined in it too.
    private var cardStroke: Color {
        isHighlighted ? Color.ripul(.info)
            : isHighContext ? Color.ripul(.danger).opacity(0.6)
            : Color.ripul(.separator)
    }

    @ViewBuilder
    private var respondentActionLozenge: some View {
        let resp = message.respondent
        let identity = ModelIdentity.resolve(modelId: resp?.modelId ?? resp?.label ?? message.senderLabel)
        let label = resp?.label ?? identity?.label ?? message.senderLabel ?? "Assistant"
        let glyph = identity?.glyph ?? resp?.icon ?? "✦"
        let tintColor = identity?.color ?? Color.ripul(.textSecondary)

        // Opened, the web chat's full pill: the family's height, outlined in the
        // model's colour, with a chevron when the turn's details can be shown.
        Button {
            if resp != nil {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showRespondentMeta.toggle()
                }
            }
        } label: {
            HStack(spacing: 4) {
                respondentGlyph(glyph, size: 12, tint: tintColor)
                Text(label)
                    .font(.ripul(size: 12, weight: .semibold))
                    .tracking(0.24)
                    .foregroundStyle(tintColor)
                // Only when it calls for attention, as the web's pill shows none:
                // with it, the actions no longer fit beside the pill on a phone.
                if let pct = resp?.contextPercent, pct >= 75 {
                    Text("\(pct)%")
                        .font(.ripul(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(pct >= 90 ? Color.ripul(.danger) : Color.ripul(.warning))
                }
                if resp != nil {
                    Image(systemName: showRespondentMeta ? "chevron.up" : "chevron.down")
                        .font(.ripulIcon(size: 8, weight: .bold))
                        .foregroundStyle(tintColor.opacity(0.7))
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .frame(height: NativeEdgeMetrics.pillHeight)
            .background(
                Capsule()
                    .fill(Color.ripul(.surface))
                    .overlay(
                        Capsule().strokeBorder(identity.map { $0.color.opacity(showRespondentMeta ? 0.6 : 0.4) } ?? Color.ripul(.separator), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityIdentifier("NativeChat.respondentLozenge.\(message.id)")
    }

    private func respondentMetadataPanel(_ resp: NativeRespondentInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let modelId = resp.modelId, !modelId.isEmpty {
                metaRow(label: "Model", value: modelId, monospaced: true)
            }
            if let provider = resp.provider, !provider.isEmpty {
                metaRow(label: "Provider", value: provider)
            }
            if let ctx = resp.contextTokens {
                let winText = resp.contextWindow.map { " / \($0.formatted())" } ?? ""
                let pctText = resp.contextPercent.map { " (\($0)%)" } ?? ""
                metaRow(label: "Context", value: "\(ctx.formatted())\(winText) tokens\(pctText)", monospaced: true)
            }
            if let inp = resp.inputTokens, let out = resp.outputTokens {
                metaRow(label: "Tokens", value: "\(inp.formatted()) in · \(out.formatted()) out", monospaced: true)
            }
            if let cacheR = resp.cacheReadTokens, cacheR > 0 {
                let cacheW = resp.cacheWriteTokens ?? 0
                metaRow(label: "Cache", value: "\(cacheR.formatted()) read · \(cacheW.formatted()) write", monospaced: true)
            }
            if let tools = resp.toolCallCount, tools > 0 {
                metaRow(label: "Tool calls", value: "\(tools)", monospaced: true)
            }
            if let ms = resp.durationMs, ms > 0 {
                let secs = String(format: "%.1fs", ms / 1000.0)
                metaRow(label: "Duration", value: secs, monospaced: true)
            }
            if let cost = resp.costUsd, cost > 0 {
                metaRow(label: "Cost", value: String(format: "$%.4f", cost), monospaced: true)
            }

            HStack(spacing: 8) {
                if let json = resp.metaJson, !json.isEmpty {
                    Button {
                        copyToClipboard(json)
                        metaCopiedFeedback = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            metaCopiedFeedback = false
                        }
                    } label: {
                        Label(metaCopiedFeedback ? "Copied JSON" : "Copy JSON", systemImage: metaCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.ripul(.caption2, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if resp.isRewindable {
                    Button {
                        bridge?.send([
                            "type": "agent-framework:nativeChat:action",
                            "op": "rewind",
                            "chatId": message.chatId ?? bridge?.currentSourceChatId ?? "",
                            "messageId": message.id,
                        ])
                    } label: {
                        Label("Rewind to here", systemImage: "arrow.uturn.backward")
                            .font(.ripul(.caption2, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("NativeChat.rewind.\(message.id)")
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ripul(.text).opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ripul(.separator), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChat.respondentMeta.\(message.id)")
    }

    private func metaRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.ripul(.caption2))
                .foregroundStyle(.ripul(.textTertiary))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(monospaced ? .ripul(.caption2, family: .code) : .ripul(.caption2))
                .foregroundStyle(.ripul(.textSecondary))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func interactiveQuestionSection(_ ask: NativeAskUser) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ask.question.isEmpty {
                NativeChatMarkdownBody(content: ask.question)
                    .equatable()
            }

            if !ask.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ask.options) { opt in
                        questionOptionRow(opt, ask: ask)
                    }
                }

                if ask.multiSelect && !ask.completed {
                    Button {
                        submitMultiChoiceAnswer(ask)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .font(.ripulIcon(size: 12))
                            Text(multiSelectedValues.isEmpty ? "Select options" : "Submit Selection (\(multiSelectedValues.count))")
                                .font(.ripul(.subheadline, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(multiSelectedValues.isEmpty || ask.submitting)
                    .accessibilityIdentifier("NativeChat.askUser.submitMulti.\(message.id)")
                }
            }

            if let dateInput = ask.dateInput {
                if ask.completed, let ans = ask.answer, !ans.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundStyle(.ripul(.success))
                        Text("Selected: \(ans)")
                            .font(.ripul(.subheadline, weight: .medium))
                    }
                    .padding(8)
                    .background(Color.ripul(.success).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker(
                            dateInput.includeTime ? "Date & Time" : "Date",
                            selection: $selectedDate,
                            displayedComponents: dateInput.includeTime ? [.date, .hourAndMinute] : [.date]
                        )
                        .font(.ripul(.subheadline))

                        Button {
                            let formatter = ISO8601DateFormatter()
                            let formatted = formatter.string(from: selectedDate)
                            submitSingleAnswer(value: formatted, label: formatted, ask: ask)
                        } label: {
                            Label(dateInput.includeTime ? "Submit Date & Time" : "Submit Date", systemImage: "checkmark.circle.fill")
                                .font(.ripul(.subheadline, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(ask.submitting)
                }
            }

            if ask.passwordInput && !ask.completed {
                HStack(spacing: 8) {
                    SecureField("Enter password or secret…", text: $passwordText)
                        .textFieldStyle(.roundedBorder)
                        .font(.ripul(.subheadline, family: .code))
                        .disabled(ask.submitting)
                        .onSubmit {
                            let trimmed = passwordText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, !ask.submitting else { return }
                            let secret = passwordText
                            passwordText = ""
                            submitSingleAnswer(value: secret, label: "••••••••", ask: ask)
                        }
                        .accessibilityIdentifier("NativeChat.askUser.passwordField.\(message.id)")

                    Button {
                        let secret = passwordText
                        passwordText = ""
                        submitSingleAnswer(value: secret, label: "••••••••", ask: ask)
                    } label: {
                        Label("Send", systemImage: "lock.fill")
                            .font(.ripul(.subheadline, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(passwordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ask.submitting)
                    .accessibilityIdentifier("NativeChat.askUser.submitPassword.\(message.id)")
                }
            }

            if !ask.completed, let error = ask.submissionError, !error.isEmpty {
                Text(error)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.danger))
                    .accessibilityIdentifier("NativeChat.askUser.error.\(message.id)")
            }

            // Typed reply summary when completed and not already represented by a selected option or date picker
            if let answer = ask.freeTextAnswer {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.ripulIcon(size: 13))
                        .foregroundStyle(.ripul(.success))
                    Text("Answered: \(answer)")
                        .font(.ripul(.caption, weight: .medium))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(2)
                }
                .padding(.top, 2)
                .accessibilityIdentifier("NativeChat.askUser.answered.\(message.id)")
            }
        }
    }

    private func questionOptionRow(_ opt: NativeAskUser.Option, ask: NativeAskUser) -> some View {
        let isSelected: Bool = {
            if ask.completed {
                if ask.selectedValues.contains(opt.value) || ask.selectedValues.contains(opt.label) {
                    return true
                }
                if let ans = ask.answer, (ans == opt.value || ans == opt.label) {
                    return true
                }
                return false
            }
            return multiSelectedValues.contains(opt.value)
        }()

        return Button {
            selectOption(opt, ask: ask)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ask.multiSelect
                      ? (isSelected ? "checkmark.square.fill" : "square")
                      : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .font(.ripulIcon(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.ripul(.textSecondary))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    if let image = opt.image, image.hasPrefix("https://") {
                        NativeChatChoiceImage(source: image)
                    }
                    Text(opt.label)
                        .ripulText()
                        .font(.ripul(.subheadline, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.ripul(.text))
                        .multilineTextAlignment(.leading)
                    if let desc = opt.description, !desc.isEmpty {
                        Text(desc)
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                if !opt.value.isEmpty && opt.value != opt.label {
                    Text(opt.value)
                        .font(.ripul(.caption2, family: .code))
                        .foregroundStyle(.ripul(.textSecondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule().stroke(Color.ripul(.textSecondary).opacity(0.35), lineWidth: 1)
                        )
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.ripul(.text).opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor : Color.ripul(.textSecondary).opacity(0.25),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            .opacity(ask.completed && !isSelected ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(ask.completed || ask.submitting)
        .accessibilityIdentifier("NativeChat.askUser.option.\(opt.id)")
    }

    private func selectOption(_ option: NativeAskUser.Option, ask: NativeAskUser) {
        guard !ask.completed && !ask.submitting else { return }
        if ask.multiSelect {
            if multiSelectedValues.contains(option.value) { multiSelectedValues.remove(option.value) }
            else { multiSelectedValues.insert(option.value) }
        } else {
            submitSingleAnswer(value: option.value, label: option.label, ask: ask)
        }
    }

    private func submitSingleAnswer(value: String, label: String, ask: NativeAskUser) {
        guard !ask.completed && !ask.submitting else { return }
        bridge?.send([
            "type": "agent-framework:nativeChat:action",
            "op": "answerQuestion",
            "chatId": message.chatId ?? bridge?.currentSourceChatId ?? "",
            "messageId": message.id,
            "responseKey": ask.responseKey ?? "",
            "threadId": ask.threadId ?? "",
            "actionId": ask.actionId ?? "",
            "value": value,
            "label": label,
        ])
    }

    private func submitMultiChoiceAnswer(_ ask: NativeAskUser) {
        let chosen = ask.options.filter { multiSelectedValues.contains($0.value) }
        let values = chosen.map(\.value)
        let labels = chosen.map(\.label).joined(separator: ", ")
        guard !ask.completed && !ask.submitting && !values.isEmpty else { return }
        bridge?.send([
            "type": "agent-framework:nativeChat:action",
            "op": "answerQuestion",
            "chatId": message.chatId ?? bridge?.currentSourceChatId ?? "",
            "messageId": message.id,
            "responseKey": ask.responseKey ?? "",
            "threadId": ask.threadId ?? "",
            "actionId": ask.actionId ?? "",
            "value": values,
            "label": labels,
        ])
    }

    /// What a tap on the card reveals on its top edge, beside the respondent pill.
    @ViewBuilder
    private var assistantActions: some View {
        NativeMessageActions(message: message, bridge: bridge, includesSpeech: true, onReply: onReply)
    }

    private func severityColor(_ severity: String?) -> Color {
        switch severity {
        case "error": return .ripul(.danger)
        case "warning": return .ripul(.warning)
        default: return .accentColor
        }
    }
}

// MARK: - 6. User Note & Artefact Reference Row

@available(iOS 16.0, macOS 14.0, *)
private struct NativeUserNoteRowView: View {
    let message: NativeChatMessage
    let bridge: AgentBridge?
    let isToolbarOpen: Bool
    let onToggleToolbar: () -> Void

    @NativeRowState("note.isExpanded") private var isExpanded = false
    @State private var copiedFeedback = false

    private let noteAccent = Color(red: 0.58, green: 0.39, blue: 0.85) // theme-exempt: distinct user note and artefact badge accent

    var body: some View {
        if let art = message.artefactRef {
            NativeArtefactCardView(
                artefact: art,
                senderLabel: message.senderLabel,
                chatId: message.chatId,
                bridge: bridge
            )
        } else {
            noteCard
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(noteAccent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.ripulIcon(size: 11))
                            .foregroundStyle(noteAccent)
                        Text(message.senderLabel ?? "Note")
                            .font(.ripul(.caption, weight: .semibold))
                            .foregroundStyle(noteAccent)
                        Spacer()
                        if message.content.count > 140 {
                            Button(isExpanded ? "Show less" : "Show more") {
                                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                            }
                            .font(.ripul(.caption2, weight: .medium))
                            .foregroundStyle(noteAccent)
                            .buttonStyle(.plain)
                        }
                    }

                    Text(message.content)
                        .font(.ripul(.callout))
                        .foregroundStyle(.ripul(.text))
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(noteAccent.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(noteAccent.opacity(0.25), lineWidth: 1)
            )
            // What a tap reveals, cut into the note's top edge at its right as the
            // web chat's note has it: over the note, so it never moves.
            .overlay(alignment: .topTrailing) {
                if isToolbarOpen {
                    HStack(spacing: 6) {
                        NativeBubbleActionLozenge(
                            title: isExpanded ? "Collapse" : "Expand",
                            systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                        }
                        NativeBubbleActionLozenge(
                            title: copiedFeedback ? "Copied" : "Copy",
                            systemImage: copiedFeedback ? "checkmark" : "doc.on.doc",
                            isActive: copiedFeedback
                        ) {
                            copyToClipboard(message.content)
                            copiedFeedback = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                copiedFeedback = false
                            }
                        }
                    }
                    .fixedSize()
                    .padding(.trailing, 10)
                    .offset(y: -NativeEdgeMetrics.pillHeight / 2)
                    .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { onToggleToolbar() }
        }
        .accessibilityIdentifier("NativeChat.userNote.\(message.id)")
    }
}

// MARK: - 6b. Native Web & Declarative Artefact Card

@available(iOS 16.0, macOS 14.0, *)
@MainActor
private final class NativeArtefactSessionCache {
    static let shared = NativeArtefactSessionCache()
    private var models: [String: NativeArtefactCardModel] = [:]

    func model(for artefact: NativeArtefactReference, chatId: String?) -> NativeArtefactCardModel {
        let key = "\(artefact.artefactId):\(artefact.revision):\(artefact.presentationId)"
        if let existing = models[key] {
            if let accepted = artefact.acceptedSelection, existing.acceptedSelection != accepted {
                existing.acceptedSelection = accepted
            }
            return existing
        }
        let created = NativeArtefactCardModel(artefact: artefact, chatId: chatId)
        models[key] = created
        return created
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeDeclarativeInputSpec: Equatable, Identifiable {
    let key: String
    let label: String
    let type: String
    var id: String { key }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeArtefactOutputRow: Equatable, Identifiable {
    let id: Int
    let label: String
    let value: String
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
private final class NativeArtefactCardModel: ObservableObject {
    let artefactId: String
    let revision: Int
    let presentationId: String
    let surface: String
    let initialRunId: String?
    var chatId: String?

    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var errorMessage: String? = nil
    @Published var runtimeError: String? = nil
    @Published var noticeMessage: String? = nil

    @Published var runtime: String = ""
    @Published var title: String = ""
    @Published var canRun: Bool = false

    // Web/v1 fields
    @Published var widgetHeight: CGFloat = 520
    @Published var measuredWidgetHeight: CGFloat = 0
    @Published var submitLabel: String? = nil
    var widgetChannel: String = ""
    var widgetDocument: String? = nil
    var pageChannel: String = ""
    var pageDocument: String? = nil
    var currentState: [String: Any] = [:]
    @Published var latestRunId: String? = nil
    @Published var pendingSelection: (runId: String, label: String, summary: String)? = nil

    // Declarative/v1 fields
    @Published var runLabel: String = "Calculate"
    @Published var inputSpecs: [NativeDeclarativeInputSpec] = []
    @Published var inputValues: [String: String] = [:]
    @Published var outputRows: [NativeArtefactOutputRow] = []

    @Published var acceptedSelection: NativeArtefactAcceptedSelection? = nil
    @Published var isBusy = false
    @Published var isSubmitting = false

    fileprivate var inlineWebView: WKWebView?
    fileprivate var inlineCoordinator: NativeWebArtefactCoordinator?

    init(artefact: NativeArtefactReference, chatId: String?) {
        self.artefactId = artefact.artefactId
        self.revision = artefact.revision
        self.presentationId = artefact.presentationId
        self.surface = artefact.surface
        self.initialRunId = artefact.runId
        self.chatId = chatId
        self.acceptedSelection = artefact.acceptedSelection
    }

    func loadIfNeeded(bridge: AgentBridge?) async {
        guard !hasLoaded, !isLoading, let bridge else { return }
        await reload(bridge: bridge)
    }

    func reload(bridge: AgentBridge?) async {
        guard let bridge else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var input: [String: Any] = [
                "artefactId": artefactId,
                "revision": revision,
                "surface": surface,
            ]
            if let initialRunId, !initialRunId.isEmpty {
                input["runId"] = initialRunId
            }
            let raw = try await Self.callArtefactBridge(bridge: bridge, chatId: chatId ?? bridge.currentSourceChatId ?? "", operation: "readCard", input: input)
            guard let dict = raw as? [String: Any] else {
                throw NSError(domain: "NativeArtefact", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid artefact payload."])
            }
            title = dict["title"] as? String ?? artefactId
            runtime = dict["runtime"] as? String ?? "web/v1"
            canRun = dict["canRun"] as? Bool ?? false
            latestRunId = dict["latestRunId"] as? String

            if runtime == "web/v1" {
                currentState = dict["initialState"] as? [String: Any] ?? [:]
                if let w = dict["widget"] as? [String: Any] {
                    if let h = (w["height"] as? NSNumber)?.doubleValue, h > 0 {
                        widgetHeight = CGFloat(h)
                    }
                    submitLabel = w["submitLabel"] as? String
                    widgetChannel = w["channel"] as? String ?? UUID().uuidString
                    widgetDocument = w["document"] as? String
                }
                if let p = dict["page"] as? [String: Any] {
                    pageChannel = p["channel"] as? String ?? UUID().uuidString
                    pageDocument = p["document"] as? String
                }
            } else if runtime == "declarative/v1" {
                runLabel = dict["runLabel"] as? String ?? "Calculate"
                if let rawSchema = dict["inputSchema"] as? [[String: Any]] {
                    inputSpecs = rawSchema.compactMap { item in
                        guard let key = item["key"] as? String,
                              let label = item["label"] as? String else { return nil }
                        let type = item["type"] as? String ?? "string"
                        return NativeDeclarativeInputSpec(key: key, label: label, type: type)
                    }
                }
                if let initVals = dict["initialValues"] as? [String: Any] {
                    var mapped: [String: String] = [:]
                    for (k, v) in initVals {
                        mapped[k] = String(describing: v)
                    }
                    inputValues = mapped
                }
                if let rawRows = dict["outputRows"] as? [[String: Any]] {
                    outputRows = rawRows.enumerated().compactMap { idx, r in
                        guard let l = r["label"] as? String, let v = r["value"] as? String else { return nil }
                        return NativeArtefactOutputRow(id: idx, label: l, value: v)
                    }
                }
            }
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func executeDeclarative(bridge: AgentBridge?) async {
        guard let bridge, !isBusy, canRun else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            var parsedInputs: [String: Any] = [:]
            for spec in inputSpecs {
                let rawVal = inputValues[spec.key] ?? ""
                if spec.type == "boolean" {
                    parsedInputs[spec.key] = (rawVal == "true")
                } else if spec.type == "number" || spec.type == "integer" {
                    let normalized = rawVal.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let num = Double(normalized) else {
                        throw NSError(domain: "NativeArtefact", code: 2, userInfo: [NSLocalizedDescriptionKey: "Enter a valid \(spec.label.lowercased())."])
                    }
                    parsedInputs[spec.key] = spec.type == "integer" ? Int(num) : num
                } else {
                    parsedInputs[spec.key] = rawVal
                }
            }
            let raw = try await Self.callArtefactBridge(
                bridge: bridge,
                chatId: chatId ?? bridge.currentSourceChatId ?? "",
                operation: "runCard",
                input: [
                    "artefactId": artefactId,
                    "revision": revision,
                    "inputs": parsedInputs,
                ]
            )
            if let dict = raw as? [String: Any] {
                latestRunId = dict["runId"] as? String
                if let rawRows = dict["outputRows"] as? [[String: Any]] {
                    outputRows = rawRows.enumerated().compactMap { idx, r in
                        guard let l = r["label"] as? String, let v = r["value"] as? String else { return nil }
                        return NativeArtefactOutputRow(id: idx, label: l, value: v)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitSelection(bridge: AgentBridge?) async {
        guard let bridge, !isSubmitting, acceptedSelection == nil else { return }
        let targetRunId: String?
        let label: String?
        let summary: String?
        if runtime == "declarative/v1" {
            targetRunId = latestRunId
            label = nil
            summary = nil
        } else {
            targetRunId = pendingSelection?.runId
            label = pendingSelection?.label
            summary = pendingSelection?.summary
        }
        guard let runId = targetRunId, !runId.isEmpty else { return }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            var payload: [String: Any] = [
                "presentationId": presentationId,
                "artefactId": artefactId,
                "revision": revision,
                "runId": runId,
            ]
            if let label { payload["label"] = label }
            if let summary { payload["summary"] = summary }

            let raw = try await Self.callArtefactBridge(
                bridge: bridge,
                chatId: chatId ?? bridge.currentSourceChatId ?? "",
                operation: "prepareSelection",
                input: payload
            )
            guard let dict = raw as? [String: Any],
                  let message = dict["message"] as? String else {
                throw NSError(domain: "NativeArtefact", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not prepare selection."])
            }
            let ok = await bridge.submitMessage(message)
            guard ok else {
                throw NSError(domain: "NativeArtefact", code: 4, userInfo: [NSLocalizedDescriptionKey: bridge.messageSubmissionError ?? "Wait until this conversation is ready for a new message."])
            }
            if let acc = dict["accepted"] as? [String: Any],
               let accLabel = acc["label"] as? String,
               let accRunId = acc["runId"] as? String {
                acceptedSelection = NativeArtefactAcceptedSelection(
                    label: accLabel,
                    summary: acc["summary"] as? String ?? "",
                    runId: accRunId
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleFrameRequest(
        id reqId: Int,
        method: String,
        args: [String: Any],
        frameSurface: String,
        channel: String,
        webView: WKWebView?,
        bridge: AgentBridge?
    ) async {
        func reply(_ body: [String: Any]) {
            guard let webView else { return }
            var msg: [String: Any] = [
                "channel": channel,
                "type": "response",
                "id": reqId,
            ]
            for (k, v) in body { msg[k] = v }
            Self.postMessageToFrame(webView: webView, payload: msg)
        }

        guard canRun else {
            reply(["error": "Run access is required."])
            return
        }
        guard !isBusy else {
            reply(["error": "Wait for the previous artefact request to finish."])
            return
        }
        guard let bridge else {
            reply(["error": "Chat bridge is not connected."])
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let activeChatId = chatId ?? bridge.currentSourceChatId ?? ""
            switch method {
            case "run":
                latestRunId = nil
                pendingSelection = nil
                var input: [String: Any] = [
                    "artefactId": artefactId,
                    "revision": revision,
                    "inputs": args["inputs"] as? [String: Any] ?? [:],
                ]
                if let action = args["action"] as? String { input["action"] = action }
                if let state = args["state"] as? [String: Any] { input["state"] = state }
                let raw = try await Self.callArtefactBridge(bridge: bridge, chatId: activeChatId, operation: "runCard", input: input)
                guard let dict = raw as? [String: Any],
                      let runId = dict["runId"] as? String else {
                    throw NSError(domain: "NativeArtefact", code: 5, userInfo: [NSLocalizedDescriptionKey: "Run returned an invalid response."])
                }
                let nextState = dict["state"] as? [String: Any] ?? [:]
                let output = dict["output"] as? [String: Any] ?? [:]
                let rev = (dict["revision"] as? NSNumber)?.intValue ?? revision
                latestRunId = runId
                currentState = nextState
                reply([
                    "result": [
                        "output": output,
                        "state": nextState,
                        "runId": runId,
                        "revision": rev,
                    ]
                ])

            case "select":
                guard frameSurface == "widget" else {
                    throw NSError(domain: "NativeArtefact", code: 6, userInfo: [NSLocalizedDescriptionKey: "Selection is available in a chat widget."])
                }
                guard let submitLabel, !submitLabel.isEmpty else {
                    throw NSError(domain: "NativeArtefact", code: 7, userInfo: [NSLocalizedDescriptionKey: "This widget is display-only."])
                }
                guard let latestRunId, (args["runId"] as? String) == latestRunId else {
                    throw NSError(domain: "NativeArtefact", code: 8, userInfo: [NSLocalizedDescriptionKey: "Calculate the current inputs before selecting this result."])
                }
                guard let p = args["presentation"] as? [String: Any],
                      let rawLabel = p["label"] as? String else {
                    throw NSError(domain: "NativeArtefact", code: 9, userInfo: [NSLocalizedDescriptionKey: "Selection requires a short label and optional summary."])
                }
                let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLabel.isEmpty, trimmedLabel.count <= 120 else {
                    throw NSError(domain: "NativeArtefact", code: 10, userInfo: [NSLocalizedDescriptionKey: "Selection requires a short label and optional summary."])
                }
                let summary = (p["summary"] as? String) ?? ""
                pendingSelection = (runId: latestRunId, label: trimmedLabel, summary: summary)
                reply(["result": ["ready": true]])

            case "save":
                let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else {
                    throw NSError(domain: "NativeArtefact", code: 11, userInfo: [NSLocalizedDescriptionKey: "Give this scenario a name"])
                }
                let raw = try await Self.callArtefactBridge(
                    bridge: bridge,
                    chatId: activeChatId,
                    operation: "saveScenario",
                    input: [
                        "artefactId": artefactId,
                        "revision": revision,
                        "name": name,
                        "state": args["state"] as? [String: Any] ?? currentState,
                    ]
                )
                let dict = raw as? [String: Any]
                noticeMessage = "Saved “\(name)” privately."
                reply(["result": dict?["scenario"] as Any])

            case "scenarios":
                let raw = try await Self.callArtefactBridge(
                    bridge: bridge,
                    chatId: activeChatId,
                    operation: "scenarios",
                    input: ["artefactId": artefactId, "revision": revision]
                )
                let dict = raw as? [String: Any]
                reply(["result": dict?["scenarios"] as Any])

            case "load":
                latestRunId = nil
                pendingSelection = nil
                guard let scenarioId = args["id"] as? String, !scenarioId.isEmpty else {
                    throw NSError(domain: "NativeArtefact", code: 12, userInfo: [NSLocalizedDescriptionKey: "Choose a saved scenario"])
                }
                let raw = try await Self.callArtefactBridge(
                    bridge: bridge,
                    chatId: activeChatId,
                    operation: "loadScenario",
                    input: ["artefactId": artefactId, "revision": revision, "scenarioId": scenarioId]
                )
                let dict = raw as? [String: Any]
                if let sc = dict?["scenario"] as? [String: Any],
                   let inputs = sc["inputs"] as? [String: Any] {
                    currentState = inputs
                }
                reply(["result": dict?["scenario"] as Any])

            default:
                throw NSError(domain: "NativeArtefact", code: 13, userInfo: [NSLocalizedDescriptionKey: "Unknown artefact capability"])
            }
        } catch {
            reply(["error": error.localizedDescription])
        }
    }

    static func postMessageToFrame(webView: WKWebView, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.postMessage(\(json), '*');", completionHandler: nil)
    }

    private static func callArtefactBridge(
        bridge: AgentBridge,
        chatId: String,
        operation: String,
        input: [String: Any]
    ) async throws -> Any {
        let reqData = try JSONSerialization.data(
            withJSONObject: [
                "chatId": chatId,
                "operation": operation,
                "input": input,
            ],
            options: [.sortedKeys]
        )
        let json = String(decoding: reqData, as: UTF8.self)
        let result = try await bridge.callAsyncJavaScript("""
            const request = \(json);
            if (typeof window.__ripulArtefactChat !== 'function') throw new Error('Chat is still loading. Try again.');
            return await window.__ripulArtefactChat(request.chatId, request.operation, request.input);
            """)
        guard let result else {
            throw NSError(domain: "NativeArtefact", code: 14, userInfo: [NSLocalizedDescriptionKey: "No reply from artefact service."])
        }
        return result
    }
}

@available(iOS 16.0, macOS 14.0, *)
private final class WeakArtefactScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
private final class NativeWebArtefactCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: NativeArtefactCardModel?
    weak var bridge: AgentBridge?
    let surface: String
    var loadedChannel: String = ""
    weak var webView: WKWebView?

    init(model: NativeArtefactCardModel, bridge: AgentBridge?, surface: String) {
        self.model = model
        self.bridge = bridge
        self.surface = surface
    }

    var activeChannel: String {
        guard let model else { return "" }
        return surface == "widget" && !model.widgetChannel.isEmpty ? model.widgetChannel : model.pageChannel
    }

    var activeDocument: String? {
        guard let model else { return nil }
        if surface == "widget", let doc = model.widgetDocument {
            return doc
        }
        return model.pageDocument
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let model else { return }
        let channel = activeChannel
        guard !channel.isEmpty else { return }
        NativeArtefactCardModel.postMessageToFrame(
            webView: webView,
            payload: [
                "channel": channel,
                "type": "init",
                "state": model.currentState,
                "context": [
                    "artefactId": model.artefactId,
                    "revision": model.revision,
                    "surface": surface,
                    "nativePresentation": NSNull(),
                    "runId": model.latestRunId as Any,
                ],
            ]
        )
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String,
                  let model = self.model else { return }

            if type == "__height" {
                if self.surface == "widget",
                   let h = (dict["height"] as? NSNumber)?.doubleValue,
                   h > 80 {
                    let clamped = min(max(CGFloat(h), model.widgetHeight), 1200)
                    if abs(model.measuredWidgetHeight - clamped) > 2 {
                        model.measuredWidgetHeight = clamped
                    }
                }
                return
            }

            let channel = self.activeChannel
            guard (dict["channel"] as? String) == channel else { return }

            switch type {
            case "draft":
                model.pendingSelection = nil
                if let nextState = dict["state"] as? [String: Any] {
                    model.currentState = nextState
                }
            case "error":
                let msg = dict["message"] as? String ?? "Artefact error"
                model.runtimeError = String(msg.prefix(1500))
            case "request":
                guard let reqId = (dict["id"] as? NSNumber)?.intValue,
                      let method = dict["method"] as? String else { return }
                let args = dict["args"] as? [String: Any] ?? [:]
                let wv = self.webView
                let br = self.bridge
                let surf = self.surface
                Task { @MainActor in
                    await model.handleFrameRequest(
                        id: reqId,
                        method: method,
                        args: args,
                        frameSurface: surf,
                        channel: channel,
                        webView: wv,
                        bridge: br
                    )
                }
            default:
                break
            }
        }
    }

    static let bridgeScriptSource = """
    (function() {
      var FROM_HOST = { 'init': true, 'response': true, 'native-event': true, 'snapshot-request': true };
      window.addEventListener('message', function(event) {
        var d = event.data;
        if (!d || typeof d !== 'object' || typeof d.channel !== 'string' || typeof d.type !== 'string') return;
        if (FROM_HOST[d.type]) return;
        try {
          window.webkit.messageHandlers.ripulArtefactHost.postMessage(d);
        } catch (e) {}
      });
      function reportHeight() {
        try {
          if (!document.body) return;
          var bodyTop = document.body.getBoundingClientRect().top;
          var maxBottom = 0;
          var children = document.body.children;
          for (var i = 0; i < children.length; i++) {
            var ch = children[i];
            var tag = ch.tagName;
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEMPLATE') continue;
            var r = ch.getBoundingClientRect();
            if (r.height > 0) maxBottom = Math.max(maxBottom, r.bottom - bodyTop);
          }
          if (maxBottom > 0) {
            window.webkit.messageHandlers.ripulArtefactHost.postMessage({
              type: '__height',
              height: Math.ceil(maxBottom + 18)
            });
          }
        } catch (e) {}
      }
      window.addEventListener('load', function() {
        reportHeight();
        setTimeout(reportHeight, 120);
        setTimeout(reportHeight, 400);
        if (typeof ResizeObserver !== 'undefined' && document.body) {
          new ResizeObserver(reportHeight).observe(document.body);
        }
        if (typeof MutationObserver !== 'undefined' && document.body) {
          new MutationObserver(reportHeight).observe(document.body, { childList: true, subtree: true, attributes: true });
        }
      });
    })();
    """
}

#if os(iOS)
@available(iOS 16.0, *)
private struct NativeWebArtefactFrameView: UIViewRepresentable {
    @ObservedObject var model: NativeArtefactCardModel
    let bridge: AgentBridge?
    let surface: String
    let isScrollable: Bool

    func makeCoordinator() -> NativeWebArtefactCoordinator {
        if surface == "widget", let existing = model.inlineCoordinator {
            existing.bridge = bridge
            return existing
        }
        let coord = NativeWebArtefactCoordinator(model: model, bridge: bridge, surface: surface)
        if surface == "widget" {
            model.inlineCoordinator = coord
        }
        return coord
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .clear
        container.clipsToBounds = true
        attachWebView(to: container, coordinator: context.coordinator)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.model = model
        context.coordinator.bridge = bridge
        attachWebView(to: container, coordinator: context.coordinator)
    }

    private func attachWebView(to container: UIView, coordinator: NativeWebArtefactCoordinator) {
        let wv: WKWebView
        if surface == "widget", let cached = model.inlineWebView {
            wv = cached
        } else if let existing = coordinator.webView {
            wv = existing
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let ucc = WKUserContentController()
            ucc.addUserScript(WKUserScript(
                source: NativeWebArtefactCoordinator.bridgeScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            ucc.add(WeakArtefactScriptMessageHandler(coordinator), name: "ripulArtefactHost")
            config.userContentController = ucc
            let created = WKWebView(frame: container.bounds, configuration: config)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.scrollView.backgroundColor = .clear
            created.scrollView.bounces = isScrollable
            created.scrollView.isScrollEnabled = isScrollable
            created.navigationDelegate = coordinator
            coordinator.webView = created
            if surface == "widget" {
                model.inlineWebView = created
            }
            wv = created
        }

        wv.scrollView.isScrollEnabled = isScrollable
        if wv.superview !== container {
            wv.removeFromSuperview()
            wv.frame = container.bounds
            wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(wv)
        }

        let channel = coordinator.activeChannel
        if let doc = coordinator.activeDocument, !channel.isEmpty, coordinator.loadedChannel != channel {
            coordinator.loadedChannel = channel
            wv.loadHTMLString(doc, baseURL: nil)
        }
    }
}
#elseif os(macOS)
@available(macOS 14.0, *)
private struct NativeWebArtefactFrameView: NSViewRepresentable {
    @ObservedObject var model: NativeArtefactCardModel
    let bridge: AgentBridge?
    let surface: String
    let isScrollable: Bool

    func makeCoordinator() -> NativeWebArtefactCoordinator {
        NativeWebArtefactCoordinator(model: model, bridge: bridge, surface: surface)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(
            source: NativeWebArtefactCoordinator.bridgeScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        ucc.add(WeakArtefactScriptMessageHandler(context.coordinator), name: "ripulArtefactHost")
        config.userContentController = ucc
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.model = model
        context.coordinator.bridge = bridge
        let channel = context.coordinator.activeChannel
        if let doc = context.coordinator.activeDocument, !channel.isEmpty, context.coordinator.loadedChannel != channel {
            context.coordinator.loadedChannel = channel
            wv.loadHTMLString(doc, baseURL: nil)
        }
    }
}
#endif

@available(iOS 16.0, macOS 14.0, *)
private struct NativeArtefactCardView: View {
    let artefact: NativeArtefactReference
    let senderLabel: String?
    let chatId: String?
    let bridge: AgentBridge?

    @StateObject private var fallbackModel: NativeArtefactCardModel
    @NativeRowState("artefact.isFullPagePresented", affectsHeight: false) private var isFullPagePresented = false

    init(artefact: NativeArtefactReference, senderLabel: String?, chatId: String?, bridge: AgentBridge?) {
        self.artefact = artefact
        self.senderLabel = senderLabel
        self.chatId = chatId
        self.bridge = bridge
        _fallbackModel = StateObject(wrappedValue: NativeArtefactSessionCache.shared.model(for: artefact, chatId: chatId))
    }

    var body: some View {
        NativeArtefactCardContentView(
            artefact: artefact,
            senderLabel: senderLabel,
            bridge: bridge,
            model: NativeArtefactSessionCache.shared.model(for: artefact, chatId: chatId),
            isFullPagePresented: $isFullPagePresented
        )
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeArtefactCardContentView: View {
    let artefact: NativeArtefactReference
    let senderLabel: String?
    let bridge: AgentBridge?
    @ObservedObject var model: NativeArtefactCardModel
    @Binding var isFullPagePresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if artefact.kind == "artefact_reference/v1" {
                Text("\(senderLabel ?? "A participant") added an artefact")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }

            if artefact.status == "error" {
                statusBanner(
                    text: artefact.errorMessage ?? "Could not present this artefact.",
                    isError: true
                )
            } else if artefact.status == "loading" || artefact.status == "unavailable" {
                statusBanner(
                    text: artefact.errorMessage ?? (artefact.status == "loading" ? "Loading artefact presentation…" : "This artefact’s saved presentation is unavailable. Reopen the chat to reload it."),
                    isError: false
                )
            } else {
                cardBody
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
        .accessibilityIdentifier("NativeChat.artefact.\(artefact.artefactId)")
        .task(id: "\(artefact.artefactId):\(artefact.revision):\(artefact.runId ?? "")") {
            await model.loadIfNeeded(bridge: bridge)
        }
        .ripulSheet(isPresented: $isFullPagePresented, size: .page) {
            fullPageSheet
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Text(model.title.isEmpty ? (model.isLoading ? "Opening artefact…" : artefact.artefactId) : model.title)
                    .font(.ripul(.subheadline, weight: .semibold))
                    .foregroundStyle(.ripul(.text))
                    .lineLimit(2)

                Spacer(minLength: 6)

                Text("Revision \(artefact.revision)")
                    .font(.ripul(.caption2, weight: .medium))
                    .foregroundStyle(.ripul(.textSecondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.ripul(.text).opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if let err = model.errorMessage ?? model.runtimeError {
                statusBanner(text: err, isError: true)
                    .padding(.horizontal, 12)
            }

            if let notice = model.noticeMessage {
                Text(notice)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.success))
                    .padding(.horizontal, 12)
            }

            if model.isLoading && !model.hasLoaded {
                HStack(spacing: 8) {
                    RenderServerSpinner(size: 16)
                    Text("Opening widget…")
                        .font(.ripul(.footnote))
                        .foregroundStyle(.ripul(.textSecondary))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            } else if let accepted = model.acceptedSelection ?? artefact.acceptedSelection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(accepted.label)
                        .font(.ripul(.subheadline, weight: .semibold))
                        .foregroundStyle(.ripul(.text))
                    if !accepted.summary.isEmpty {
                        Text(accepted.summary)
                            .font(.ripul(.footnote))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    Text("Added to this chat · recorded result")
                        .font(.ripul(.caption2))
                        .foregroundStyle(.ripul(.textTertiary))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if artefact.kind == "artefact_reference/v1" && artefact.surface == "page" {
                // Page card added via + -> Artefact
                EmptyView()
            } else if model.runtime == "declarative/v1" {
                declarativeControls
                    .padding(.horizontal, 12)
            } else if model.runtime == "web/v1" {
                if !model.canRun {
                    statusBanner(text: "Ask the owner for run access to use this widget.", isError: false)
                        .padding(.horizontal, 12)
                } else {
                    let displayHeight = max(model.widgetHeight, model.measuredWidgetHeight)
                    NativeWebArtefactFrameView(
                        model: model,
                        bridge: bridge,
                        surface: artefact.surface == "page" ? "page" : "widget",
                        isScrollable: false
                    )
                    .frame(height: displayHeight)
                    .frame(maxWidth: .infinity)
                }
            }

            // Footer
            if model.hasLoaded {
                VStack(alignment: .leading, spacing: 8) {
                    let currentAccepted = model.acceptedSelection ?? artefact.acceptedSelection
                    if currentAccepted == nil {
                        if model.runtime == "declarative/v1" {
                            Button {
                                Task { await model.submitSelection(bridge: bridge) }
                            } label: {
                                Text(model.isSubmitting ? "Adding to chat…" : "Use this result")
                                    .font(.ripul(.subheadline, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.latestRunId == nil || model.isBusy || model.isSubmitting)

                            Text("Sends the selected inputs and result to this chat.")
                                .font(.ripul(.caption2))
                                .foregroundStyle(.ripul(.textSecondary))
                        } else if let submitLabel = model.submitLabel, !submitLabel.isEmpty, artefact.surface == "widget" {
                            Button {
                                Task { await model.submitSelection(bridge: bridge) }
                            } label: {
                                Text(model.isSubmitting ? "Adding to chat…" : submitLabel)
                                    .font(.ripul(.subheadline, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.pendingSelection == nil || model.isBusy || model.isSubmitting)
                            .accessibilityIdentifier("ArtefactWidget.submit")

                            Text("Sends the selected inputs and result to this chat.")
                                .font(.ripul(.caption2))
                                .foregroundStyle(.ripul(.textSecondary))
                        }
                    }

                    Button {
                        isFullPagePresented = true
                    } label: {
                        Text(artefact.kind == "artefact_reference/v1" && artefact.surface == "page" ? "Open artefact" : "Open full page")
                            .font(.ripul(.footnote, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ArtefactWidget.openPage")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ripul(.surface))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.ripul(.separator), lineWidth: 1)
        )
    }

    private var declarativeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.inputSpecs) { spec in
                if spec.type == "boolean" {
                    Toggle(
                        spec.label,
                        isOn: Binding(
                            get: { model.inputValues[spec.key] == "true" },
                            set: { model.inputValues[spec.key] = $0 ? "true" : "false" }
                        )
                    )
                    .font(.ripul(.subheadline))
                    .disabled(model.isBusy || !model.canRun)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spec.label)
                            .font(.ripul(.caption, weight: .medium))
                            .foregroundStyle(.ripul(.textSecondary))
                        TextField(
                            spec.label,
                            text: Binding(
                                get: { model.inputValues[spec.key] ?? "" },
                                set: { model.inputValues[spec.key] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.ripul(.subheadline))
                        .disabled(model.isBusy || !model.canRun)
                    }
                }
            }

            Button {
                Task { await model.executeDeclarative(bridge: bridge) }
            } label: {
                HStack(spacing: 6) {
                    if model.isBusy {
                        RenderServerSpinner(size: 16)
                    }
                    Text(model.runLabel)
                        .font(.ripul(.subheadline, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || !model.canRun)

            ForEach(model.outputRows) { row in
                HStack {
                    Text(row.label)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                    Spacer()
                    Text(row.value)
                        .font(.ripul(.subheadline, weight: .semibold))
                        .foregroundStyle(.ripul(.text))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var fullPageSheet: some View {
        NavigationStack {
            Group {
                if model.runtime == "declarative/v1" {
                    ScrollView {
                        declarativeControls
                            .padding(16)
                    }
                } else if model.pageDocument != nil {
                    NativeWebArtefactFrameView(
                        model: model,
                        bridge: bridge,
                        surface: "page",
                        isScrollable: true
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading artefact page…")
                            .font(.ripul(.subheadline))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(model.title.isEmpty ? "Artefact" : model.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back to chat") {
                        isFullPagePresented = false
                    }
                }
            }
        }
    }

    private func statusBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.ripulIcon(size: 14))
                .foregroundStyle(isError ? Color.ripul(.danger) : Color.ripul(.info))
            Text(text)
                .font(.ripul(.footnote))
                .foregroundStyle(.ripul(.text))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((isError ? Color.ripul(.danger) : Color.ripul(.info)).opacity(0.1))
        )
    }
}

// MARK: - 7. Task Notification, System Status, Error, and CLI Seam Rows

@available(iOS 16.0, macOS 14.0, *)
private struct NativeTaskNotificationRowView: View {
    let notification: NativeTaskNotification

    var body: some View {
        let isOk = notification.status == "completed"
        let isFailed = notification.status == "failed" || notification.status == "error"
        let iconName = isOk ? "checkmark.circle.fill" : isFailed ? "xmark.circle.fill" : "clock.fill"
        let iconColor: Color = isOk ? .ripul(.success) : isFailed ? .ripul(.danger) : .ripul(.textSecondary)
        let displayText = notification.summary ?? notification.taskId ?? "Task completed"

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.ripulIcon(size: 12))
                .foregroundStyle(iconColor)
                .padding(.top, 1)
            Text(displayText)
                .font(.ripul(.footnote))
                .foregroundStyle(.ripul(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ripul(.textSecondary).opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.ripul(.textSecondary).opacity(0.18), lineWidth: 0.5))
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeSystemStatusRowView: View {
    let message: NativeChatMessage

    var body: some View {
        let info = message.systemStatus
        let text = info?.message.isEmpty == false ? info!.message : message.content
        let isShared = info?.isSharedEvent ?? true
        let severity = info?.severity ?? "info"

        if isShared {
            HStack {
                Spacer(minLength: 20)
                Text(text)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.ripul(.text).opacity(0.05), in: Capsule())
                Spacer(minLength: 20)
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("NativeChat.systemStatus.\(message.id)")
        } else {
            let color: Color = severity == "error" ? .ripul(.danger) : severity == "warning" ? .ripul(.warning) : .ripul(.info)
            let symbol = severity == "error" ? "exclamationmark.triangle.fill" : severity == "warning" ? "exclamationmark.circle.fill" : "info.circle.fill"
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.ripulIcon(size: 13))
                    .foregroundStyle(color)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    if let title = info?.title, !title.isEmpty {
                        Text(title)
                            .font(.ripul(.caption, weight: .semibold))
                            .foregroundStyle(.ripul(.text))
                    }
                    Text(text)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.25), lineWidth: 1))
            .accessibilityIdentifier("NativeChat.systemStatus.\(message.id)")
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeErrorRowView: View {
    let message: NativeChatMessage
    @NativeRowState("error.showDetails") private var showDetails = false
    @State private var copied = false

    var body: some View {
        let title = message.errorInfo?.title ?? "Error"
        let bodyText = message.errorInfo?.message ?? (message.content.isEmpty ? (message.summary ?? "An error occurred") : message.content)
        let details = message.errorInfo?.details

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.ripulIcon(size: 15))
                    .foregroundStyle(.ripul(.danger))
                Text(title)
                    .font(.ripul(.subheadline, weight: .semibold))
                    .foregroundStyle(.ripul(.danger))
                Spacer()
                Button {
                    copyToClipboard([title, bodyText, details].compactMap { $0 }.joined(separator: "\n\n"))
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.ripulIcon(size: 12))
                        .foregroundStyle(.ripul(.textSecondary))
                }
                .buttonStyle(.plain)
            }

            Text(bodyText)
                .font(.ripul(.callout))
                .foregroundStyle(.ripul(.text))
                .textSelection(.enabled)

            if let details, !details.isEmpty {
                DisclosureGroup("Technical Details", isExpanded: $showDetails) {
                    NativeToolCodeBlock(text: details, syntax: .automatic)
                        .padding(.top, 6)
                }
                .font(.ripul(.caption, weight: .medium))
                .foregroundStyle(.ripul(.textSecondary))
            }
        }
        .padding(12)
        .background(Color.ripul(.danger).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.ripul(.danger).opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("NativeChat.error.\(message.id)")
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeCliEventSeamRowView: View {
    let messageId: String
    let event: NativeCliEventInfo
    @NativeRowState("cliEvent.expanded") private var expanded = false

    private var accentColor: Color {
        switch event.accent {
        case "success": return .ripul(.success)
        case "warning": return .ripul(.warning)
        case "error": return .ripul(.danger)
        case "info": return .ripul(.info)
        default: return .ripul(.textTertiary)
        }
    }

    private var iconName: String {
        switch event.kind {
        case "compact_boundary", "compaction": return "arrow.down.right.and.arrow.up.left"
        case "vcs": return event.label.lowercased().contains("push") ? "arrow.up.circle" : "point.topleft.down.curvedto.point.bottomright.up"
        case "hook": return "link"
        case "model_refusal": return "exclamationmark.shield"
        case "permission_denied": return "hand.raised.slash"
        case "rate_limit": return "speedometer"
        case "signin": return "person.crop.circle.badge.exclamationmark"
        case "claude_limit": return "hourglass"
        case "api_retry": return "arrow.clockwise"
        case "session_title": return "pencil"
        case "tool_inventory": return "wrench.and.screwdriver"
        case "shell_output": return "terminal"
        default: return "curlybraces"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if event.rawJson != nil || event.content != nil {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.ripul(.separator))
                        .frame(minWidth: 12, maxWidth: .infinity, maxHeight: 1)

                    Image(systemName: iconName)
                        .font(.ripulIcon(size: 11))
                        .foregroundStyle(accentColor)

                    Text(event.codeLabel ? event.label : event.label.uppercased())
                        .font(event.codeLabel ? .ripul(size: 10, family: .code) : .ripul(size: 10, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.ripul(size: 10))
                            .foregroundStyle(.ripul(.textTertiary))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    ForEach(Array(event.chips.enumerated()), id: \.offset) { _, chip in
                        Text(chip)
                            .font(.ripul(size: 10, family: .code))
                            .foregroundStyle(.ripul(.textSecondary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.ripul(.separator), lineWidth: 1)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Rectangle()
                        .fill(Color.ripul(.separator))
                        .frame(minWidth: 12, maxWidth: .infinity, maxHeight: 1)
                }
            }
            .buttonStyle(.plain)

            if let content = event.content, !content.isEmpty {
                Text(content)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .padding(.horizontal, 10)
            }

            if expanded, let rawJson = event.rawJson, !rawJson.isEmpty {
                NativeToolCodeBlock(text: rawJson, title: event.label, titleFont: .ripul(.caption), syntax: .json)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("NativeChat.cliEvent.\(messageId)")
    }
}

// MARK: - 8. Shared Rich Markdown + Code Block Renderer, Table View, Avatars, and Swipe-to-Reply

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatStructuredTableView: View {
    let table: NativeMessageTable
    let options: [NativeAskUser.Option]
    let disabled: Bool
    let onSelect: (NativeAskUser.Option) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.columns) { col in
                        Text(col.label)
                            .font(.ripul(.caption, weight: .semibold))
                            .foregroundStyle(.ripul(.text))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.ripul(.text).opacity(0.08))
                    }
                }

                Divider()
                    .gridCellUnsizedAxes(.horizontal)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { idx, row in
                    let option = table.matchingOption(for: row, options: options)
                    let link = row["_link"].flatMap(URL.init(string:))
                    let interactive = !disabled && (option != nil || link != nil)
                    GridRow {
                        ForEach(table.columns) { col in
                            Button {
                                if let option { onSelect(option) }
                                if let link { openURL(link) }
                            } label: {
                                Text(row[col.key] ?? "")
                                    .font(.ripul(.caption))
                                    .foregroundStyle(.ripul(interactive ? .info : .textSecondary))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(idx.isMultiple(of: 2) ? Color.clear : Color.ripul(.text).opacity(0.03))
                            }
                            .buttonStyle(.plain)
                            .disabled(!interactive)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.ripul(.separator), lineWidth: 1)
            )
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeParticipantAvatarView: View {
    let name: String
    let avatarUrl: String?
    let identity: String
    var size: CGFloat = 32

    private static let palette: [Color] = [
        Color(red: 0.286, green: 0.416, blue: 0.624), // theme-exempt: deterministic participant avatar palette
        Color(red: 0.604, green: 0.298, blue: 0.439), // theme-exempt: deterministic participant avatar palette
        Color(red: 0.224, green: 0.490, blue: 0.451), // theme-exempt: deterministic participant avatar palette
        Color(red: 0.518, green: 0.376, blue: 0.631), // theme-exempt: deterministic participant avatar palette
        Color(red: 0.573, green: 0.396, blue: 0.157), // theme-exempt: deterministic participant avatar palette
        Color(red: 0.298, green: 0.447, blue: 0.510), // theme-exempt: deterministic participant avatar palette
    ]

    private var fill: Color {
        var hash: Int32 = 0
        for scalar in identity.unicodeScalars {
            hash = (hash &* 31) &+ Int32(bitPattern: scalar.value)
        }
        let idx = Int(abs(Int64(hash)) % Int64(Self.palette.count))
        return Self.palette[idx]
    }

    private var initials: String {
        let words = name.split { $0.isWhitespace }.map(String.init)
        if words.count > 1, let first = words.first?.first, let last = words.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String((words.first ?? "?").prefix(2)).uppercased()
    }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height) > 0 ? min(geo.size.width, geo.size.height) : size
            ZStack {
                Circle().fill(fill)
                if let avatarUrl, let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Text(initials)
                            .font(.ripul(size: d * 0.36, weight: .semibold))
                            .foregroundStyle(.ripul(system: .white))
                    }
                } else {
                    Text(initials)
                        .font(.ripul(size: d * 0.36, weight: .semibold))
                        .foregroundStyle(.ripul(system: .white))
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
        }
        .frame(idealWidth: size, idealHeight: size)
        .accessibilityLabel(name)
    }
}

/// Adaptive layout for incoming group messages: measures the bubble at both the
/// side-by-side width (next to the avatar) and the full underneath width, and
/// converts to placing the bubble underneath the `[Avatar + Sender]` header row
/// when and only when doing so results in net-net less vertical height.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeAdaptiveGroupBubbleLayout: Layout {
    var hasSender: Bool

    private let sideAvatarSize: CGFloat = 30
    private let headerAvatarSize: CGFloat = 24
    private let avatarGap: CGFloat = 8
    private let headerAvatarGap: CGFloat = 6
    private let headerBottomGap: CGFloat = 4
    private let trailingSpacer: CGFloat = 44
    private let stripeWidth: CGFloat = 3
    private let padX: CGFloat = 12
    private let padY: CGFloat = 10
    private let senderSpacing: CGFloat = 6

    private struct Metrics {
        var useUnderneath: Bool
        var totalWidth: CGFloat
        var totalHeight: CGFloat
        var sideBubbleSize: CGSize
        var sideContentSize: CGSize
        var underBubbleSize: CGSize
        var underContentSize: CGSize
        var senderSize: CGSize
        var headerHeight: CGFloat
    }

    private func computeMetrics(proposal: ProposedViewSize, subviews: Subviews) -> Metrics {
        let totalWidth = max(200, proposal.width ?? 340)
        guard subviews.count == 4 else {
            return Metrics(
                useUnderneath: false,
                totalWidth: totalWidth,
                totalHeight: 44,
                sideBubbleSize: .zero,
                sideContentSize: .zero,
                underBubbleSize: .zero,
                underContentSize: .zero,
                senderSize: .zero,
                headerHeight: headerAvatarSize
            )
        }
        let senderView = subviews[2]
        let contentView = subviews[3]

        let maxSideBubbleWidth = max(140, totalWidth - sideAvatarSize - avatarGap - trailingSpacer)
        let maxSideContentWidth = max(80, maxSideBubbleWidth - stripeWidth - padX * 2)
        let senderSize = hasSender
            ? senderView.sizeThatFits(ProposedViewSize(width: maxSideContentWidth, height: nil))
            : .zero
        let sideContentSize = contentView.sizeThatFits(ProposedViewSize(width: maxSideContentWidth, height: nil))
        let sideInnerWidth = max(senderSize.width, sideContentSize.width)
        let sideBubbleWidth = min(maxSideBubbleWidth, sideInnerWidth + stripeWidth + padX * 2)
        let sideSenderBlock = hasSender ? (senderSize.height + senderSpacing) : 0
        let sideBubbleHeight = padY * 2 + sideSenderBlock + sideContentSize.height
        let sideTotalHeight = max(sideAvatarSize, sideBubbleHeight)

        let maxUnderBubbleWidth = totalWidth
        let maxUnderContentWidth = max(120, maxUnderBubbleWidth - stripeWidth - padX * 2)
        let underContentSize = contentView.sizeThatFits(ProposedViewSize(width: maxUnderContentWidth, height: nil))
        let underBubbleWidth = min(maxUnderBubbleWidth, underContentSize.width + stripeWidth + padX * 2)
        let underBubbleHeight = padY * 2 + underContentSize.height
        let headerHeight = max(headerAvatarSize, senderSize.height)
        let underTotalHeight = headerHeight + headerBottomGap + underBubbleHeight

        let useUnderneath = underTotalHeight < sideTotalHeight - 0.5

        return Metrics(
            useUnderneath: useUnderneath,
            totalWidth: totalWidth,
            totalHeight: useUnderneath ? underTotalHeight : sideTotalHeight,
            sideBubbleSize: CGSize(width: sideBubbleWidth, height: sideBubbleHeight),
            sideContentSize: sideContentSize,
            underBubbleSize: CGSize(width: underBubbleWidth, height: underBubbleHeight),
            underContentSize: underContentSize,
            senderSize: senderSize,
            headerHeight: headerHeight
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = computeMetrics(proposal: proposal, subviews: subviews)
        return CGSize(width: m.totalWidth, height: m.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let m = computeMetrics(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        let chromeView = subviews[0]
        let avatarView = subviews[1]
        let senderView = subviews[2]
        let contentView = subviews[3]

        if m.useUnderneath {
            let avatarY = bounds.minY + (m.headerHeight - headerAvatarSize) * 0.5
            avatarView.place(
                at: CGPoint(x: bounds.minX, y: avatarY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: headerAvatarSize, height: headerAvatarSize)
            )
            if hasSender {
                let senderY = bounds.minY + (m.headerHeight - m.senderSize.height) * 0.5
                senderView.place(
                    at: CGPoint(x: bounds.minX + headerAvatarSize + headerAvatarGap, y: senderY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: max(60, bounds.width - headerAvatarSize - headerAvatarGap), height: m.senderSize.height)
                )
            } else {
                senderView.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: 0, height: 0))
            }
            let bubbleY = bounds.minY + m.headerHeight + headerBottomGap
            chromeView.place(
                at: CGPoint(x: bounds.minX, y: bubbleY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: m.underBubbleSize.width, height: m.underBubbleSize.height)
            )
            contentView.place(
                at: CGPoint(x: bounds.minX + stripeWidth + padX, y: bubbleY + padY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: m.underBubbleSize.width - stripeWidth - padX * 2, height: m.underContentSize.height)
            )
        } else {
            let avatarY = bounds.minY + m.totalHeight - sideAvatarSize
            avatarView.place(
                at: CGPoint(x: bounds.minX, y: avatarY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: sideAvatarSize, height: sideAvatarSize)
            )
            let bubbleX = bounds.minX + sideAvatarSize + avatarGap
            let bubbleY = bounds.minY + m.totalHeight - m.sideBubbleSize.height
            chromeView.place(
                at: CGPoint(x: bubbleX, y: bubbleY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: m.sideBubbleSize.width, height: m.sideBubbleSize.height)
            )
            let innerX = bubbleX + stripeWidth + padX
            let innerW = m.sideBubbleSize.width - stripeWidth - padX * 2
            var contentY = bubbleY + padY
            if hasSender {
                senderView.place(
                    at: CGPoint(x: innerX, y: contentY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: innerW, height: m.senderSize.height)
                )
                contentY += m.senderSize.height + senderSpacing
            } else {
                senderView.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: 0, height: 0))
            }
            contentView.place(
                at: CGPoint(x: innerX, y: contentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: innerW, height: m.sideContentSize.height)
            )
        }
    }
}

/// The pills on a bubble's edges, as the web chat sizes them (`bubbleActionToolbar.ts`).
private enum NativeEdgeMetrics {
    /// Every pill a tap reveals (the open respondent label and the actions): one
    /// height, so the row reads as one family (the web's LOZENGE_HEIGHT).
    static let pillHeight: CGFloat = 22
    /// A compact label cut into an edge at rest: the respondent label, the time.
    static let cutInHeight: CGFloat = 16
}

/// What a tap on a bubble reveals, cut into its top edge as the web chat's
/// bubbleActions are: centred on the edge, after `leading` at the left,
/// right-aligned, scrolling on their own when they do not fit. Drawn over the
/// bubble, so opening them moves nothing: a row above it pushed the bubble down
/// (Peter, 27 Oct 2026).
@available(iOS 16.0, macOS 14.0, *)
private struct NativeEdgeActions<Leading: View, Actions: View>: View {
    let showsActions: Bool
    let leading: Leading
    let actions: Actions

    init(showsActions: Bool, @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.showsActions = showsActions
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            if showsActions {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { actions }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { actions }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
    }
}

/// A compact label cut into a bubble's edge, as the web chat's resting respondent
/// label and its time are: in the bubble's own fill, so its inner half is the
/// bubble, with only the half outside it outlined, in the bubble's border colour.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeEdgeCutIn<Content: View>: View {
    let edge: VerticalEdge
    /// The bubble's fill, opaque: its ground, then what is laid over it.
    let ground: Color
    let tint: Color
    let outline: Color
    let content: Content

    init(edge: VerticalEdge, ground: Color, tint: Color, outline: Color, @ViewBuilder content: () -> Content) {
        self.edge = edge
        self.ground = ground
        self.tint = tint
        self.outline = outline
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .frame(height: NativeEdgeMetrics.cutInHeight)
            .background {
                Capsule().fill(ground)
                Capsule().fill(tint)
                Capsule()
                    .strokeBorder(outline, lineWidth: 1)
                    .mask(alignment: edge == .top ? .top : .bottom) {
                        Rectangle().frame(height: NativeEdgeMetrics.cutInHeight / 2)
                    }
            }
    }
}

/// A bubble's time, cut into its bottom edge at the right while its actions show.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeEdgeTime: View {
    let timestamp: Double
    let ground: Color
    let tint: Color
    let outline: Color

    var body: some View {
        NativeEdgeCutIn(edge: .bottom, ground: ground, tint: tint, outline: outline) {
            Text(formatTimestamp(timestamp))
                .font(.ripul(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.ripul(.textTertiary))
        }
        .padding(.trailing, 10)
        // Centred on the bottom edge. Shown behind an `if`, an overlay drops
        // its alignment guides, so it is moved by half its height instead.
        .offset(y: NativeEdgeMetrics.cutInHeight / 2)
        .transition(.opacity)
        .accessibilityIdentifier("NativeChat.time")
    }
}

/// One toolbar for assistant panels and incoming cross-chat messages.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeMessageActions: View {
    let message: NativeChatMessage
    let bridge: AgentBridge?
    let includesSpeech: Bool
    let onReply: () -> Void
    @State private var copiedFeedback = false

    var body: some View {
        let copyText = message.askUser?.question.isEmpty == false ? (message.askUser?.question ?? "") : message.content
        NativeBubbleActionLozenge(
            title: "Reply",
            systemImage: "arrowshape.turn.up.left",
            action: onReply
        )

        NativeBubbleActionLozenge(
            title: copiedFeedback ? "Copied" : "Copy",
            systemImage: copiedFeedback ? "checkmark" : "doc.on.doc",
            isActive: copiedFeedback
        ) {
            copyToClipboard(copyText)
            copiedFeedback = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copiedFeedback = false
            }
        }

        if includesSpeech, SpeechPreferences.readAloudEnabled,
           !NativeChatReadAloudController.panelText(for: message).isEmpty {
            NativeMessageSpeakLozenge(message: message, bridge: bridge)
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeMessageSpeakLozenge: View {
    let message: NativeChatMessage
    let bridge: AgentBridge?
    @ObservedObject private var readAloud = NativeChatReadAloudController.shared

    var body: some View {
        let phase = readAloud.state(for: message.id)
        if phase == .idle {
            Menu {
                Button {
                    readAloud.play(message: message, mode: .quick, bridge: bridge)
                } label: {
                    Label("Quick overview", systemImage: "text.quote")
                }
                Button {
                    readAloud.play(message: message, mode: .detailed, bridge: bridge)
                } label: {
                    Label("Detailed summary", systemImage: "text.alignleft")
                }
            } label: {
                NativeBubbleActionLozengeLabel(
                    title: "Speak",
                    systemImage: "speaker.wave.2",
                    isActive: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speak")
        } else {
            NativeBubbleActionLozenge(
                title: phase == .loading ? "…" : "Stop",
                systemImage: phase == .loading ? "waveform" : "stop.fill",
                isActive: true,
                accessibilityLabel: "Stop speaking"
            ) {
                readAloud.stop()
            }
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeBubbleActionLozenge: View {
    let title: String?
    let systemImage: String
    var isActive: Bool = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NativeBubbleActionLozengeLabel(
                title: title,
                systemImage: systemImage,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title ?? "Action")
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeBubbleActionLozengeLabel: View {
    let title: String?
    let systemImage: String
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.ripulIcon(size: 11, weight: .semibold))
            if let title {
                Text(title)
                    .font(.ripul(size: 11, weight: .semibold))
                    .tracking(0.22)
            }
        }
        .foregroundStyle(isActive ? Color.ripul(.success) : Color.ripul(.textSecondary))
        .padding(.horizontal, title != nil ? 8 : 7)
        .frame(height: NativeEdgeMetrics.pillHeight)
        .background(
            Capsule()
                .fill(Color.ripul(.surface))
                .overlay(
                    Capsule()
                        .strokeBorder(isActive ? Color.ripul(.success).opacity(0.5) : Color.ripul(.separator), lineWidth: 1)
                )
        )
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeSwipeToReplyModifier: ViewModifier {
    let onTrigger: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var armed: Bool = false
    private let threshold: CGFloat = 56

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            if dragOffset > 6 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.ripulIcon(size: 14, weight: .semibold))
                    .foregroundStyle(armed ? Color.accentColor : Color.ripul(.textTertiary))
                    .scaleEffect(min(1.15, max(0.6, dragOffset / threshold)))
                    .opacity(min(1.0, Double(dragOffset / (threshold * 0.8))))
                    .padding(.leading, 8)
            }

            swipeable(content.offset(x: dragOffset))
        }
    }

    @ViewBuilder
    private func swipeable(_ view: some View) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            // A SwiftUI DragGesture recognises any 24 pt move, vertical too, and a
            // gesture on a row takes priority over its scroll view. A quick flick
            // whose first touch sample is already past 24 pt (about 40 pt on a
            // phone) started the drag before the scroll, and the chat ignored the
            // flick (a swipe log showed the scroll's pan never began on bubbles,
            // 26 Oct 2026). This pan fails at
            // once unless the drag is rightward and mostly sideways.
            view.gesture(NativeReplySwipeGesture(onChanged: dragChanged, onEnded: dragEnded))
        } else {
            view.simultaneousGesture(dragGesture)
        }
        #else
        view.simultaneousGesture(dragGesture)
        #endif
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) * 1.6 else { return }
                dragChanged(dx)
            }
            .onEnded { _ in dragEnded() }
    }

    private func dragChanged(_ dx: CGFloat) {
        let pulled = max(0, dx)
        let damped = pulled <= threshold ? pulled : threshold + (pulled - threshold) * 0.25
        dragOffset = min(90, damped)
        let nowArmed = dragOffset >= threshold
        if nowArmed && !armed {
            armed = true
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } else if !nowArmed && armed {
            armed = false
        }
    }

    private func dragEnded(shouldTrigger: Bool = true) {
        let shouldFire = shouldTrigger && armed
        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
            dragOffset = 0
            armed = false
        }
        if shouldFire {
            onTrigger()
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatAttachmentThumbnail: View {
    let attachment: NativeChatImageAttachment
    var maxSide: CGFloat = 110
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            NativeChatAttachmentImage(attachment: attachment)
                .frame(width: maxSide, height: maxSide * 0.75)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ripul(.separator), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.name ?? "Attached image")
    }
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
final class NativeChatImagePreloader {
    static let shared = NativeChatImagePreloader()

    #if os(iOS)
    typealias PlatformImage = UIImage
    #elseif os(macOS)
    typealias PlatformImage = NSImage
    #endif

    private static let dimensionsDefaultsKey = "ripul.nativeChat.imageDimensions.v1"
    private static let maxPersistedDimensions = 500
    private let cache = NSCache<NSString, PlatformImage>()
    private var knownSizes: [String: CGSize] = [:]
    private var knownSizeOrder: [String] = []
    private var persistWorkItem: DispatchWorkItem?
    private var inFlightKeys = Set<String>()
    let keyLoaded = PassthroughSubject<String, Never>()

    private init() {
        cache.countLimit = 256
        if let saved = UserDefaults.standard.dictionary(forKey: Self.dimensionsDefaultsKey) {
            for (k, v) in saved {
                if let arr = v as? [Double], arr.count == 2, arr[0] > 0, arr[1] > 0 {
                    knownSizes[k] = CGSize(width: arr[0], height: arr[1])
                    knownSizeOrder.append(k)
                }
            }
        }
    }

    func cacheKey(for attachment: NativeChatImageAttachment) -> String {
        if let url = attachment.url, !url.isEmpty {
            return "url:\(url)"
        }
        return "id:\(attachment.id)"
    }

    func knownSize(for attachment: NativeChatImageAttachment) -> CGSize? {
        knownSizes[cacheKey(for: attachment)]
    }

    private func recordKnownSize(_ size: CGSize, forKey key: String) {
        guard size.width > 0, size.height > 0 else { return }
        if knownSizes[key] == size { return }
        if knownSizes[key] == nil {
            knownSizeOrder.append(key)
        }
        knownSizes[key] = size
        while knownSizeOrder.count > Self.maxPersistedDimensions {
            let oldest = knownSizeOrder.removeFirst()
            knownSizes.removeValue(forKey: oldest)
        }
        schedulePersistKnownSizes()
    }

    private func schedulePersistKnownSizes() {
        persistWorkItem?.cancel()
        let snapshot = knownSizes
        let item = DispatchWorkItem {
            var serialized: [String: [Double]] = [:]
            serialized.reserveCapacity(snapshot.count)
            for (k, s) in snapshot {
                serialized[k] = [Double(s.width), Double(s.height)]
            }
            UserDefaults.standard.set(serialized, forKey: Self.dimensionsDefaultsKey)
        }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func cachedImage(for attachment: NativeChatImageAttachment) -> PlatformImage? {
        let key = cacheKey(for: attachment)
        if let hit = cache.object(forKey: key as NSString) {
            recordKnownSize(hit.size, forKey: key)
            return hit
        }
        if let raw = attachment.data, !raw.isEmpty {
            let base64 = raw.hasPrefix("data:") ? (raw.components(separatedBy: ",").last ?? raw) : raw
            if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
               let img = PlatformImage(data: data) {
                cache.setObject(img, forKey: key as NSString)
                recordKnownSize(img.size, forKey: key)
                return img
            }
        }
        if let urlStr = attachment.url, let url = URL(string: urlStr) {
            startFetchIfNeeded(url: url, key: key)
        }
        return nil
    }

    func preload(messages: [NativeChatMessage]) {
        for msg in messages {
            for att in msg.imageAttachments {
                if let w = att.width, let h = att.height, w > 0, h > 0 {
                    recordKnownSize(CGSize(width: w, height: h), forKey: cacheKey(for: att))
                }
                _ = cachedImage(for: att)
            }
        }
    }

    private func startFetchIfNeeded(url: URL, key: String) {
        guard !inFlightKeys.contains(key) else { return }
        inFlightKeys.insert(key)
        Task.detached(priority: .userInitiated) {
            let decoded: PlatformImage? = await {
                let request = URLRequest(url: url)
                if let cachedResp = URLCache.shared.cachedResponse(for: request),
                   let img = PlatformImage(data: cachedResp.data) {
                    return img
                }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    return PlatformImage(data: data)
                } catch {
                    return nil
                }
            }()
            await MainActor.run {
                let loader = NativeChatImagePreloader.shared
                loader.inFlightKeys.remove(key)
                if let decoded {
                    loader.cache.setObject(decoded, forKey: key as NSString)
                    loader.recordKnownSize(decoded.size, forKey: key)
                    loader.keyLoaded.send(key)
                }
            }
        }
    }

    func notifyLoadedForTesting(image: PlatformImage, for attachment: NativeChatImageAttachment) {
        let key = cacheKey(for: attachment)
        cache.setObject(image, forKey: key as NSString)
        recordKnownSize(image.size, forKey: key)
        keyLoaded.send(key)
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatAttachmentImage: View {
    let attachment: NativeChatImageAttachment
    private let preloader = NativeChatImagePreloader.shared
    @State private var loadedRevision: Int = 0

    var body: some View {
        let _ = loadedRevision
        let key = preloader.cacheKey(for: attachment)
        Group {
            if let img = preloader.cachedImage(for: attachment) {
                #if os(iOS)
                Image(uiImage: img).resizable().scaledToFill()
                #elseif os(macOS)
                Image(nsImage: img).resizable().scaledToFill()
                #endif
            } else {
                placeholder
            }
        }
        .onAppear {
            if preloader.cachedImage(for: attachment) != nil {
                loadedRevision &+= 1
            }
        }
        .onReceive(preloader.keyLoaded) { loadedKey in
            if loadedKey == key {
                loadedRevision &+= 1
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.ripul(.text).opacity(0.06)
            Image(systemName: "photo")
                .foregroundStyle(.ripul(.textTertiary))
        }
    }
}

// MARK: - Helpers

private struct NativeChatFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Only the button observes this state: starting a flick must not redraw the
/// chat. Tracking, dragging, deceleration and animated jumps all hide it until
/// SwiftUI reports idle, including the coast after the finger has lifted.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatScrollActivity: ViewModifier {
    let model: ScrollButtonModel?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    let moving = phase != .idle
                    if model?.isScrolling != moving { model?.isScrolling = moving }
                }
                .onDisappear {
                    if model?.isScrolling == true { model?.isScrolling = false }
                }
        } else {
            content
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeDefaultBottomScrollAnchor: ViewModifier {
    var shouldAnchorBottom: Bool = true

    func body(content: Content) -> some View {
        #if os(iOS)
        // On iOS, NativeChatScrollCoordinator owns bottom-following and smooth
        // glide via CADisplayLink (mirroring V2ChatScroller's `overflowAnchor: 'none'`
        // + useAutoFollow.ts). Using `.defaultScrollAnchor(.bottom)` causes SwiftUI
        // to teleport contentOffset.y in a single layout pass when contentSize grows,
        // bypassing the smooth follow glide.
        if #available(iOS 17.0, *) {
            content.defaultScrollAnchor(.top)
        } else {
            content
        }
        #else
        content.defaultScrollAnchor(shouldAnchorBottom ? .bottom : .top)
        #endif
    }
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
final class NativeChatScrollCoordinator: NSObject {
    #if os(iOS)
    private struct WeakMarker {
        weak var value: UIView?
    }
    weak var scrollView: UIScrollView?
    weak var vstackAnchorView: UIView?
    private var offsetObservation: NSKeyValueObservation?
    private var contentSizeObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var followDisplayLink: CADisplayLink?
    private var decelerationWaitDisplayLink: CADisplayLink?
    private var lastFollowFrameTimestamp: CFTimeInterval = 0
    /// The follow glide's speed, in points a second toward the end.
    private var followVelocity: CGFloat = 0
    private var isWritingOffset: Bool = false
    private var lastObservedOffsetY: CGFloat = 0
    private var pendingFollowAfterDeceleration: Bool = false
    private var pendingForceInstantFollow: Bool = false
    private var hasHeldRowPublication: Bool = false
    private var awaitingGeometry: Bool = false
    private var pendingGeometry: [String: CGRect]? = nil
    private var pendingFilteredFrames: [String: CGRect]? = nil
    private var pendingCandidates: [(key: String, value: CGRect)] = []
    private var geometryBaseOffset: CGFloat? = nil
    private var geometryOrigin: CGFloat? = nil
    private var rowMarkers: [String: WeakMarker] = [:]
    #if DEBUG
    private var scrollPerfDisplayLink: CADisplayLink?
    private var perfLastFrameTimestamp: CFTimeInterval = 0
    private var perfFrames: Int = 0
    private var perfHitches: Int = 0
    // What the hitches cost: time past each late frame's deadline, and the longest gap.
    private var perfLostMs: Double = 0
    private var perfWorstGapMs: Double = 0
    private var perfIdleFrames: Int = 0
    // Frames counted while settling with no finger or fling. Phone and Catalyst
    // builds are Debug, so this link runs on the devices people use: geometry that
    // cannot settle (a chat hidden behind another screen) kept it waking the main
    // thread at 120 Hz with nothing scrolling.
    private var perfSettlingFrames: Int = 0
    private var perfOffsetHandlerCalls: Int = 0
    private var perfOffsetHandlerMs: Double = 0
    private var perfGeometryCalls: Int = 0
    private var perfGeometryMs: Double = 0
    private var perfPrepGens: Int = 0
    private var perfPrepMs: Double = 0
    // The nod, measured: the reading row's on-screen move each frame, less what the
    // user's scrolling explains (the offset change without our own corrections).
    private var perfDriftRowId: String?
    private var perfDriftLastScreenY: CGFloat = 0
    private var perfDriftLastOffsetY: CGFloat = 0
    private var perfCorrectionSinceFrame: CGFloat = 0
    private var perfDriftMax: CGFloat = 0
    private var perfDriftFrames: Int = 0
    private var perfDriftSamples: Int = 0
    // Row publications (updateWindowRows) and their main-thread time, and
    // store changes held below the screen, while tracking.
    private var perfRowPublications: Int = 0
    private var perfRowPublicationMs: Double = 0
    private var perfTailHolds: Int = 0
    // A page landing at rest, which the scroll line never sees (it counts only
    // while scrolling): the wait for the next frame, then the worst frame after.
    private var landingProbeLink: CADisplayLink?
    private var landingProbeStart: CFTimeInterval = 0
    private var landingProbeLast: CFTimeInterval = 0
    private var landingProbeFirstMs: Double = -1
    private var landingProbeWorstMs: Double = 0
    private var landingProbeLostMs: Double = 0
    private var landingProbeFrames = 0
    private var landingProbeRows = (from: 0, to: 0)
    /// Offset writes that moved a following chat at once rather than gliding, as
    /// "reason:points", for the follow harness (`NativeChatFollowUITests`). Kept
    /// to the last 200.
    static var debugInstantFollows: [String] = []
    static func noteInstantFollow(_ reason: String, points: CGFloat) {
        guard abs(points) >= 1 else { return }
        if debugInstantFollows.count >= 200 { debugInstantFollows.removeFirst() }
        debugInstantFollows.append("\(reason):\(Int(points.rounded()))")
    }
    #endif
    private lazy var tapAwayRecognizer: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleScrollViewTapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()
    #endif
    private weak var windowPublication: NativeChatWindowBand?
    #if os(iOS) && DEBUG
    /// This scroller's `[LISTPERF]` lines, to set beside the owned list's.
    private lazy var listFrames: NativeChatScrollFrames = {
        let frames = NativeChatScrollFrames(path: "old")
        frames.log = { [weak self] line in self?.bridge?.handleConsoleLog(line) }
        frames.extra = { [weak self] in
            "mounted=\(self?.windowPublication?.snapshot.rows.count ?? -1) rows=\(self?.store?.rows.count ?? 0)"
        }
        return frames
    }()
    #endif
    var windowEnabled = false
    var useMarkerFrames: Bool = PerfSwitch.isOn("markerFrames")
    private var lastContainerFrames: [String: CGRect] = [:]
    private var markerDeltaCheckScheduled: Bool = false
    private var windowRows: [NativeChatRow] = []
    private(set) var windowModel = NativeChatWindowModel(layout: .init(width: 320))
    private var windowRevisions = NativeChatRowRevisionTracker<NativeChatRow>()
    private struct WindowRowRevision: Equatable {
        let content: UInt64
        let state: UInt64
        let token: UInt64
    }
    private weak var windowRowStateRegistry: NativeChatRowStateRegistry?
    private var windowRowRevisionByID: [String: WindowRowRevision] = [:]
    private var windowRowRevisionSerial: UInt64 = 0
    private var windowDirtyStateRows = Set<String>()
    private var windowStateUpdateScheduled = false
    private var windowPlan: NativeChatWindowModel.Plan?
    private var windowRowsOrigin: CGFloat = 0
    private var windowOffsetPlanScheduled = false
    private var windowOffsetPlanPending = false
    private var windowMeasurementScheduled = false
    private var windowMeasurementJob: (() -> Void)?
    private var windowPlanningTopOverride: CGFloat?
    private var windowDescriptorByID: [String: NativeChatWindowModel.Descriptor] = [:]
    private var windowPublishedDescriptors: [String: NativeChatWindowModel.Descriptor] = [:]
    private var windowIndexByID: [String: Int] = [:]
    #if os(iOS)
    private struct WindowAnchorBaseline {
        let id: String
        let contentY: CGFloat
    }
    private var windowAnchorBaseline: WindowAnchorBaseline?
    private var windowWaitStarted: CFTimeInterval?
    private var windowWaitTicks = 0
    private var windowWaitReason = "layout"
    private var windowRecovery = false
    private var windowLastExpectedHeight: CGFloat = 0
    private var windowLastActualHeight: CGFloat = 0
    private struct WindowLayoutAnchor {
        let id: String
        var screenOffset: CGFloat
        var offsetAtCapture: CGFloat
    }
    private var windowLayoutAnchor: WindowLayoutAnchor?
    private var windowLayoutTarget: NativeChatWindowModel.LayoutKey?
    private var windowPublishedLayout: NativeChatWindowModel.LayoutKey?
    #endif
    private var windowNeedsDataPublication = false
    private var windowWaitSize = 0
    private var windowWaitMarker = 0
    private var windowWaitSerial = 0
    private var windowMissingAnchor = 0
    private var windowNavigationCount = 0
    private var windowStuckCount = 0
    private var windowCommittedSerial: UInt64 = 0
    private var windowLayoutChanges = 0
    private var windowTargetID: String?
    private var windowTargetIsRestoration = false
    private var windowNavigationCompletion: (() -> Void)?
    private var windowMissingSerial: UInt64 = 0
    private var windowMissingPasses: [String: Int] = [:]
    private var windowConfirmedMissing: [NativeChatWindowModel.HeightKey] = []
    private var windowMoves = 0
    private var windowCorrections = 0
    private var windowCorrectionPoints: CGFloat = 0
    /// The way the view last travelled: toward older rows (`.up`) or newer, read from
    /// the offset's own motion, which a coast keeps (the pan recognizer reads zero
    /// once the finger lifts).
    private var windowTravel: NativeChatWindowModel.Direction = .stationary
    /// When the offset last moved other than by our own writes: an animated scroll
    /// (a status-bar tap) moves it with no tracking or deceleration flag set.
    private var windowLastOffsetMotion: CFTimeInterval = 0
    /// When rows were last published: growth waits for streaming or a landing to settle.
    private var windowLastRowsPublication: CFTimeInterval = 0
    private var windowLastGrowthPublication: CFTimeInterval = 0
    private var windowQuietWorkItem: DispatchWorkItem?
    private var windowGrowthScheduled = false
    private var windowGrowthWaits = 0
    private var windowGrowthStepsThisRest = 0
    private var windowGrowthSteps = 0
    /// A turn of the phone cut the band to the rows near the screen
    /// (`beginSizeTransition`). Until it has grown back to every row, a chat of 80
    /// rows or fewer keeps a band and grows it at rest, as a long chat does, rather
    /// than mounting every row again in one pass.
    private var windowTurnBand = false
    /// Growth waits until the turn has been laid out and animated.
    private var windowTurnUntil: CFTimeInterval = 0
    var windowTextMetrics = "default" {
        didSet {
            #if os(iOS)
            if oldValue != windowTextMetrics { captureWindowLayoutAnchor() }
            #endif
        }
    }

    /// Returns true when navigation is staged; mounted targets retain proxy animation.
    func stageWindowNavigation(id: String, completion: @escaping () -> Void) -> Bool {
        #if os(iOS)
        guard windowEnabled else { return false }
        let nativeID = windowIndexByID[id] != nil ? id : store?.resolveNativeRowId(forWebRowId: id)
        guard let nativeID, windowIndexByID[nativeID] != nil else { return false }
        if isWindowTargetMounted(nativeID) { return false }
        stageWindowTarget(id: nativeID, restoration: false, completion: completion)
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func beginWindowWait(_ reason: String) {
        if windowWaitStarted == nil {
            windowWaitStarted = CACurrentMediaTime()
            windowWaitTicks = 0
        }
        windowWaitReason = reason
        scheduleWaitForDecelerationEnd()
    }

    private func recoverStuckWindowIfNeeded() -> Bool {
        guard windowEnabled, let started = windowWaitStarted else { return false }
        windowWaitTicks += 1
        guard windowWaitTicks >= 30 || CACurrentMediaTime() - started >= 0.5 else { return false }
        windowStuckCount += 1
        #if DEBUG
        bridge?.handleConsoleLog("LOG: [SCROLLPERF] stuck=\(windowWaitReason) ticks=\(windowWaitTicks) sizeGap=\(windowLastActualHeight)/\(windowLastExpectedHeight)")
        #endif
        windowWaitStarted = nil
        windowWaitTicks = 0
        windowAnchorBaseline = nil
        windowLayoutAnchor = nil
        windowLayoutTarget = nil
        windowTargetID = nil
        windowTargetIsRestoration = false
        windowNavigationCompletion = nil
        endRestoration()
        pendingGeometry = nil
        pendingFilteredFrames = nil
        pendingCandidates = []
        geometryBaseOffset = nil
        awaitingGeometry = false
        windowPlan = nil
        windowRecovery = true
        checkWindowBand(forceData: true)
        windowRecovery = false
        // The view does not stay where the wait left it. Following, it goes to
        // the end: at once while held there on entry, otherwise gliding, as a
        // following chat always does. Reading, an offset past a shortened end (a
        // shorter chat entered, estimates replaced) came back only at the next
        // touch: blank.
        if let sv = scrollView, !sv.isTracking, !sv.isDragging, !sv.isDecelerating {
            if isPinnedToBottom {
                requestFollow(forceInstant: isHoldingEntryAtEnd || !followGlidesThroughLayout)
            } else if sv.contentOffset.y > maxOffsetY(for: sv) + 0.5 {
                writeContentOffsetY(maxOffsetY(for: sv), in: sv)
            }
        }
        return true
    }

    private func isWindowTargetMounted(_ id: String) -> Bool {
        guard let publication = windowPublication else { return false }
        return windowCommittedSerial == publication.snapshot.serial && rowFrames[id] != nil
            && rowMarkers[id]?.value?.window != nil && publication.snapshot.rows.contains(where: { $0.id == id })
    }

    private func stageWindowTarget(id: String, restoration: Bool, completion: (() -> Void)? = nil) {
        guard windowIndexByID[id] != nil else { return }
        windowAnchorBaseline = nil // Intentional navigation supersedes reading compensation.
        windowLayoutAnchor = nil
        windowLayoutTarget = nil
        windowTargetID = id
        windowTargetIsRestoration = restoration
        windowNavigationCompletion = completion
        windowNavigationCount += 1
        checkWindowBand(forceData: true)
        beginWindowWait("navigation")
        guard let index = windowIndexByID[id], let sv = scrollView else { return }
        let origin = vstackAnchorView?.convert(.zero, to: sv).y ?? 0
        let estimatedCenter = origin + windowRowsOrigin + windowModel.prefix[index] + windowModel.heights[index] / 2
        writeContentOffsetY(min(maxOffsetY(for: sv), max(-sv.adjustedContentInset.top,
            estimatedCenter - sv.bounds.height / 2)), in: sv)
    }

    private func captureWindowLayoutAnchor() {
        guard windowEnabled, windowTargetID == nil, activeRestoration == nil,
              !isPinnedToBottom, let sv = scrollView, let origin = geometryOrigin else { return }
        if windowLayoutAnchor == nil {
            guard let row = firstRowIntersecting(thresholdMaxY: sv.contentOffset.y - origin + topInset + 4) else { return }
            let contentY = origin + row.frame.minY
            windowLayoutAnchor = .init(id: row.id, screenOffset: contentY - sv.contentOffset.y, offsetAtCapture: sv.contentOffset.y)
            if windowAnchorBaseline == nil { windowAnchorBaseline = .init(id: row.id, contentY: contentY) }
        }
        beginWindowWait("resize")
    }

    private func finishWindowNavigation(in sv: UIScrollView, origin: CGFloat, frames: [String: CGRect]) -> Bool {
        guard let id = windowTargetID else { return false }
        let rowY: CGFloat
        let centerY: CGFloat
        if let frame = frames[id], let marker = rowMarkers[id]?.value, marker.window != nil,
           abs(marker.convert(.zero, to: sv).y - (origin + frame.minY)) < 0.5 {
            guard !windowTargetIsRestoration else { return false } // Existing measured restoration path.
            rowY = origin + frame.minY
            centerY = origin + frame.midY
        } else if let index = windowIndexByID[id], !windowModel.hasSlot(at: index) {
            // A confirmed EmptyView has no marker to await; its destination is the
            // zero-height logical boundary, not an absent/unloaded message.
            rowY = origin + windowRowsOrigin + windowModel.prefix[index]
            centerY = rowY
        } else { return false }
        let desired = windowTargetIsRestoration ? rowY - (activeRestoration?.offset ?? 0)
            : centerY - sv.bounds.height / 2
        writeContentOffsetY(min(maxOffsetY(for: sv), max(-sv.adjustedContentInset.top, desired)), in: sv)
        let completion = windowNavigationCompletion
        windowNavigationCompletion = nil
        windowWaitStarted = nil
        if windowTargetIsRestoration { endRestoration() } else { windowTargetID = nil }
        DispatchQueue.main.async { completion?() }
        return true
    }
    #endif

    func bindRowStateRegistry(_ registry: NativeChatRowStateRegistry) {
        windowRowStateRegistry = registry
        registry.onRowStateChanged = { [weak self] id in
            guard let self, self.windowEnabled else { return }
            self.windowDirtyStateRows.insert(id)
            guard !self.windowStateUpdateScheduled else { return }
            self.windowStateUpdateScheduled = true
            // Coalesce state changes/evictions, updating only affected descriptors.
            // No shared ObservableObject notification reaches sibling row bodies.
            DispatchQueue.main.async { [weak self] in self?.flushWindowRowStateChanges() }
        }
    }

    func windowRevision(for id: String, content: UInt64) -> UInt64 {
        let state = windowRowStateRegistry?.revision(forRow: id) ?? 0
        if let old = windowRowRevisionByID[id], old.content == content, old.state == state { return old.token }
        // Assign a fresh identity to the pair rather than adding/hashing revisions:
        // different content/state combinations must never reuse a measured key.
        windowRowRevisionSerial &+= 1
        let next = WindowRowRevision(content: content, state: state, token: windowRowRevisionSerial)
        windowRowRevisionByID[id] = next
        return next.token
    }

    private func flushWindowRowStateChanges() {
        windowStateUpdateScheduled = false
        let dirty = windowDirtyStateRows
        windowDirtyStateRows.removeAll()
        guard windowEnabled else { return }
        var descriptors = windowModel.descriptors
        var changed = false
        for id in dirty {
            guard let index = windowIndexByID[id], let old = windowRowRevisionByID[id] else { continue }
            let revision = windowRevision(for: id, content: old.content)
            guard descriptors[index].revision != revision else { continue }
            let previous = descriptors[index]
            let descriptor = NativeChatWindowModel.Descriptor(id: id, revision: revision,
                kind: previous.kind, estimate: previous.estimate)
            descriptors[index] = descriptor
            windowDescriptorByID[id] = descriptor
            changed = true
        }
        guard changed else { return }
        // Rebuild prefixes once, retaining previous heights as estimates until
        // actual mounted geometry arrives with the new keys.
        windowModel.update(descriptors)
        checkWindowBand(forceData: true)
    }

    fileprivate func configureWindow(rows: [NativeChatRow], publication: NativeChatWindowBand) {
        windowPublication = publication
        #if os(iOS)
        // On by default since step 2's acceptance on the Duo simulator (26 Oct 2026).
        // The key stays as a kill switch: `defaults write io.ripul.app
        // ripul.nativeChat.windowing -bool NO` brings back the eager stack.
        windowEnabled = UserDefaults.standard.object(forKey: "ripul.nativeChat.windowing") as? Bool ?? true
        #else
        windowEnabled = false
        #endif
        updateWindowRows(rows)
    }

    static func makeWindowDescriptor(for row: NativeChatRow, revision: UInt64) -> NativeChatWindowModel.Descriptor {
        let kind: String
        switch row {
        case .gap: kind = "gap"
        case .toolGroup: kind = "tools"
        case .thinking: kind = "thinking"
        case .user: kind = "user"
        case .note: kind = "note"
        case .assistant: kind = "assistant"
        case .taskNotification: kind = "task"
        case .systemStatus: kind = "status"
        case .error: kind = "error"
        case .cliEvent: kind = "cli"
        }
        return NativeChatWindowModel.Descriptor(
            id: row.id,
            revision: revision,
            kind: kind,
            estimate: kind == "gap" || kind == "status" ? 32 : kind == "tools" ? 64 : 100
        )
    }

    func updateWindowRows(_ rows: [NativeChatRow], dirtyRowIDs: Set<String>? = nil) {
        guard windowEnabled else {
            if windowPublication?.snapshot.enabled == true { windowPublication?.snapshot = .init() }
            return
        }
        #if os(iOS) && DEBUG
        let perfStart = CACurrentMediaTime()
        defer {
            perfRowPublications += 1
            perfRowPublicationMs += (CACurrentMediaTime() - perfStart) * 1000.0
            ChatSlideProbe.mark(String(format: "nativeChat.rows %d %.1fms", rows.count, (CACurrentMediaTime() - perfStart) * 1000.0))
        }
        #endif
        #if os(iOS)
        let oldAnchor: (id: String, relativeTop: CGFloat)? = {
            guard !isPinnedToBottom, let sv = scrollView, let anchor = vstackAnchorView else { return nil }
            let localTop = sv.contentOffset.y - anchor.convert(.zero, to: sv).y
            guard let row = firstRowIntersecting(thresholdMaxY: localTop + topInset + 4) else { return nil }
            return (row.id, localTop - row.frame.minY)
        }()
        #endif
        var uniqueRows = rows
        var seenRowIDs = Set<String>(minimumCapacity: rows.count)
        var droppedDuplicateIDs: [String] = []
        for row in rows {
            if !seenRowIDs.insert(row.id).inserted {
                droppedDuplicateIDs.append(row.id)
            }
        }
        if !droppedDuplicateIDs.isEmpty {
            print("[NativeChatScrollCoordinator] Dropping duplicate row IDs in updateWindowRows: \(droppedDuplicateIDs.joined(separator: ", "))")
            seenRowIDs.removeAll(keepingCapacity: true)
            uniqueRows = rows.filter { seenRowIDs.insert($0.id).inserted }
        }
        let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
        let consumedDirty = dirtyRowIDs ?? store?.consumeDirtyRowIds()
        let dirty = (incremental && droppedDuplicateIDs.isEmpty) ? consumedDirty : nil
        let revisions: [UInt64]
        if incremental {
            revisions = windowRevisions.revisions(for: uniqueRows, dirtyIDs: dirty)
        } else {
            revisions = windowRevisions.revisions(for: uniqueRows.map { (id: $0.id, value: $0) })
        }
        let sameRowIDs = windowModel.descriptors.count == uniqueRows.count
            && zip(windowModel.descriptors, uniqueRows).allSatisfy { $0.id == $1.id }
        // New rows (a page landing) are new ground for the rest band to grow over.
        if !sameRowIDs { windowGrowthStepsThisRest = 0 }
        #if os(iOS)
        windowLastRowsPublication = CACurrentMediaTime()
        // Once the rows have been still for 3 s the chat counts as quiet: grow then,
        // whether or not anything else happens (a chat left at its tail included).
        windowQuietWorkItem?.cancel()
        let quiet = DispatchWorkItem { [weak self] in
            self?.windowGrowthStepsThisRest = 0
            self?.scheduleWindowGrowth(after: 0)
        }
        windowQuietWorkItem = quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.05, execute: quiet)
        #endif
        windowRows = uniqueRows
        let descriptors: [NativeChatWindowModel.Descriptor]
        if incremental, sameRowIDs, let dirty {
            var updatedDescriptors = windowModel.descriptors
            for id in dirty {
                guard let idx = windowIndexByID[id] else { continue }
                let row = uniqueRows[idx]
                let descriptor = Self.makeWindowDescriptor(for: row, revision: windowRevision(for: id, content: revisions[idx]))
                updatedDescriptors[idx] = descriptor
                windowDescriptorByID[id] = descriptor
            }
            descriptors = updatedDescriptors
            windowModel.update(descriptors)
        } else {
            descriptors = zip(uniqueRows, revisions).map { row, contentRevision in
                Self.makeWindowDescriptor(for: row, revision: windowRevision(for: row.id, content: contentRevision))
            }
            if !incremental || !sameRowIDs {
                windowRowRevisionByID = windowRowRevisionByID.filter { seenRowIDs.contains($0.key) }
                windowIndexByID = Dictionary(
                    descriptors.enumerated().map { ($0.element.id, $0.offset) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            windowModel.update(descriptors)
            windowDescriptorByID = Dictionary(
                descriptors.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        #if os(iOS)
        if let oldAnchor, let index = windowIndexByID[oldAnchor.id] {
            windowPlanningTopOverride = windowModel.prefix[index] + oldAnchor.relativeTop
        }
        #endif
        #if os(iOS)
        if let restoration = activeRestoration, let webID = restoration.webRowId,
           let id = store?.resolveNativeRowId(forWebRowId: webID), windowIndexByID[id] != nil,
           windowTargetID != id, !isWindowTargetMounted(id) {
            stageWindowTarget(id: id, restoration: true)
            windowPlanningTopOverride = nil
            return
        }
        #endif
        checkWindowBand(forceData: true)
        windowPlanningTopOverride = nil
    }

    #if os(iOS)
    /// The screen in ledger coordinates: its top placed from the row it shows,
    /// else from the scroll offset; at the tail while following.
    private func windowViewport() -> Range<CGFloat> {
        let screen = max(1, scrollView?.bounds.height ?? 800)
        let origin = vstackAnchorView.flatMap { anchor in scrollView.map { anchor.convert(.zero, to: $0).y } } ?? 0
        let localTop = (scrollView?.contentOffset.y ?? 0) - origin
        let projectedTop: CGFloat? = {
            guard !windowRecovery, let row = firstRowIntersecting(thresholdMaxY: localTop + topInset + 4),
                  let index = windowIndexByID[row.id] else { return nil }
            return windowModel.prefix[index] + localTop - row.frame.minY
        }()
        let top = isPinnedToBottom ? max(0, windowModel.totalHeight - screen)
            : max(0, windowPlanningTopOverride ?? projectedTop ?? (localTop - windowRowsOrigin))
        return top..<(top + screen)
    }

    /// A finger, a coast or an animated scroll is moving the view.
    private var windowMoving: Bool {
        guard let sv = scrollView else { return false }
        return sv.isTracking || sv.isDragging || sv.isDecelerating || CACurrentMediaTime() - windowLastOffsetMotion < 0.1
    }

    /// A turn is running, or rows changed in the last 3 s (a page just landed). A
    /// tool-heavy turn pauses for seconds between rows: it must not count as quiet,
    /// or the band would grow and shrink again around every tool call.
    private var windowChatActive: Bool {
        CACurrentMediaTime() - windowLastRowsPublication < 3 || bridge?.isAgentRunning == true
    }

    /// How many rows the band may hold. A chat at rest grows toward every row it has
    /// loaded: with every row mounted a scroll back through history moved nothing but
    /// the offset (27 Oct 2026, Duo: fast flings at 112 rows 8 hitches, against 23 for
    /// the moving band). While rows change it keeps few: a streamed change then costs
    /// far less (main thread 75% against 100% with 83 rows mounted).
    private var windowRestCap: Int { windowChatActive ? 64 : 160 }

    /// The band holds still through a fling and grows at rest (`steadyBand`), unless
    /// something else places it: navigation, restoration or recovery, and the follow
    /// of a chat whose rows are changing. A coast that pins near the tail still holds
    /// it until it stops; a quiet chat at the tail grows its band above the screen.
    private func windowBandHoldsStill(moving: Bool) -> Bool {
        NativeChatPerformance.isEnabled(.steadyBand) && windowTargetID == nil && !windowRecovery
            && activeRestoration == nil && !isRestoring && (moving || !isPinnedToBottom || !windowChatActive)
    }

    /// The band as mounted, in the current row order. After rows land above or below
    /// it the same rows by id: a page landing above shifts every index.
    private func retainedWindowPlan() -> NativeChatWindowModel.Plan? {
        guard let current = windowPlan else { return nil }
        if current.structureGeneration == windowModel.structureGeneration { return current }
        guard let publication = windowPublication, publication.snapshot.enabled,
              let first = publication.snapshot.rows.first?.id, let last = publication.snapshot.rows.last?.id,
              let lower = windowIndexByID[first], let upper = windowIndexByID[last], lower <= upper else { return nil }
        return windowModel.geometry(for: lower..<(upper + 1))
    }

    private func scheduleWindowGrowth(after delay: TimeInterval = 0.03) {
        guard windowEnabled, !windowGrowthScheduled else { return }
        windowGrowthScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.windowGrowthScheduled = false
            self.stepWindowGrowth()
        }
    }

    /// A turn of the phone is about to lay the chat out at a new width
    /// (`SizeTransitionReader`, before the system lays the turn out). Every mounted
    /// row is laid out again at that width inside the turn, and a chat of up to 80
    /// rows has all of them mounted: on the open Duo a turn of the Agents screen took
    /// 0.92 to 0.95 s of main thread against 0.25 to 0.3 s on Home (7 November 2026).
    /// So for the turn only the rows on screen and a screen either side stay mounted;
    /// the rest wait as filler on their measured heights and come back at rest a few
    /// rows a step, as a long chat's band grows. Only at the tail, where the chat
    /// stays pinned to its end through any change of height: reading further back,
    /// the turn keeps every row, as before.
    func beginSizeTransition() {
        guard windowEnabled, NativeChatPerformance.isEnabled(.steadyBand), isPinnedToBottom,
              let publication = windowPublication, publication.snapshot.enabled,
              windowTargetID == nil, !windowRecovery, activeRestoration == nil, !isRestoring,
              windowAnchorBaseline == nil, windowLayoutAnchor == nil,
              let current = windowPlan, !windowRows.isEmpty else { return }
        windowTurnUntil = CACurrentMediaTime() + 0.6
        let plan = windowModel.restPlan(viewport: windowViewport(), direction: .stationary,
                                        ahead: 1, behind: 1, cap: 24)
        guard plan.range.count < current.range.count else { return }
        windowTurnBand = true
        windowGrowthStepsThisRest = 0
        ChatSlideProbe.mark("turn: chat band \(plan.range.lowerBound)..\(plan.range.upperBound) of \(windowRows.count)")
        checkWindowBand(publishing: plan)
        // Not published (a correction was pending): nothing was cut.
        if windowPlan?.range != plan.range { windowTurnBand = false }
        scheduleWindowGrowth(after: 0.6)
    }

    /// At rest, grow the band toward the rest band a few rows at a time, nearest the
    /// screen first, so the next fling finds its rows mounted and measured, and their
    /// height corrections land while nothing moves. A touch stops it; the band then
    /// holds still, and the next rest resumes it.
    private func stepWindowGrowth() {
        // The turn is still being laid out or animated: grow once it has finished.
        let turnLeft = windowTurnUntil - CACurrentMediaTime()
        if turnLeft > 0 {
            scheduleWindowGrowth(after: turnLeft)
            return
        }
        // Following a chat whose rows change, a band grown while it was quiet shrinks
        // here a few rows a step; nothing grows.
        let following = isPinnedToBottom && windowChatActive
        guard windowEnabled, windowRows.count > 80 || windowTurnBand, windowGrowthStepsThisRest < 48,
              following || windowBandHoldsStill(moving: false),
              NativeChatPerformance.isEnabled(.steadyBand), windowTargetID == nil, !windowRecovery,
              activeRestoration == nil, !isRestoring,
              let sv = scrollView, !sv.isTracking, !sv.isDragging, !sv.isDecelerating,
              let publication = windowPublication, let current = retainedWindowPlan() else { return }
        // UIKit has stopped but the offset moved a moment ago (the grace that covers an
        // animated scroll): try again when it lapses, since nothing else may.
        if windowMoving {
            scheduleWindowGrowth(after: 0.12)
            return
        }
        // The bottom inset is moving with the keyboard: the chat is laid out again every
        // frame of it, and a step's correction waits until it stops, so rows just mounted
        // above pushed the chat down 500-600 pt for half a second as a message was sent.
        // Grow once it has settled.
        // Not while the keyboard is up; its going down plans the band again, which
        // schedules growth.
        if smoothFollow, keyboardIsUp { return }
        if smoothFollow, CACurrentMediaTime() < followsKeyboardUntil + 0.15 {
            scheduleWindowGrowth(after: followsKeyboardUntil + 0.15 - CACurrentMediaTime())
            return
        }
        // The last step's layout and its correction land first: one step per laid-out
        // band, so steps never pile into one commit (a timer alone does not ensure it).
        // (Not `awaitingGeometry`: a content-size change can leave it set with nothing pending.)
        if windowCommittedSerial != publication.snapshot.serial
            || windowAnchorBaseline != nil || windowLayoutAnchor != nil || pendingGeometry != nil
            || windowMeasurementScheduled || windowWaitStarted != nil {
            // About a second of waiting, then the next rest, landing or band check
            // tries again: a layout that never reports must not wake the phone at rest.
            windowGrowthWaits += 1
            if windowGrowthWaits <= 20 { scheduleWindowGrowth(after: 0.05) }
            return
        }
        windowGrowthWaits = 0
        // Quiet: toward every loaded row (up to the cap), nearest the screen first.
        // Rows changing: 3 screens ahead and 2 behind; following them, the follow band.
        let reach: CGFloat = windowChatActive ? 3 : 1000
        let target = following ? windowModel.plan(viewport: windowViewport())
            : windowModel.restPlan(viewport: windowViewport(), direction: windowTravel,
                                   ahead: reach, behind: windowChatActive ? 2 : reach, cap: windowRestCap)
        guard let next = windowModel.growthStep(current: current.range, target: target, direction: windowTravel, step: 6),
              next.range != current.range, !following || next.range.count < current.range.count else { return }
        // Rows streaming in, or a page just landed: grow once they have been quiet a
        // moment, so growth never interleaves with a reply's own publications. A band
        // grown while the chat was quiet shrinks at once: that is what keeps a stream cheap.
        if next.range.count >= current.range.count, CACurrentMediaTime() - windowLastRowsPublication < 0.5 {
            scheduleWindowGrowth(after: 0.6)
            return
        }
        // Small differences at the far edges are left alone, within the band's size:
        // dropping and adding a row as corrections nudge the screen would never settle.
        if next.range.count < current.range.count, current.range.count <= windowRestCap,
           current.range.count - target.range.count <= 4 { return }
        windowGrowthStepsThisRest += 1
        windowGrowthSteps += 1
        windowLastGrowthPublication = CACurrentMediaTime()
        checkWindowBand(publishing: next)
        scheduleWindowGrowth()
    }
    #endif

    private func checkWindowBand(forceData: Bool = false, publishing chosen: NativeChatWindowModel.Plan? = nil) {
        guard windowEnabled, let publication = windowPublication else { return }
        #if os(iOS)
        if windowAnchorBaseline != nil || windowLayoutAnchor != nil {
            windowNeedsDataPublication = windowNeedsDataPublication || forceData
            return
        }
        #endif
        let publishData = forceData || windowNeedsDataPublication
        let plan: NativeChatWindowModel.Plan
        if let chosen {
            plan = chosen
        } else if windowRows.count <= 80 && !windowTurnBand {
            plan = windowModel.geometry(for: 0..<windowRows.count)
        } else {
            #if os(iOS)
            let viewport = windowViewport()
            let moving = windowMoving
            // Rows just landed or left: this pass keeps the same rows mounted (the landed
            // ones enter as filler) and nothing grows or goes until the next.
            let landed = windowPlan.map { $0.structureGeneration != windowModel.structureGeneration } ?? false
            if windowBandHoldsStill(moving: moving), let current = retainedWindowPlan() {
                // Moving: keep the band, growing its leading edge only as the screen
                // nears it. At rest: keep it while it covers the screen, and grow it
                // toward the rest band in steps.
                // Mid-fling growth waits until the screen is half a screen from the edge,
                // then reaches two screens ahead in one change: each band change costs
                // about a frame, so fewer, larger ones lose less.
                plan = moving && !landed
                    ? windowModel.motionPlan(viewport: viewport, current: current, direction: windowTravel,
                                             cap: windowRestCap)
                    : windowModel.motionPlan(viewport: viewport, current: current, direction: .stationary,
                                             margin: 0, step: 0, cap: .max)
                if !moving { scheduleWindowGrowth() }
            } else if isPinnedToBottom, windowChatActive, NativeChatPerformance.isEnabled(.steadyBand),
                      windowTargetID == nil, !windowRecovery, activeRestoration == nil, !isRestoring,
                      let current = retainedWindowPlan(), current.range.count > 48 {
                // Following a changing chat with a band grown while it was quiet: keep
                // its rows and add the tail. It shrinks to the follow band a few rows a
                // step (stepWindowGrowth), never all at once in the frame a message is sent.
                plan = windowModel.motionPlan(viewport: viewport, current: current, direction: .stationary,
                                              margin: 0, step: 0, cap: .max)
                if !moving { scheduleWindowGrowth() }
            } else {
                let velocity = scrollView?.panGestureRecognizer.velocity(in: scrollView).y ?? 0
                plan = windowModel.plan(viewport: viewport, current: windowPlan,
                    direction: velocity > 0 ? .up : velocity < 0 ? .down : .stationary, fast: abs(velocity) > 1000,
                    targetID: windowTargetID)
            }
            #else
            plan = windowModel.geometry(for: 0..<windowRows.count)
            #endif
        }
        let changed = windowPlan?.range != plan.range || windowPlan?.top != plan.top || windowPlan?.bottom != plan.bottom
        windowPlan = plan
        // Grown back to every row after a turn: a short chat mounts them all again.
        if windowTurnBand, plan.range.lowerBound == 0, plan.range.upperBound >= windowRows.count {
            windowTurnBand = false
        }
        windowNeedsDataPublication = false
        guard changed || publishData || !publication.snapshot.enabled else { return }
        let mountedRows = Array(windowRows[plan.range])
        let current = publication.snapshot
        let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
        let mountedRowsEqual: Bool = {
            guard current.enabled, mountedRows.count == current.rows.count else { return false }
            guard incremental else { return mountedRows == current.rows }
            for (lhs, rhs) in zip(mountedRows, current.rows) {
                guard lhs.id == rhs.id else { return false }
                if let lhsRev = windowDescriptorByID[lhs.id]?.revision,
                   let rhsRev = windowPublishedDescriptors[rhs.id]?.revision,
                   lhsRev == rhsRev {
                    continue
                }
                if lhs != rhs { return false }
            }
            return true
        }()
        guard !current.enabled || !mountedRowsEqual || plan.top != current.top || plan.bottom != current.bottom else {
            // Equal UI values can have newer revision tokens after deferred/ABA
            // updates. Keep measurement keys current without changing the serial.
            windowPublishedDescriptors = windowDescriptorByID
            return
        }
        let sameMountedIDs = current.enabled
            && mountedRows.count == current.rows.count
            && zip(mountedRows, current.rows).allSatisfy { $0.id == $1.id }
        let bandStructureChanged = !current.enabled
            || changed
            || !sameMountedIDs
            || plan.top != current.top
            || plan.bottom != current.bottom
        // Growth at rest is counted on its own (`grow=`), not as a move.
        if changed && chosen == nil { windowMoves += 1 }
        var snapshot = NativeChatWindowBand.Snapshot()
        snapshot.enabled = true
        snapshot.rows = mountedRows
        snapshot.top = plan.top
        snapshot.bottom = plan.bottom
        if useMarkerFrames && !bandStructureChanged {
            snapshot.serial = max(1, publication.snapshot.serial)
        } else {
            snapshot.serial = publication.snapshot.serial &+ 1
        }
        #if os(iOS)
        // Capture UIKit's actual committed position BEFORE publishing the next band.
        // Preference callbacks may otherwise replace rowFrames with an intermediate
        // band pass, losing the old geometry before a coherent pass is ready.
        if (!useMarkerFrames || bandStructureChanged),
           !windowRecovery, activeRestoration == nil, windowTargetID == nil, let sv = scrollView, let anchor = vstackAnchorView {
            let localTop = sv.contentOffset.y - anchor.convert(.zero, to: sv).y
            let ids = Set(snapshot.rows.map(\.id))
            let common = orderedRowFrames.filter { ids.contains($0.id) }
            let pinned = windowLayoutAnchor.flatMap { layoutAnchor in common.first(where: { $0.id == layoutAnchor.id }) }
            let choice = pinned ?? (isPinnedToBottom ? common.last
                : common.first(where: { $0.frame.maxY > localTop + topInset + 4 })
                    ?? common.first(where: { $0.frame.maxY > localTop }))
            if let choice, let marker = rowMarkers[choice.id]?.value, marker.window != nil {
                let referenceY: CGFloat
                if let layoutAnchor = windowLayoutAnchor, layoutAnchor.id == choice.id {
                    referenceY = layoutAnchor.screenOffset + layoutAnchor.offsetAtCapture
                } else { referenceY = marker.convert(.zero, to: sv).y }
                windowAnchorBaseline = .init(id: choice.id, contentY: referenceY)
            } else if !rowFrames.isEmpty { windowMissingAnchor += 1 }
        }
        #endif
        windowPublishedDescriptors = windowDescriptorByID
        #if os(iOS)
        windowPublishedLayout = windowModel.layout
        #endif
        var transaction = Transaction()
        transaction.disablesAnimations = true
        ChatSlideProbe.mark("nativeChat.band \(plan.range.lowerBound)..\(plan.range.upperBound) of \(windowRows.count)")
        withTransaction(transaction) { publication.snapshot = snapshot }
        #if os(iOS)
        if useMarkerFrames && !bandStructureChanged {
            scheduleMarkerDataDeltaCheck()
        } else if windowAnchorBaseline != nil {
            beginWindowWait("band")
        }
        #endif
    }

    #if os(iOS)
    private func scheduleWindowMeasurements(_ allFrames: [String: CGRect]) {
        guard windowEnabled, let publication = windowPublication,
              allFrames["__window:\(publication.snapshot.serial)"] != nil,
              let section = allFrames["__rows"], section.width > 0 else { return }
        let scale = scrollView?.window?.screen.scale ?? 2
        let layout = NativeChatWindowModel.LayoutKey(width: (section.width * scale).rounded() / scale,
            scale: scale, textMetrics: windowTextMetrics)
        let serial = publication.snapshot.serial
        let captured = publication.snapshot.rows.compactMap { row -> (NativeChatWindowModel.HeightKey, CGFloat)? in
            guard let frame = allFrames[row.id], let descriptor = windowPublishedDescriptors[row.id] else { return nil }
            return (.init(id: descriptor.id, revision: descriptor.revision, layout: layout), frame.height)
        }
        windowRowsOrigin = section.minY
        windowMeasurementJob = { [weak self, weak publication] in
            guard let self, let publication, publication.snapshot.serial == serial else { return }
            let layoutChanged = self.windowModel.layout != layout
            if layoutChanged {
                self.windowModel.changeLayoutPreservingEstimates(layout)
                self.windowLayoutTarget = nil
            }
            self.windowModel.measure(captured)
            ChatSlideProbe.mark("nativeChat.measure \(captured.count)")
            let missing = self.windowConfirmedMissing
            self.windowConfirmedMissing = []
            self.windowModel.setNoSlot(missing)
            self.checkWindowBand(forceData: layoutChanged || !missing.isEmpty)
        }
        guard !windowMeasurementScheduled else { return }
        windowMeasurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowMeasurementScheduled = false
            let job = self.windowMeasurementJob
            self.windowMeasurementJob = nil
            job?()
        }
    }
    #endif

    var rowFrames: [String: CGRect] = [:] {
        didSet {
            #if os(iOS) && DEBUG
            let prepStart = CACurrentMediaTime()
            #endif
            rebuildOrderedRowFrames()
            #if os(iOS) && DEBUG
            perfPrepMs += (CACurrentMediaTime() - prepStart) * 1000.0
            #endif
        }
    }
    private(set) var orderedRowFrames: [(id: String, frame: CGRect)] = []
    var activeRestoration: NativeChatScrollPosition? = nil
    var pendingLoadMoreSnapshot: NativeChatScrollPosition? = nil
    var isRestoring: Bool = false
    var isPinnedToBottom: Bool = true
    var shownAt: Date = Date()
    #if os(iOS)
    /// Until when a chat that was just entered is held at its end (`pinEntryToEnd`).
    private var entryPinUntil: CFTimeInterval = 0
    private static let entryPinSeconds: CFTimeInterval = 3
    #endif
    var topInset: CGFloat = 0
    weak var store: NativeChatMessageStore?
    weak var bridge: AgentBridge?
    var onPinnedChange: ((Bool) -> Void)?
    var onNearTopLoadMore: ((Bool) -> Void)?
    var onFlushHeldRows: (() -> Void)?
    var onReleaseHeldTailRows: (() -> Void)?
    // Rows below the screen that changed while the reader was away from the
    // tail of a live chat, not yet published (see holdsTailChange).
    private var tailRowsHeld = false
    private var heldTailFirstIndex = Int.max
    private var syncWorkItem: DispatchWorkItem?
    private var autoLoadWorkItem: DispatchWorkItem?
    private var restorationGeneration: Int = 0
    private var probedUntruncatedChatId: String? = nil
    private var wasPullingPastTop: Bool = false

    func configure(
        store: NativeChatMessageStore,
        bridge: AgentBridge?,
        topInset: CGFloat,
        onPinnedChange: @escaping (Bool) -> Void,
        onNearTopLoadMore: @escaping (Bool) -> Void,
        onFlushHeldRows: @escaping () -> Void,
        onReleaseHeldTailRows: @escaping () -> Void
    ) {
        self.store = store
        self.bridge = bridge
        self.topInset = topInset
        self.onPinnedChange = onPinnedChange
        self.onNearTopLoadMore = onNearTopLoadMore
        self.onFlushHeldRows = onFlushHeldRows
        self.onReleaseHeldTailRows = onReleaseHeldTailRows
    }

    // MARK: Tail rows held while reading away from the bottom
    //
    // While an agent works, rows at the tail change several times a second.
    // Publishing each change re-ran the window model over every row and
    // SwiftUI's row diff on the main thread, mid-drag, for rows nobody could
    // see (Peter, 26 Oct 2026). While the reader is away from the tail, a
    // change that touches only rows below the screen is held; the store keeps
    // the data. Held rows publish on return to the bottom, when a scroll comes
    // to rest with a held row on screen, or before a jump.

    private var tailHoldEnabled: Bool {
        // On by default since the streaming-chat measurement (26 Oct 2026); the
        // key is a kill switch, read live.
        UserDefaults.standard.object(forKey: "ripul.nativeChat.holdTailWhileAway") as? Bool ?? true
    }

    /// Whether to hold `incoming` back: true when it differs from `published`
    /// only in rows below the screen while the reader is away from the tail.
    func holdsTailChange(from published: [NativeChatRow], to incoming: [NativeChatRow]) -> Bool {
        #if os(iOS)
        guard windowEnabled, tailHoldEnabled, !isPinnedToBottom, !isRestoring,
              activeRestoration == nil, windowTargetID == nil, store?.pendingScrollRestoration == nil,
              !published.isEmpty, let lastVisible = lastVisibleRowIndex() else {
            tailRowsHeld = false
            heldTailFirstIndex = .max
            return false
        }
        let shared = min(published.count, incoming.count)
        var firstChange = shared
        for index in 0..<shared where published[index] != incoming[index] {
            firstChange = index
            break
        }
        // The reader's own new message always shows: sending one re-engages
        // follow (handleDisplayedRowsChanged).
        let sendsOwnMessage = incoming.count > shared && incoming[shared...].contains { row in
            if case .user(let message) = row { return message.isOwnMessage }
            return false
        }
        guard firstChange > lastVisible, !sendsOwnMessage else {
            tailRowsHeld = false
            heldTailFirstIndex = .max
            return false
        }
        if firstChange == shared && published.count == incoming.count {
            tailRowsHeld = false
            heldTailFirstIndex = .max
            return false
        }
        tailRowsHeld = true
        heldTailFirstIndex = min(heldTailFirstIndex, firstChange)
        #if DEBUG
        perfTailHolds += 1
        #endif
        return true
        #else
        return false
        #endif
    }

    func releaseHeldTailRows() {
        guard tailRowsHeld else { return }
        tailRowsHeld = false
        heldTailFirstIndex = .max
        onReleaseHeldTailRows?()
    }

    #if os(iOS)
    /// At rest: publish held rows once one of them is on screen.
    private func releaseHeldTailRowsIfOnScreen() {
        guard tailRowsHeld else { return }
        if isPinnedToBottom || !tailHoldEnabled || (lastVisibleRowIndex().map { heldTailFirstIndex <= $0 } ?? true) {
            releaseHeldTailRows()
        }
    }

    /// Index in the published rows of the last row whose top is above the
    /// bottom of the screen.
    private func lastVisibleRowIndex() -> Int? {
        guard let sv = scrollView, let anchor = vstackAnchorView, !orderedRowFrames.isEmpty else { return nil }
        let screenBottom = sv.contentOffset.y - anchor.convert(.zero, to: sv).y + sv.bounds.height
        let frames = orderedRowFrames
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].frame.minY < screenBottom { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        return windowIndexByID[frames[low - 1].id]
    }
    #endif

    func endRestoration() {
        if windowTargetIsRestoration {
            windowTargetID = nil
            windowTargetIsRestoration = false
        }
        #if os(iOS)
        if windowTargetID == nil && windowAnchorBaseline == nil && pendingGeometry == nil { windowWaitStarted = nil }
        #endif
        activeRestoration = nil
        isRestoring = false
    }

    func resetForChatSwitch() {
        shownAt = Date()
        if windowEnabled {
            #if os(iOS)
            windowAnchorBaseline = nil
            windowLayoutAnchor = nil
            windowLayoutTarget = nil
            windowPublishedLayout = nil
            windowWaitStarted = nil
            windowWaitTicks = 0
            #endif
            windowNeedsDataPublication = false
            windowTurnBand = false
            windowTurnUntil = 0
            windowTargetID = nil
            windowNavigationCompletion = nil
            windowTargetIsRestoration = false
            windowMissingPasses = [:]
            windowConfirmedMissing = []
            windowCommittedSerial = 0
            windowPlan = nil
            windowDescriptorByID = [:]
            windowRowsOrigin = 0
            lastContainerFrames = [:]
            markerDeltaCheckScheduled = false
            windowTravel = .stationary
            windowGrowthStepsThisRest = 0
            windowGrowthWaits = 0
            windowQuietWorkItem?.cancel()
            windowQuietWorkItem = nil
            windowLastRowsPublication = 0
        }
        pendingLoadMoreSnapshot = nil
        probedUntruncatedChatId = nil
        wasPullingPastTop = false
        autoLoadWorkItem?.cancel()
        autoLoadWorkItem = nil
        // Row frames, their origin and the marker registry are kept: the chat id can
        // change (nil → the real id) while the same rows stay on screen, and no new
        // geometry batch arrives until a row moves, so clearing them left the next
        // growth with nothing to anchor. The next layout commit replaces them.
        endRestoration()
        stopFollowAnimation()
        // The chat switched to opens at its end unless the web chat's place is
        // waiting (the web/native switch): the window then plans that end with
        // the new rows, not where the last chat was being read.
        if store?.pendingScrollRestoration == nil { isPinnedToBottom = true }
        #if os(iOS)
        // Entering the new chat holds it at its end again (`pinEntryToEnd`).
        entryPinUntil = 0
        stopWaitForDecelerationEnd()
        #if DEBUG
        stopScrollPerfTracking(log: false)
        #endif
        hasHeldRowPublication = false
        pendingFollowAfterDeceleration = false
        pendingForceInstantFollow = false
        awaitingGeometry = false
        pendingGeometry = nil
        pendingFilteredFrames = nil
        pendingCandidates = []
        geometryBaseOffset = nil
        #endif
    }

    var shouldHoldRowPublication: Bool {
        #if os(iOS)
        guard !isRestoring,
              activeRestoration == nil,
              store?.pendingScrollRestoration == nil,
              let sv = scrollView,
              sv.isDecelerating || isKeyboardDropping else {
            return false
        }
        return true
        #else
        return false
        #endif
    }

    func scheduleFlushHeldRowsAtRest() {
        #if os(iOS)
        hasHeldRowPublication = true
        if isKeyboardDropping, scrollView?.isDecelerating != true {
            // Published once the keyboard is down (the deceleration wait would publish
            // them at once, with nothing decelerating).
            flushHeldRowsOnceKeyboardIsDown()
            return
        }
        scheduleWaitForDecelerationEnd()
        #endif
    }

    #if os(iOS)
    /// Publishes held rows when the inset has stopped dropping. A message of more than
    /// one line drops it twice: the keyboard, then the composer shrinking as its text
    /// clears, which waits again. The first wait used to find the second running and
    /// give up, so the message stayed held until the reply's first row (Peter,
    /// 5 November 2026: "anything over 1 line just appears").
    private func flushHeldRowsOnceKeyboardIsDown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, holdRowsUntil - CACurrentMediaTime()) + 0.01) { [weak self] in
            guard let self, self.hasHeldRowPublication, self.scrollView?.isDecelerating != true else { return }
            if self.isKeyboardDropping {
                self.flushHeldRowsOnceKeyboardIsDown()
                return
            }
            self.hasHeldRowPublication = false
            self.onFlushHeldRows?()
        }
    }
    #endif

    func setFollowing(_ following: Bool) {
        if following {
            #if os(iOS)
            windowLayoutAnchor = nil
            windowLayoutTarget = nil
            #endif
            endRestoration()
            releaseHeldTailRows()
        } else {
            stopFollowAnimation()
            #if os(iOS)
            pendingFollowAfterDeceleration = false
            pendingForceInstantFollow = false
            #endif
        }
        if isPinnedToBottom != following {
            isPinnedToBottom = following
            #if os(iOS)
            if following && windowEnabled {
                // Explicit follow supersedes the old reading position. Mount the
                // destination before moving through its estimated filler.
                windowAnchorBaseline = nil
                checkWindowBand()
            }
            #endif
        }
        onPinnedChange?(following)
    }

    /// A chat that is entered opens at its end (Peter, 27 Oct 2026: it opened
    /// blank until a scroll, or partway up). For a few seconds after, while
    /// estimates are replaced by measured rows and a catch-up rewrites the tail,
    /// each change of the content's height follows to the end at once, without
    /// waiting for a layout pass to agree. The first touch ends it.
    func pinEntryToEnd() {
        #if os(iOS)
        entryPinUntil = CACurrentMediaTime() + Self.entryPinSeconds
        #if DEBUG
        entryTraceStart = CACurrentMediaTime()
        entryTrace("pin rows=\(windowRows.count)" + (scrollView.map { " " + Self.geometry($0) } ?? ""))
        #endif
        #endif
        shownAt = Date()
        setFollowing(true)
        requestFollow(forceInstant: true)
    }

    #if os(iOS) && DEBUG
    /// When the last entry pinned the chat to its end: for 3 s after, `[ENTRYNOD]` logs
    /// every offset write, every move of the offset by anyone else, and every change of
    /// the content's size, the scroll view's height and the chat's insets, each with the
    /// animation it was made in. What moves a chat as it slides in (the nod, 8 November
    /// 2026).
    private var entryTraceStart: CFTimeInterval = 0

    func entryTrace(_ message: @autoclosure () -> String) {
        let now = CACurrentMediaTime()
        guard entryTraceStart > 0, now - entryTraceStart < 3 else { return }
        bridge?.handleConsoleLog("LOG: [ENTRYNOD] +\(Int((now - entryTraceStart) * 1000))ms \(message())")
    }

    private static func geometry(_ sv: UIScrollView) -> String {
        let inset = sv.adjustedContentInset
        return String(format: "size=%.0f h=%.0f inset=%.0f/%.0f end=%.0f", sv.contentSize.height, sv.bounds.height,
                      inset.top, inset.bottom, sv.contentSize.height - sv.bounds.height + inset.bottom)
    }
    #else
    func entryTrace(_ message: @autoclosure () -> String) {}
    #endif

    #if os(iOS)
    private var isHoldingEntryAtEnd: Bool {
        isPinnedToBottom && CACurrentMediaTime() < entryPinUntil
    }

    /// The follow may glide while a layout pass is pending: nothing else places the
    /// offset (a jump, a restoration, a resize's anchor) and no instant follow waits
    /// for that pass.
    private var followGlidesThroughLayout: Bool {
        smoothFollow && windowEnabled && isPinnedToBottom && windowTargetID == nil && activeRestoration == nil
            && !isRestoring && windowLayoutAnchor == nil && !pendingForceInstantFollow
    }

    /// Settings > Debug > Native Chat Performance > Smooth follow (on unless turned off).
    private var smoothFollow: Bool { NativeChatPerformance.isEnabled(.smoothFollow) }

    /// Until when the follow keeps up with the keyboard, on the stiffer spring.
    private var followsKeyboardUntil: CFTimeInterval = 0
    /// Until when new rows wait while the keyboard goes down (`followTheKeyboard`).
    private var holdRowsUntil: CFTimeInterval = 0
    private var isKeyboardDropping: Bool { smoothFollow && CACurrentMediaTime() < holdRowsUntil }
    /// The system keyboard is up. The band does not grow meanwhile: a send lowers it, and a
    /// growth step whose correction lands under the keyboard's animated inset pushed the
    /// chat down 665 pt as the message went in. Someone typing is not scrolling back, and
    /// the band grows once the keyboard is down and the chat is quiet again.
    private var keyboardIsUp = false
    private var watchesTheKeyboard = false

    /// Hears the keyboard from the system as it starts to move, a turn before the chat's
    /// bottom inset follows it (the inset comes through `KeyboardObserver` and a SwiftUI
    /// update), so nothing grows or lands in between. Selector observers, which go when
    /// the coordinator does.
    private func watchTheKeyboard() {
        guard !watchesTheKeyboard else { return }
        watchesTheKeyboard = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        keyboardIsUp = true
        followsKeyboardUntil = max(followsKeyboardUntil, CACurrentMediaTime() + 0.45)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardIsUp = false
        followsKeyboardUntil = max(followsKeyboardUntil, CACurrentMediaTime() + 0.45)
        if smoothFollow, isPinnedToBottom {
            holdRowsUntil = max(holdRowsUntil, CACurrentMediaTime() + 0.45)
        }
    }
    #endif

    /// The chat's bottom inset changed (the keyboard or the composer): for a moment the
    /// follow moves on the stiffer spring, in either direction, to keep the last message
    /// on the composer as it moves. Going down, new rows wait until it has: the sent
    /// message, published 80 ms into the keyboard's 0.45 s, ended the inset's animation
    /// at once (a band publication runs without animation), and the chat dropped the
    /// rest of the keyboard's height in one frame.
    func followTheKeyboard(dropping: Bool) {
        #if os(iOS)
        followsKeyboardUntil = CACurrentMediaTime() + 0.45
        if dropping, isPinnedToBottom { holdRowsUntil = CACurrentMediaTime() + 0.4 }
        #endif
    }

    func stopFollowAnimation() {
        #if os(iOS)
        followDisplayLink?.invalidate()
        followDisplayLink = nil
        lastFollowFrameTimestamp = 0
        followVelocity = 0
        if !hasHeldRowPublication && !pendingFollowAfterDeceleration && activeRestoration == nil
            && (!windowEnabled || (windowAnchorBaseline == nil && windowTargetID == nil && windowWaitStarted == nil)) {
            stopWaitForDecelerationEnd()
        }
        #endif
    }

    /// - Parameter checkingBand: false only to start a glide from a content-size change,
    ///   mid-layout, where planning the band again would publish one against frames
    ///   the pass has not reported yet.
    func requestFollow(forceInstant: Bool = false, checkingBand: Bool = true) {
        #if os(iOS)
        if checkingBand && windowEnabled && isPinnedToBottom { checkWindowBand() }
        // Held at the end on entry, the end is the reader's place: nothing above
        // it needs the pending layout's correction before the offset moves. A glide
        // need not wait either: windowed corrections land on the live offset, so
        // they move with it. It waited out every band change, and a band grown while
        // the chat sat quiet shrinks in steps as a message is sent: the message sat
        // under the composer for over half a second, then the chat leapt to it.
        if awaitingGeometry && !isHoldingEntryAtEnd && (forceInstant || !followGlidesThroughLayout) {
            if forceInstant {
                pendingForceInstantFollow = true
            }
            return
        }
        guard isPinnedToBottom, !isRestoring, let sv = scrollView, sv.bounds.height > 0 else { return }
        // Held at the end on entry: settle to the tail at once. Smooth follow glides
        // after a band step too, since windowed corrections land on the live offset
        // and move with a glide. Without it, rows just mounted above the screen by
        // growth sent the follow to the tail at once, and a quiet chat grows its band
        // just when the keyboard comes up or a message is sent: a jump of the
        // keyboard's height, or of the message's.
        let useInstant = forceInstant || pendingForceInstantFollow || isHoldingEntryAtEnd
            || (!smoothFollow && CACurrentMediaTime() - windowLastGrowthPublication < 0.6)
        if sv.isTracking || sv.isDragging {
            stopFollowAnimation()
            if sv.isDecelerating {
                pendingFollowAfterDeceleration = true
                pendingForceInstantFollow = useInstant
                scheduleWaitForDecelerationEnd()
            }
            return
        }
        if sv.isDecelerating {
            stopFollowAnimation()
            pendingFollowAfterDeceleration = true
            pendingForceInstantFollow = useInstant
            scheduleWaitForDecelerationEnd()
            return
        }
        #if DEBUG
        let instantReason = forceInstant ? "forced" : pendingForceInstantFollow ? "forcedEarlier"
            : isHoldingEntryAtEnd ? "entry" : useInstant ? "bandChange" : "-"
        #endif
        pendingForceInstantFollow = false
        let target = maxOffsetY(for: sv)
        let gap = target - sv.contentOffset.y
        if abs(gap) <= 1.0 {
            stopFollowAnimation()
            if abs(gap) > 0.1 {
                writeContentOffsetY(target, in: sv)
            }
            return
        }
        // The end came up: the keyboard going down (a tapped Send lowers it) or the
        // composer shrinking. The glide brings the chat down with them; set at once,
        // it dropped the keyboard's height in one frame while the keyboard was still
        // sliding down, the jump in every send. Far past the end, it goes at once.
        if gap < 0, !smoothFollow || -gap > sv.bounds.height * 1.25 {
            stopFollowAnimation()
            #if DEBUG
            Self.noteInstantFollow("shrank", points: gap)
            #endif
            writeContentOffsetY(target, in: sv)
            return
        }
        let recentlyShown = Date().timeIntervalSince(shownAt) < 0.6
        if useInstant || recentlyShown || gap > sv.bounds.height * 1.25 {
            stopFollowAnimation()
            #if DEBUG
            Self.noteInstantFollow(useInstant ? instantReason : recentlyShown ? "shown" : "farBehind", points: gap)
            #endif
            writeContentOffsetY(target, in: sv)
            return
        }
        guard followDisplayLink == nil else { return }
        lastFollowFrameTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(stepFollowAnimation(_:)))
        // The follow runs for most of a streaming turn, and each frame moves
        // the content under the glass composer, so the render server blurs the
        // screen again. Sixty frames a second keeps the glide smooth (each step
        // is sized by the time since the last, so it is rate-independent) and
        // halves that on a 120 Hz display; it may still rise to the display's
        // rate. Independent of the working-animation limit.
        // Settings > Debug > Native Chat Performance > Follow at 60 fps; off,
        // the link asks for nothing and runs at the display's rate, as before.
        if NativeChatPerformance.isEnabled(.followRate) || PerfSwitch.followFramesPerSecond != nil {
            let followRate = PerfSwitch.followFramesPerSecond ?? 60
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, followRate), maximum: 120, preferred: followRate)
        }
        link.add(to: .main, forMode: .common)
        followDisplayLink = link
        #endif
    }

    func areMarkerFramesCoherent(frames: [String: CGRect], allFrames: [String: CGRect]) -> Bool {
        guard windowEnabled, let publication = windowPublication, publication.snapshot.enabled else {
            return true
        }
        guard let section = allFrames["__rows"], section.width > 0 else {
            return false
        }
        var ordered: [(id: String, frame: CGRect)] = []
        ordered.reserveCapacity(publication.snapshot.rows.count)
        for row in publication.snapshot.rows {
            guard let frame = frames[row.id] else { continue }
            if frame.width > section.width + 1.0 {
                return false
            }
            if case .thinking = row {
                // Folded thinking lozenges can be narrower than the section width.
            } else if abs(frame.width - section.width) > 1.0 {
                return false
            }
            ordered.append((row.id, frame))
        }
        guard let first = ordered.first, let last = ordered.last else {
            let expectedHeight = publication.snapshot.top + publication.snapshot.bottom
            return abs((section.minY + expectedHeight) - section.maxY) < 1.5
        }
        let expectedFirstMinY = section.minY + publication.snapshot.top
        guard abs(first.frame.minY - expectedFirstMinY) < 1.0 else {
            return false
        }
        for index in 1..<ordered.count {
            let expectedMinY = ordered[index - 1].frame.maxY + 10
            guard abs(ordered[index].frame.minY - expectedMinY) < 1.0 else {
                return false
            }
        }
        let expectedMaxY = last.frame.maxY + publication.snapshot.bottom
        guard abs(expectedMaxY - section.maxY) < 1.5 else {
            return false
        }
        return true
    }

    #if os(iOS)
    func registerRowMarker(_ view: UIView, for id: String) {
        rowMarkers[id] = WeakMarker(value: view)
    }

    func unregisterRowMarker(_ view: UIView, for id: String) {
        if rowMarkers[id]?.value === view {
            rowMarkers.removeValue(forKey: id)
        }
    }

    func collectMarkerRowFrames() -> [String: CGRect] {
        guard let anchor = vstackAnchorView, anchor.window != nil else { return [:] }
        var result: [String: CGRect] = [:]
        if windowEnabled, let publication = windowPublication, publication.snapshot.enabled {
            result.reserveCapacity(publication.snapshot.rows.count)
            for row in publication.snapshot.rows {
                guard let marker = rowMarkers[row.id]?.value,
                      marker.window != nil,
                      !marker.isHidden,
                      marker.bounds.width > 0,
                      marker.bounds.height > 0 else { continue }
                result[row.id] = marker.convert(marker.bounds, to: anchor)
            }
        } else {
            result.reserveCapacity(rowMarkers.count)
            for (id, weakMarker) in rowMarkers {
                guard let marker = weakMarker.value,
                      marker.window != nil,
                      !marker.isHidden,
                      marker.bounds.width > 0,
                      marker.bounds.height > 0 else { continue }
                result[id] = marker.convert(marker.bounds, to: anchor)
            }
        }
        return result
    }

    private func hasMarkerFrameDelta(_ markerFrames: [String: CGRect]) -> Bool {
        guard markerFrames.count == rowFrames.count else { return true }
        for (id, frame) in markerFrames {
            guard let old = rowFrames[id] else { return true }
            if abs(frame.minY - old.minY) > 0.1
                || abs(frame.height - old.height) > 0.1
                || abs(frame.width - old.width) > 0.1 {
                return true
            }
        }
        return false
    }

    private func recordConfirmedMissingMarkers(_ frames: [String: CGRect]) {
        guard windowEnabled, let publication = windowPublication, publication.snapshot.enabled else { return }
        let serial = publication.snapshot.serial
        if windowMissingSerial != serial {
            windowMissingSerial = serial
            windowMissingPasses = [:]
            windowConfirmedMissing = []
        }
        for row in publication.snapshot.rows {
            if frames[row.id] != nil {
                windowMissingPasses[row.id] = 0
                windowConfirmedMissing.removeAll { $0.id == row.id }
            } else if let descriptor = windowPublishedDescriptors[row.id] {
                let key = windowModel.key(for: descriptor)
                if !windowConfirmedMissing.contains(key) {
                    windowConfirmedMissing.append(key)
                }
            }
        }
    }

    private func scheduleMarkerDataDeltaCheck() {
        guard useMarkerFrames, !markerDeltaCheckScheduled else { return }
        markerDeltaCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markerDeltaCheckScheduled = false
            guard self.useMarkerFrames,
                  self.pendingGeometry == nil,
                  !self.lastContainerFrames.isEmpty else { return }
            let markerFrames = self.collectMarkerRowFrames()
            guard self.areMarkerFramesCoherent(frames: markerFrames, allFrames: self.lastContainerFrames) else {
                return
            }
            if self.hasMarkerFrameDelta(markerFrames) {
                self.reconcileFrames(self.lastContainerFrames)
            } else {
                self.recordConfirmedMissingMarkers(markerFrames)
                let merged = self.lastContainerFrames.merging(markerFrames) { _, new in new }
                self.scheduleWindowMeasurements(merged)
            }
        }
    }

    func notifyMarkerLayoutChanged() {
        if pendingGeometry != nil {
            applyPendingGeometry()
        } else if useMarkerFrames && !lastContainerFrames.isEmpty {
            scheduleMarkerDataDeltaCheck()
        }
    }

    private func maxOffsetY(for sv: UIScrollView) -> CGFloat {
        max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
    }

    private func distanceFromBottom(in sv: UIScrollView) -> CGFloat {
        maxOffsetY(for: sv) - sv.contentOffset.y
    }

    private func writeContentOffsetY(_ y: CGFloat, in sv: UIScrollView) {
        guard windowEnabled || !sv.isDecelerating else {
            if isPinnedToBottom {
                pendingFollowAfterDeceleration = true
            }
            scheduleWaitForDecelerationEnd()
            return
        }
        isWritingOffset = true
        let point = CGPoint(x: sv.contentOffset.x, y: y)
        #if DEBUG
        if abs(sv.contentOffset.y - y) > 0.5 {
            entryTrace(String(format: "write %.0f->%.0f %@ anim=%.2f", sv.contentOffset.y, y,
                              Self.geometry(sv), UIView.inheritedAnimationDuration))
        }
        #endif
        let write = {
            if self.windowEnabled && (sv.isTracking || sv.isDragging || sv.isDecelerating) {
                // Unlike setContentOffset(_:animated:false), this preserves momentum.
                sv.contentOffset = point
            } else {
                sv.setContentOffset(point, animated: false)
            }
        }
        // Every write here places the chat at once; glides step on our own display link.
        // Made inside someone else's animation (a layout pass of the slide that brings a
        // chat in), UIKit would carry the change on that animation's curve. On Peter's Duo
        // a cold chat's rows, landing as its slide began, drifted about 70 pt down along
        // the slide's curve (8 November 2026, the nod): `[ENTRYNOD]` logs each write's
        // `anim`. `-perfOff unanimatedOffsets` (Debug) brings back the old write, for an A/B.
        if PerfSwitch.isOff("unanimatedOffsets") {
            write()
        } else {
            UIView.performWithoutAnimation(write)
        }
        lastObservedOffsetY = sv.contentOffset.y
        isWritingOffset = false
        scheduleWindowBandAfterOffsetWrite()
    }

    private func scheduleWindowBandAfterOffsetWrite() {
        guard windowEnabled else { return }
        windowOffsetPlanPending = true
        guard !windowOffsetPlanScheduled else { return }
        windowOffsetPlanScheduled = true
        // Offset writes also happen inside geometry reconciliation. Defer until
        // its baseline/target bookkeeping has finished, avoiding reentrant publication.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowOffsetPlanScheduled = false
            self.flushWindowBandAfterOffsetWrite()
        }
    }

    private func flushWindowBandAfterOffsetWrite() {
        guard windowEnabled, windowOffsetPlanPending else { return }
        guard pendingGeometry == nil && windowAnchorBaseline == nil && windowLayoutAnchor == nil else {
            beginWindowWait("offset")
            scheduleWaitForDecelerationEnd()
            return
        }
        windowOffsetPlanPending = false
        checkWindowBand()
    }

    private func scheduleWaitForDecelerationEnd() {
        guard decelerationWaitDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepWaitForDecelerationEnd(_:)))
        link.add(to: .main, forMode: .common)
        decelerationWaitDisplayLink = link
    }

    private func stopWaitForDecelerationEnd() {
        decelerationWaitDisplayLink?.invalidate()
        decelerationWaitDisplayLink = nil
    }

    #if DEBUG
    /// `-perfOn scrollPerf`: time a page of rows landing, at rest or not. Logs one
    /// `[SCROLLPERF] landing` line 0.6 s later.
    func probeLanding(from old: Int, to new: Int) {
        guard PerfSwitch.isOn("scrollPerf"), landingProbeLink == nil else { return }
        landingProbeRows = (old, new)
        landingProbeStart = CACurrentMediaTime()
        landingProbeLast = 0
        landingProbeFirstMs = -1
        landingProbeWorstMs = 0
        landingProbeLostMs = 0
        landingProbeFrames = 0
        let link = CADisplayLink(target: self, selector: #selector(stepLandingProbe(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        landingProbeLink = link
    }

    @objc private func stepLandingProbe(_ link: CADisplayLink) {
        let now = link.timestamp
        let frame = link.duration > 0 ? link.duration : 1.0 / 60.0
        if landingProbeFirstMs < 0 {
            landingProbeFirstMs = (CACurrentMediaTime() - landingProbeStart) * 1000
        } else if landingProbeLast > 0 {
            let gap = now - landingProbeLast
            landingProbeWorstMs = max(landingProbeWorstMs, gap * 1000)
            if gap > frame * 1.5 { landingProbeLostMs += (gap - frame) * 1000 }
        }
        landingProbeLast = now
        landingProbeFrames += 1
        guard CACurrentMediaTime() - landingProbeStart > 0.6 else { return }
        link.invalidate()
        landingProbeLink = nil
        bridge?.handleConsoleLog(String(format: "LOG: [SCROLLPERF] landing rows=%d->%d firstFrame=%.0fms worst=%.0fms lost=%.0fms frames=%d mounted=%d",
            landingProbeRows.from, landingProbeRows.to, landingProbeFirstMs, landingProbeWorstMs, landingProbeLostMs,
            landingProbeFrames, windowEnabled ? (windowPublication?.snapshot.rows.count ?? 0) : landingProbeRows.to))
    }

    private func startScrollPerfTrackingIfNeeded() {
        // A 120 Hz link on the main thread for every streaming change: phone
        // and Catalyst builds are DEBUG, so it ran for everyone. Measuring
        // asks for it (`-perfOn scrollPerf`).
        guard scrollPerfDisplayLink == nil, PerfSwitch.isOn("scrollPerf") else { return }
        perfLastFrameTimestamp = 0
        perfIdleFrames = 0
        perfSettlingFrames = 0
        let link = CADisplayLink(target: self, selector: #selector(stepScrollPerfDisplayLink(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        scrollPerfDisplayLink = link
    }

    private func stopScrollPerfTracking(log: Bool) {
        scrollPerfDisplayLink?.invalidate()
        scrollPerfDisplayLink = nil
        perfLastFrameTimestamp = 0
        perfIdleFrames = 0
        perfSettlingFrames = 0
        if log && (perfFrames > 0 || perfOffsetHandlerCalls > 0 || perfGeometryCalls > 0 || perfPrepGens > 0) {
            let rowsCount = store?.rows.count ?? rowFrames.count
            let line = String(
                format: "LOG: [SCROLLPERF] rows=%d frames=%d hitches=%d lost=%.0fms worst=%.0fms offsetHandler=%.2fms/%dcalls geometry=%.2fms/%dcalls prep=%.2fms/%dgens drift=%.1fpt/%dover/%dsampled mounted=%d band=%d..%d moves=%d corr=%d/%.1fpt wait=%dsize/%dmarker/%dserial/%dnoanchor nav=%d layoutKeyChange=%d stuck=%d root=%.1f/%.1f rowsPub=%d/%.2fms held=%d grow=%d",
                rowsCount,
                perfFrames,
                perfHitches,
                perfLostMs,
                perfWorstGapMs,
                perfOffsetHandlerMs,
                perfOffsetHandlerCalls,
                perfGeometryMs,
                perfGeometryCalls,
                perfPrepMs,
                perfPrepGens,
                perfDriftMax,
                perfDriftFrames,
                perfDriftSamples,
                windowEnabled ? (windowPublication?.snapshot.rows.count ?? 0) : rowsCount,
                windowPlan?.range.lowerBound ?? 0,
                windowPlan?.range.upperBound ?? rowsCount,
                windowMoves, windowCorrections, windowCorrectionPoints,
                windowWaitSize, windowWaitMarker, windowWaitSerial, windowMissingAnchor, windowNavigationCount, windowLayoutChanges, windowStuckCount, windowLastActualHeight, windowLastExpectedHeight,
                perfRowPublications, perfRowPublicationMs, perfTailHolds, windowGrowthSteps
            )
            bridge?.handleConsoleLog(line)
        }
        windowGrowthSteps = 0
        perfRowPublications = 0
        perfRowPublicationMs = 0
        perfTailHolds = 0
        windowStuckCount = 0
        windowNavigationCount = 0
        windowLayoutChanges = 0
        windowWaitSize = 0
        windowWaitMarker = 0
        windowWaitSerial = 0
        windowMissingAnchor = 0
        windowMoves = 0
        windowCorrections = 0
        windowCorrectionPoints = 0
        perfDriftRowId = nil
        perfCorrectionSinceFrame = 0
        perfDriftMax = 0
        perfDriftFrames = 0
        perfDriftSamples = 0
        perfFrames = 0
        perfHitches = 0
        perfLostMs = 0
        perfWorstGapMs = 0
        perfOffsetHandlerCalls = 0
        perfOffsetHandlerMs = 0
        perfGeometryCalls = 0
        perfGeometryMs = 0
        perfPrepGens = 0
        perfPrepMs = 0
    }

    @objc private func stepScrollPerfDisplayLink(_ link: CADisplayLink) {
        guard let sv = scrollView, sv.window != nil else {
            stopScrollPerfTracking(log: true)
            return
        }
        let isScrolling = sv.isTracking || sv.isDragging || sv.isDecelerating
        let isSettling = hasHeldRowPublication || awaitingGeometry || pendingGeometry != nil
        if isScrolling {
            perfSettlingFrames = 0
        } else if isSettling {
            perfSettlingFrames += 1
        }
        // About a second at 120 Hz: long enough to time a page landing's geometry.
        let isActive = isScrolling || (isSettling && perfSettlingFrames <= 120)
        sampleReadingRowDrift(in: sv)
        if isActive {
            perfIdleFrames = 0
            perfFrames += 1
            let now = link.timestamp
            if perfLastFrameTimestamp > 0 {
                let targetDuration = max(
                    0.004,
                    link.targetTimestamp > link.timestamp
                        ? (link.targetTimestamp - link.timestamp)
                        : (link.duration > 0 ? link.duration : (1.0 / 60.0))
                )
                let gap = now - perfLastFrameTimestamp
                if gap > targetDuration * 1.5 {
                    perfHitches += 1
                    perfLostMs += (gap - targetDuration) * 1000
                    perfWorstGapMs = max(perfWorstGapMs, gap * 1000)
                }
            }
            perfLastFrameTimestamp = now
        } else {
            perfIdleFrames += 1
            if perfIdleFrames >= 3 {
                stopScrollPerfTracking(log: true)
            }
        }
    }

    /// A layout change found the view at rest: take the reading row's position from the
    /// geometry last applied (what was on screen), so the first frame after the change
    /// is measured against it.
    private func seedReadingRowDriftBaseline() {
        guard perfDriftRowId == nil, !isPinnedToBottom, activeRestoration == nil,
              let sv = scrollView, let oldOrigin = geometryOrigin else { return }
        let offsetY = sv.contentOffset.y
        guard let row = firstRowIntersecting(thresholdMaxY: offsetY - oldOrigin + topInset + 4) else { return }
        perfDriftRowId = row.id
        perfDriftLastScreenY = oldOrigin + row.frame.minY - offsetY
        perfDriftLastOffsetY = offsetY
        perfCorrectionSinceFrame = 0
    }

    private func sampleReadingRowDrift(in sv: UIScrollView) {
        guard !isPinnedToBottom, activeRestoration == nil,
              let anchor = vstackAnchorView, anchor.window != nil else {
            perfDriftRowId = nil
            perfCorrectionSinceFrame = 0
            return
        }
        // Keep following the same row while it stays mounted: a jump big enough to
        // change which row is first visible must still be measured.
        let rowId: String
        let marker: UIView
        if let tracked = perfDriftRowId, let trackedMarker = rowMarkers[tracked]?.value, trackedMarker.window != nil {
            rowId = tracked
            marker = trackedMarker
        } else {
            let origin = anchor.convert(CGPoint.zero, to: sv).y
            guard let row = firstRowIntersecting(thresholdMaxY: sv.contentOffset.y - origin + topInset + 4),
                  let rowMarker = rowMarkers[row.id]?.value, rowMarker.window != nil else {
                perfDriftRowId = nil
                perfCorrectionSinceFrame = 0
                return
            }
            rowId = row.id
            marker = rowMarker
        }
        let offsetY = sv.contentOffset.y
        let screenY = marker.convert(CGPoint.zero, to: sv).y - offsetY
        if perfDriftRowId == rowId {
            let drift = abs((screenY - perfDriftLastScreenY) + (offsetY - perfDriftLastOffsetY) - perfCorrectionSinceFrame)
            perfDriftSamples += 1
            if drift > 0.5 {
                perfDriftFrames += 1
            }
            perfDriftMax = max(perfDriftMax, drift)
        }
        perfDriftRowId = rowId
        perfDriftLastScreenY = screenY
        perfDriftLastOffsetY = offsetY
        perfCorrectionSinceFrame = 0
    }
    #endif

    @objc private func stepWaitForDecelerationEnd(_ link: CADisplayLink) {
        guard let sv = scrollView else {
            stopWaitForDecelerationEnd()
            return
        }
        if recoverStuckWindowIfNeeded() { return }
        if windowEnabled && (pendingGeometry != nil || windowAnchorBaseline != nil || windowTargetID != nil) {
            applyPendingGeometry()
            // Do not consume the baseline or stop retrying because UIKit came to
            // rest: a final layout/marker batch may still be pending.
            if pendingGeometry != nil || windowAnchorBaseline != nil || windowTargetID != nil { return }
        }
        flushWindowBandAfterOffsetWrite()
        if windowEnabled && (windowAnchorBaseline != nil || pendingGeometry != nil) { return }
        if sv.isTracking || sv.isDragging || sv.isDecelerating {
            return
        }
        stopWaitForDecelerationEnd()
        if let snap = captureSnapshot() {
            store?.lastScrollSnapshot = snap
            sendSyncToWeb(snap)
        }
        // Rows held while the inset drops wait for it (`flushHeldRowsOnceKeyboardIsDown`):
        // this wait also runs for band layout passes, and with nothing decelerating it
        // published a sent message of several lines while the composer was still
        // collapsing, which hid its glide (Peter, 5 November 2026).
        if hasHeldRowPublication, !isKeyboardDropping {
            hasHeldRowPublication = false
            onFlushHeldRows?()
        }
        releaseHeldTailRowsIfOnScreen()
        if activeRestoration != nil {
            applyActiveRestorationStep()
            return
        }
        if pendingFollowAfterDeceleration || isPinnedToBottom {
            let forceInstant = pendingForceInstantFollow
            pendingFollowAfterDeceleration = false
            pendingForceInstantFollow = false
            requestFollow(forceInstant: forceInstant)
        }
        scheduleAutoLoadCheck(delay: 0.05)
        scheduleWindowGrowth()
    }

    @objc private func stepFollowAnimation(_ link: CADisplayLink) {
        guard isPinnedToBottom, !isRestoring, let sv = scrollView, !sv.isTracking, !sv.isDragging, !sv.isDecelerating else {
            if let sv = scrollView, sv.isDecelerating, isPinnedToBottom {
                pendingFollowAfterDeceleration = true
                scheduleWaitForDecelerationEnd()
            }
            stopFollowAnimation()
            return
        }
        let target = maxOffsetY(for: sv)
        let distance = target - sv.contentOffset.y
        let smooth = smoothFollow
        if smooth ? abs(distance) <= 1.0 : distance <= 1.0 {
            if abs(distance) > 0.1 {
                writeContentOffsetY(target, in: sv)
            }
            stopFollowAnimation()
            return
        }
        let now = link.timestamp
        guard smooth else {
            // Smooth follow off: the step it replaced.
            let elapsedMs = lastFollowFrameTimestamp > 0
                ? min(32.0, max(1.0, (now - lastFollowFrameTimestamp) * 1000.0))
                : 16.0
            lastFollowFrameTimestamp = now
            let step = max(1.0, distance * (1.0 - exp(-elapsedMs / 85.0)))
            writeContentOffsetY(min(target, sv.contentOffset.y + step), in: sv)
            return
        }
        let dt = lastFollowFrameTimestamp > 0 ? min(1.0 / 30.0, max(1.0 / 240.0, now - lastFollowFrameTimestamp)) : 1.0 / 60.0
        lastFollowFrameTimestamp = now
        // A critically damped spring toward the end, which keeps its speed as the end
        // moves: each new line draws the glide on rather than starting it again, and a
        // sent message eases up off the composer and settles. The step it replaces
        // (a fixed share of the distance each frame) set off at full speed every time
        // the end moved, so a streaming reply surged and stalled line by line (Peter,
        // 5 November 2026: "I'd like to make that scrolling buttery smooth"). An end
        // above the chat (the keyboard going down) is met on a stiffer spring, which
        // keeps the last message on the composer as the keyboard's fast curve lowers it.
        let omega = distance < 0 || now < followsKeyboardUntil ? Self.followSpringDown : Self.followSpring
        let away = -distance
        let decay = CGFloat(exp(-omega * dt))
        let nextAway = (away + (followVelocity + CGFloat(omega) * away) * CGFloat(dt)) * decay
        followVelocity = (followVelocity - CGFloat(omega) * (followVelocity + CGFloat(omega) * away) * CGFloat(dt)) * decay
        // Stop at the end rather than pass it, from either side.
        let arrived = abs(nextAway) <= 0.5 || (away < 0) != (nextAway < 0)
        writeContentOffsetY(arrived ? target : target + nextAway, in: sv)
        if arrived {
            stopFollowAnimation()
        }
    }

    /// How quickly the follow's spring closes on the end, in radians a second: a sent
    /// message settles in about a third of a second.
    private static let followSpring: Double = 16
    /// The same, coming down to an end above it: about 0.2 s, the keyboard's own.
    private static let followSpringDown: Double = 30

    func attach(scrollView sv: UIScrollView, anchorView: UIView) {
        self.vstackAnchorView = anchorView
        watchTheKeyboard()
        if self.scrollView !== sv {
            if let old = self.scrollView {
                old.removeGestureRecognizer(tapAwayRecognizer)
                old.panGestureRecognizer.removeTarget(self, action: #selector(handlePanGesture(_:)))
            }
            self.scrollView = sv
            self.lastObservedOffsetY = sv.contentOffset.y
            sv.addGestureRecognizer(tapAwayRecognizer)
            sv.panGestureRecognizer.addTarget(self, action: #selector(handlePanGesture(_:)))
            self.offsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.handleScrollOffsetChanged()
                }
            }
            self.contentSizeObservation = sv.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                let oldHeight = change.oldValue?.height ?? 0
                let newHeight = change.newValue?.height ?? 0
                MainActor.assumeIsolated {
                    self?.handleContentSizeChanged(oldHeight: oldHeight, newHeight: newHeight)
                }
            }
            self.boundsObservation = sv.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                MainActor.assumeIsolated {
                    #if DEBUG
                    self?.entryTrace(String(format: "bounds %.0fx%.0f->%.0fx%.0f anim=%.2f",
                                            change.oldValue?.width ?? 0, change.oldValue?.height ?? 0,
                                            change.newValue?.width ?? 0, change.newValue?.height ?? 0,
                                            UIView.inheritedAnimationDuration))
                    #endif
                    if change.oldValue?.width != change.newValue?.width { self?.captureWindowLayoutAnchor() }
                    self?.handleBoundsChanged()
                }
            }
        }
        if pendingGeometry != nil {
            applyPendingGeometry()
        } else if activeRestoration != nil {
            applyActiveRestorationStep()
        } else if isPinnedToBottom {
            requestFollow()
        }
    }

    func applyPendingGeometry() {
        #if DEBUG
        let perfStart = CACurrentMediaTime()
        defer {
            perfGeometryCalls += 1
            perfGeometryMs += (CACurrentMediaTime() - perfStart) * 1000.0
        }
        #endif
        guard let allFrames = pendingGeometry, let sv = scrollView else { return }
        if windowEnabled, let publication = windowPublication,
           allFrames["__window:\(publication.snapshot.serial)"] == nil {
            windowWaitSerial += 1
            windowWaitReason = "serial"
            if windowAnchorBaseline != nil { scheduleWaitForDecelerationEnd() }
            return
        }
        let expected = allFrames["__content"]?.height ?? sv.contentSize.height
        windowLastExpectedHeight = expected
        windowLastActualHeight = sv.contentSize.height
        // A HostingScrollView's contentSize and the SwiftUI root preference can
        // diverge after resize. Windowed commits use serial + real marker coherence
        // below; waiting on root-height equality can otherwise deadlock forever.
        guard windowEnabled || abs(sv.contentSize.height - expected) < 0.5 else {
            if windowEnabled {
                windowWaitSize += 1
                windowWaitReason = "size"
                if windowAnchorBaseline != nil { scheduleWaitForDecelerationEnd() }
            }
            return
        }
        let baseOffset = geometryBaseOffset ?? sv.contentOffset.y
        let frames: [String: CGRect]
        if useMarkerFrames {
            let liveMarkers = collectMarkerRowFrames()
            frames = !liveMarkers.isEmpty || vstackAnchorView?.window != nil
                ? liveMarkers
                : (pendingFilteredFrames ?? [:])
            pendingFilteredFrames = frames
            guard areMarkerFramesCoherent(frames: frames, allFrames: allFrames) else {
                if windowEnabled {
                    windowWaitMarker += 1
                    windowWaitReason = "marker"
                    if windowAnchorBaseline != nil { scheduleWaitForDecelerationEnd() }
                }
                return
            }
            recordConfirmedMissingMarkers(frames)
        } else if let cachedFrames = pendingFilteredFrames {
            frames = cachedFrames
        } else {
            let computed = allFrames.filter { (windowEnabled ? !$0.key.hasPrefix("__") : $0.key != "__content") }
            pendingFilteredFrames = computed
            frames = computed
        }
        let origin = vstackAnchorView.map { $0.window != nil ? $0.convert(CGPoint.zero, to: sv).y : 0 } ?? 0
        let oldOrigin = geometryOrigin ?? origin
        let candidates = pendingCandidates
        let choice: (key: String, value: CGRect)?
        if windowEnabled, let target = windowTargetID {
            if let frame = frames[target] {
                choice = (key: target, value: frame)
            } else if let index = windowIndexByID[target], !windowModel.hasSlot(at: index) {
                choice = nil // Confirmed no-slot navigation completes at the ledger boundary.
            } else {
                windowWaitMarker += 1
                return
            }
        } else if windowEnabled, let baseline = windowAnchorBaseline {
            guard let frame = frames[baseline.id] else {
                windowWaitMarker += 1
                windowWaitReason = "marker"
                scheduleWaitForDecelerationEnd()
                return
            }
            choice = (key: baseline.id, value: frame)
        } else if isPinnedToBottom {
            choice = candidates.last
        } else {
            let visibleContentTop = baseOffset - oldOrigin + topInset
            choice = Self.firstCandidateIntersecting(in: candidates, thresholdMaxY: visibleContentTop + 4)
                ?? Self.firstCandidateIntersecting(in: candidates, thresholdMaxY: baseOffset - oldOrigin)
        }
        if let choice, let current = frames[choice.key] {
            guard let marker = rowMarkers[choice.key]?.value, marker.window != nil else {
                if windowEnabled { windowWaitMarker += 1; windowWaitReason = "marker"; scheduleWaitForDecelerationEnd() }
                return
            }
            let mountedY = marker.convert(CGPoint.zero, to: sv).y
            let expectedY = origin + current.minY
            guard abs(mountedY - expectedY) < 0.5 else {
                if windowEnabled { windowWaitMarker += 1; windowWaitReason = "marker"; scheduleWaitForDecelerationEnd() }
                return
            }
        }
        if let target = activeRestoration,
           !target.following,
           let webRowId = target.webRowId,
           let nativeRowId = store?.resolveNativeRowId(forWebRowId: webRowId),
           let current = frames[nativeRowId] {
            guard let marker = rowMarkers[nativeRowId]?.value, marker.window != nil else { return }
            let mountedY = marker.convert(CGPoint.zero, to: sv).y
            let expectedY = origin + current.minY
            guard abs(mountedY - expectedY) < 0.5 else { return }
        }
        let measurementFrames = useMarkerFrames
            ? allFrames.merging(frames) { _, new in new }
            : allFrames
        pendingGeometry = nil
        pendingFilteredFrames = nil
        pendingCandidates = []
        geometryBaseOffset = nil
        rowFrames = frames
        if windowEnabled { windowCommittedSerial = windowPublication?.snapshot.serial ?? 0 }
        scheduleWindowMeasurements(measurementFrames)
        geometryOrigin = origin
        awaitingGeometry = false
        if windowEnabled, finishWindowNavigation(in: sv, origin: origin, frames: frames) { return }
        if let target = activeRestoration,
           !target.following,
           let webRowId = target.webRowId {
            if (sv.isTracking || sv.isDragging) && !sv.isDecelerating {
                endRestoration()
            } else if sv.isDecelerating {
                scheduleWaitForDecelerationEnd()
                return
            } else if let nativeRowId = store?.resolveNativeRowId(forWebRowId: webRowId),
                      let current = frames[nativeRowId] {
                let rowMinY = origin + current.minY
                let desiredOffsetY = rowMinY - target.offset
                let maxOff = maxOffsetY(for: sv)
                let minOffsetY = -sv.adjustedContentInset.top
                let nextOffsetY = min(maxOff, max(minOffsetY, desiredOffsetY))
                if abs(nextOffsetY - sv.contentOffset.y) > 0.1 {
                    writeContentOffsetY(nextOffsetY, in: sv)
                }
                endRestoration()
                if desiredOffsetY >= maxOff - 0.5 {
                    setFollowing(true)
                    requestFollow(forceInstant: true)
                }
                return
            } else if let store, !store.rows.isEmpty, store.resolveNativeRowId(forWebRowId: webRowId) == nil {
                endRestoration()
                setFollowing(true)
            }
        }
        if let choice, let current = frames[choice.key] {
            let baseline = windowEnabled ? windowAnchorBaseline : nil
            let delta: CGFloat
            if let layoutAnchor = windowLayoutAnchor, layoutAnchor.id == choice.key,
               !sv.isTracking && !sv.isDragging && !sv.isDecelerating {
                // A resize can also clamp/reset UIKit's offset. At rest restore
                // the saved screen position, not that incidental offset change.
                delta = origin + current.minY - sv.contentOffset.y - layoutAnchor.screenOffset
            } else {
                delta = baseline.map { (origin + current.minY) - $0.contentY }
                    ?? ((current.minY - choice.value.minY) + (origin - oldOrigin))
            }
            if abs(delta) > 0.1 {
                // All windowed geometry (including images/streaming without a
                // publication baseline) preserves motion since reconcileFrames.
                let correctionBase = windowEnabled ? sv.contentOffset.y : baseOffset
                // Following, the correction is not cut at the end: when the end came up in
                // the same pass (the keyboard going down as a Send lands), the cut dropped
                // the chat by the keyboard's height in one frame. Past the end, the
                // follow glides it down with the keyboard.
                let upperBound = smoothFollow && isPinnedToBottom && windowEnabled
                    ? CGFloat.greatestFiniteMagnitude : maxOffsetY(for: sv)
                let next = min(upperBound, max(-sv.adjustedContentInset.top, correctionBase + delta))
                #if DEBUG
                let beforeCorrection = sv.contentOffset.y
                #endif
                writeContentOffsetY(next, in: sv)
                if var layoutAnchor = windowLayoutAnchor {
                    layoutAnchor.offsetAtCapture = origin + current.minY - layoutAnchor.screenOffset
                    windowLayoutAnchor = layoutAnchor
                }
                #if DEBUG
                if abs(sv.contentOffset.y - beforeCorrection) > 0.1 {
                    windowCorrections += 1
                    windowCorrectionPoints += abs(sv.contentOffset.y - beforeCorrection)
                }
                perfCorrectionSinceFrame += sv.contentOffset.y - beforeCorrection
                if isPinnedToBottom { Self.noteInstantFollow("anchor", points: sv.contentOffset.y - beforeCorrection) }
                #endif
                if windowEnabled && !isPinnedToBottom && abs(next - (correctionBase + delta)) > 0.5 {
                    // contentSize may lag the coherent mounted markers during resize.
                    // Retain only the unapplied displacement until size catches up;
                    // the common 30-frame/0.5-second budget bounds this retry too.
                    let applied = sv.contentOffset.y - correctionBase
                    let oldPoint = baseline?.contentY ?? (origin + current.minY - delta)
                    windowAnchorBaseline = .init(id: choice.key, contentY: oldPoint + applied)
                    pendingGeometry = allFrames
                    pendingFilteredFrames = frames
                    pendingCandidates = []
                    awaitingGeometry = true
                    beginWindowWait("clamp")
                    return
                }
            }
        }
        if windowEnabled, windowAnchorBaseline != nil {
            windowAnchorBaseline = nil
            // Keep the same band/fillers through the physical resize. Once its
            // real marker is corrected, measure at the new width and resume planning.
            windowLayoutAnchor = nil
            windowWaitStarted = nil
            // The latest deferred data or measurements get a fresh actual baseline.
            DispatchQueue.main.async { [weak self] in self?.checkWindowBand() }
        }
        if windowEnabled && windowAnchorBaseline == nil && windowTargetID == nil { windowWaitStarted = nil }
        if isPinnedToBottom {
            requestFollow()
        }
    }

    private func handleContentSizeChanged(oldHeight: CGFloat, newHeight: CGFloat) {
        #if DEBUG
        if let sv = scrollView {
            entryTrace(String(format: "size %.0f->%.0f offset=%.0f %@ anim=%.2f", oldHeight, newHeight,
                              sv.contentOffset.y, Self.geometry(sv), UIView.inheritedAnimationDuration))
        }
        #endif
        // The inset is still moving with the keyboard (the content changes every frame of
        // its animation, and the keyboard coming up rides a spring longer than 0.45 s):
        // the window it opened lasts until the content has been still for a few frames,
        // shorter than the gap between a streaming reply's changes.
        if smoothFollow, CACurrentMediaTime() < followsKeyboardUntil {
            followsKeyboardUntil = max(followsKeyboardUntil, CACurrentMediaTime() + 0.05)
        }
        awaitingGeometry = true
        applyPendingGeometry()
        // Just entered: the end moved (rows measured, a catch-up). Follow it now.
        if isHoldingEntryAtEnd {
            requestFollow(forceInstant: true)
        } else if newHeight > oldHeight, followGlidesThroughLayout {
            // Following, the end moved down: glide toward it now, not once a layout
            // pass the band holds open settles.
            requestFollow(checkingBand: false)
        }
    }

    private func handleBoundsChanged() {
        if pendingGeometry != nil {
            applyPendingGeometry()
            return
        }
        if activeRestoration != nil {
            applyActiveRestorationStep()
            return
        }
        if windowEnabled { checkWindowBand() }
        if isPinnedToBottom {
            requestFollow()
        }
    }

    @objc private func handlePanGesture(_ pan: UIPanGestureRecognizer) {
        guard let sv = scrollView else { return }
        switch pan.state {
        case .began, .changed:
            if pan.state == .began && windowTargetID != nil && !windowTargetIsRestoration {
                windowTargetID = nil
                windowNavigationCompletion = nil
            }
            if pan.state == .began {
                windowGrowthStepsThisRest = 0
                windowGrowthWaits = 0
            }
            // A touch takes the chat over from the entry's hold at its end.
            entryPinUntil = 0
            #if DEBUG
            startScrollPerfTrackingIfNeeded()
            #endif
            endRestoration()
            stopFollowAnimation()
            if hasHeldRowPublication && !sv.isDecelerating {
                hasHeldRowPublication = false
                onFlushHeldRows?()
            }
            let velocityY = pan.velocity(in: sv).y
            let dist = distanceFromBottom(in: sv)
            if velocityY > 25 && dist > 8 {
                setFollowing(false)
            } else if velocityY < -25 && dist <= 48 && (!windowEnabled || windowLayoutAnchor == nil) {
                setFollowing(true)
            }
        case .ended, .cancelled, .failed:
            // A finger lifting while it moves toward older rows is a flick away
            // from the tail, however little the drag itself covered: a quick
            // flick from rest leaves most of its travel to the coast, and the
            // pan's start threshold takes part of the rest. Pinning it because
            // the drag ended within 32 pt glided it back to the bottom once the
            // coast stopped, which reads as an ignored flick (26 Oct 2026).
            let releaseVelocityY = pan.state == .ended ? pan.velocity(in: sv).y : 0
            if releaseVelocityY > 25 {
                setFollowing(false)
            } else if distanceFromBottom(in: sv) <= 32 && (!windowEnabled || windowLayoutAnchor == nil) {
                setFollowing(true)
            }
            if isPinnedToBottom {
                requestFollow()
            } else if sv.isDecelerating {
                scheduleWaitForDecelerationEnd()
            } else {
                if let snap = captureSnapshot() {
                    store?.lastScrollSnapshot = snap
                    sendSyncToWeb(snap)
                }
                releaseHeldTailRowsIfOnScreen()
                scheduleAutoLoadCheck(delay: 0.05)
                scheduleWindowGrowth()
            }
        default:
            break
        }
    }

    @objc private func handleScrollViewTapped() {
        scrollView?.window?.endEditing(true)
    }
    #endif

    func reconcileFrames(_ allFrames: [String: CGRect]) {
        #if os(iOS)
        #if DEBUG
        if !isRestoring && activeRestoration == nil && Date().timeIntervalSince(shownAt) > 0.6 {
            startScrollPerfTrackingIfNeeded()
            seedReadingRowDriftBaseline()
        }
        let prepStart = CACurrentMediaTime()
        #endif
        if useMarkerFrames {
            let containerOnly = allFrames.filter { $0.key.hasPrefix("__") }
            if !containerOnly.isEmpty {
                lastContainerFrames = containerOnly
            }
            if windowEnabled, let publication = windowPublication,
               allFrames["__window:\(publication.snapshot.serial)"] != nil,
               let section = allFrames["__rows"] {
                let scale = scrollView?.window?.screen.scale ?? 2
                let width = (section.width * scale).rounded() / scale
                let targetLayout = NativeChatWindowModel.LayoutKey(width: width, scale: scale, textMetrics: windowTextMetrics)
                if targetLayout != windowModel.layout {
                    if windowLayoutTarget != targetLayout { windowLayoutChanges += 1 }
                    captureWindowLayoutAnchor()
                    windowLayoutTarget = targetLayout
                }
            }
            if pendingGeometry == nil {
                geometryBaseOffset = scrollView?.contentOffset.y
            }
            let markerFrames = collectMarkerRowFrames()
            let explicitRowFrames = allFrames.filter { (windowEnabled ? !$0.key.hasPrefix("__") : $0.key != "__content") }
            let filtered = !markerFrames.isEmpty || vstackAnchorView?.window != nil
                ? markerFrames
                : explicitRowFrames
            pendingGeometry = containerOnly.isEmpty ? allFrames : containerOnly.merging(filtered) { _, new in new }
            pendingFilteredFrames = filtered
            if windowEnabled, let publication = windowPublication, publication.snapshot.enabled {
                let mountedIDs = Set(publication.snapshot.rows.map(\.id))
                pendingCandidates = rowFrames
                    .filter { mountedIDs.contains($0.key) }
                    .sorted { $0.value.minY < $1.value.minY }
            } else {
                pendingCandidates = rowFrames
                    .filter { filtered[$0.key] != nil }
                    .sorted { $0.value.minY < $1.value.minY }
            }
            awaitingGeometry = true
            if windowEnabled { beginWindowWait("geometry") }
            #if DEBUG
            perfPrepGens += 1
            perfPrepMs += (CACurrentMediaTime() - prepStart) * 1000.0
            #endif
            applyPendingGeometry()
            return
        }
        if windowEnabled, let publication = windowPublication,
           allFrames["__window:\(publication.snapshot.serial)"] != nil {
            let serial = publication.snapshot.serial
            if windowMissingSerial != serial {
                windowMissingSerial = serial
                windowMissingPasses = [:]
                windowConfirmedMissing = []
            }
            for row in publication.snapshot.rows {
                if allFrames[row.id] != nil {
                    windowMissingPasses[row.id] = 0
                    windowConfirmedMissing.removeAll { $0.id == row.id }
                }
                else {
                    let count = (windowMissingPasses[row.id] ?? 0) + 1
                    windowMissingPasses[row.id] = count
                    if count == 2, let descriptor = windowPublishedDescriptors[row.id] {
                        windowConfirmedMissing.append(windowModel.key(for: descriptor))
                    }
                }
            }
            if let section = allFrames["__rows"] {
                let scale = scrollView?.window?.screen.scale ?? 2
                let width = (section.width * scale).rounded() / scale
                let targetLayout = NativeChatWindowModel.LayoutKey(width: width, scale: scale, textMetrics: windowTextMetrics)
                if targetLayout != windowModel.layout {
                    if windowLayoutTarget != targetLayout { windowLayoutChanges += 1 }
                    captureWindowLayoutAnchor()
                    windowLayoutTarget = targetLayout
                }
            }
            if !windowConfirmedMissing.isEmpty { scheduleWindowMeasurements(allFrames) }
        }
        if pendingGeometry == nil {
            geometryBaseOffset = scrollView?.contentOffset.y
        }
        var filtered = allFrames
        filtered = filtered.filter { (windowEnabled ? !$0.key.hasPrefix("__") : $0.key != "__content") }
        pendingGeometry = allFrames
        pendingFilteredFrames = filtered
        pendingCandidates = rowFrames
            .filter { filtered[$0.key] != nil }
            .sorted { $0.value.minY < $1.value.minY }
        awaitingGeometry = true
        if windowEnabled { beginWindowWait("geometry") }
        #if DEBUG
        perfPrepGens += 1
        perfPrepMs += (CACurrentMediaTime() - prepStart) * 1000.0
        #endif
        applyPendingGeometry()
        #else
        rowFrames = allFrames.filter { (windowEnabled ? !$0.key.hasPrefix("__") : $0.key != "__content") }
        if activeRestoration != nil {
            applyActiveRestorationStep()
        }
        #endif
    }

    func startRestoration(_ position: NativeChatScrollPosition, proxy: ScrollViewProxy) {
        restorationGeneration += 1
        if position.following || position.webRowId == nil {
            endRestoration()
            setFollowing(true)
            store?.lastScrollSnapshot = position
            #if !os(iOS)
            proxy.scrollTo("native-chat-bottom-anchor", anchor: .bottom)
            #endif
            requestFollow(forceInstant: true)
            DispatchQueue.main.async { [weak self] in
                #if !os(iOS)
                proxy.scrollTo("native-chat-bottom-anchor", anchor: .bottom)
                #endif
                self?.requestFollow(forceInstant: true)
            }
            return
        }

        stopFollowAnimation()
        activeRestoration = position
        isRestoring = true
        setFollowing(false)
        store?.lastScrollSnapshot = position
        #if os(iOS)
        if windowEnabled, let webID = position.webRowId,
           let id = store?.resolveNativeRowId(forWebRowId: webID), !isWindowTargetMounted(id) {
            stageWindowTarget(id: id, restoration: true)
        }
        #endif

        #if !os(iOS)
        if let webRowId = position.webRowId,
           let nativeRowId = store?.resolveNativeRowId(forWebRowId: webRowId) {
            proxy.scrollTo(nativeRowId, anchor: .top)
        }
        #endif
        applyActiveRestorationStep()
    }

    func applyActiveRestorationStep() {
        guard let target = activeRestoration,
              !target.following,
              let webRowId = target.webRowId,
              let store else { return }
        #if os(iOS)
        if awaitingGeometry { return }
        guard let nativeRowId = store.resolveNativeRowId(forWebRowId: webRowId) else {
            if !store.rows.isEmpty {
                endRestoration()
                setFollowing(true)
                requestFollow(forceInstant: true)
            }
            return
        }
        if windowEnabled, !isWindowTargetMounted(nativeRowId) {
            if windowTargetID != nativeRowId { stageWindowTarget(id: nativeRowId, restoration: true) }
            return
        }
        guard let rowFrame = rowFrames[nativeRowId],
              let sv = scrollView,
              let anchor = vstackAnchorView,
              anchor.window != nil,
              sv.bounds.height > 0 else { return }
        if sv.isTracking || sv.isDragging {
            if sv.isDecelerating {
                scheduleWaitForDecelerationEnd()
                return
            }
            endRestoration()
            return
        }
        if sv.isDecelerating {
            scheduleWaitForDecelerationEnd()
            return
        }
        let origin = anchor.convert(CGPoint.zero, to: sv).y
        guard let marker = rowMarkers[nativeRowId]?.value,
              marker.window != nil,
              abs(marker.convert(CGPoint.zero, to: sv).y - (origin + rowFrame.minY)) < 0.5 else {
            return
        }
        let rowMinY = origin + rowFrame.minY
        let desiredOffsetY = rowMinY - target.offset
        let maxOff = maxOffsetY(for: sv)
        let minOffsetY = -sv.adjustedContentInset.top
        let nextOffsetY = min(maxOff, max(minOffsetY, desiredOffsetY))
        if abs(nextOffsetY - sv.contentOffset.y) > 0.1 {
            writeContentOffsetY(nextOffsetY, in: sv)
        }
        endRestoration()
        if desiredOffsetY >= maxOff - 0.5 {
            setFollowing(true)
            requestFollow(forceInstant: true)
        }
        #else
        endRestoration()
        #endif
    }

    private func handleScrollOffsetChanged() {
        guard !isRestoring else { return }
        #if os(iOS)
        guard !isWritingOffset, let sv = scrollView, sv.bounds.height > 0 else { return }
        #if DEBUG
        if sv.isTracking || sv.isDragging || sv.isDecelerating {
            startScrollPerfTrackingIfNeeded()
            listFrames.begin(sv)
        }
        // Moved by someone else: UIKit clamping it, SwiftUI, or a finger.
        if abs(sv.contentOffset.y - lastObservedOffsetY) > 0.5 {
            entryTrace(String(format: "moved %.0f->%.0f (not ours) %@ anim=%.2f", lastObservedOffsetY,
                              sv.contentOffset.y, Self.geometry(sv), UIView.inheritedAnimationDuration))
        }
        let perfStart = CACurrentMediaTime()
        defer {
            perfOffsetHandlerCalls += 1
            perfOffsetHandlerMs += (CACurrentMediaTime() - perfStart) * 1000.0
        }
        #endif
        if var layoutAnchor = windowLayoutAnchor, sv.isTracking || sv.isDragging || sv.isDecelerating {
            let motion = sv.contentOffset.y - lastObservedOffsetY
            layoutAnchor.screenOffset -= motion
            layoutAnchor.offsetAtCapture += motion
            windowLayoutAnchor = layoutAnchor
        }
        let dist = distanceFromBottom(in: sv)
        let allowEdgeFollow = !windowEnabled || windowLayoutAnchor == nil
        // A coast pins on its way to the tail, or at it (a bounce back from
        // past the bottom). One leaving it, a flick toward older rows from the
        // bottom, is still within 24 pt in its first frames.
        let coastPins = !isPinnedToBottom && allowEdgeFollow && dist <= 24
            && (dist <= 1 || sv.contentOffset.y > lastObservedOffsetY)
        if sv.isTracking || sv.isDragging {
            if sv.isDecelerating {
                if coastPins {
                    setFollowing(true)
                    pendingFollowAfterDeceleration = true
                    scheduleWaitForDecelerationEnd()
                }
            } else if sv.contentOffset.y < lastObservedOffsetY - 2 && dist > 16 {
                setFollowing(false)
            } else if allowEdgeFollow && dist <= 24 {
                setFollowing(true)
            }
        } else if sv.isDecelerating {
            if coastPins {
                setFollowing(true)
                pendingFollowAfterDeceleration = true
                scheduleWaitForDecelerationEnd()
            }
        } else if pendingFollowAfterDeceleration {
            let forceInstant = pendingForceInstantFollow
            pendingFollowAfterDeceleration = false
            pendingForceInstantFollow = false
            requestFollow(forceInstant: forceInstant)
        }
        let travel = sv.contentOffset.y - lastObservedOffsetY
        if abs(travel) > 0.5 {
            windowTravel = travel < 0 ? .up : .down
            windowLastOffsetMotion = CACurrentMediaTime()
        }
        lastObservedOffsetY = sv.contentOffset.y
        if pendingGeometry == nil { checkWindowBand() }
        scheduleWebSync()
        // Pull-to-refresh / overscroll past top forces an immediate loadMore request.
        let pullThreshold = -sv.adjustedContentInset.top - 36
        if sv.isDragging && sv.contentOffset.y < pullThreshold {
            if !wasPullingPastTop {
                wasPullingPastTop = true
                onNearTopLoadMore?(true)
            }
        } else if sv.contentOffset.y >= -sv.adjustedContentInset.top - 8 {
            wasPullingPastTop = false
        }
        // Auto-load older messages when within 2 screens of the top (mirrors olderHistoryAutoLoad.ts).
        let autoLoadZone = max(240, sv.bounds.height * 2)
        if sv.contentOffset.y <= autoLoadZone {
            if autoLoadWorkItem == nil || (!sv.isDragging && !sv.isTracking) {
                scheduleAutoLoadCheck(delay: 0.14)
            }
        } else if autoLoadWorkItem != nil {
            autoLoadWorkItem?.cancel()
            autoLoadWorkItem = nil
        }
        #endif
    }

    func scheduleAutoLoadCheck(delay: TimeInterval = 0.14) {
        #if os(iOS)
        autoLoadWorkItem?.cancel()
        autoLoadWorkItem = nil
        guard let sv = scrollView, sv.bounds.height > 0, !isRestoring, activeRestoration == nil else { return }
        let autoLoadZone = max(240, sv.bounds.height * 2)
        guard sv.contentOffset.y <= autoLoadZone else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoLoadWorkItem = nil
            self.evaluateNearTopAutoLoad()
        }
        autoLoadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        #endif
    }

    #if os(iOS)
    private func evaluateNearTopAutoLoad() {
        guard let sv = scrollView, sv.bounds.height > 0, !isRestoring, activeRestoration == nil else { return }
        let autoLoadZone = max(240, sv.bounds.height * 2)
        guard sv.contentOffset.y <= autoLoadZone else { return }
        if sv.isDragging || sv.isTracking || sv.isDecelerating {
            scheduleAutoLoadCheck(delay: 0.14)
            return
        }
        guard let store, !store.rows.isEmpty, store.rows.count < 600 else { return }
        if store.truncatedCount > 0 {
            ChatSlideProbe.mark("nativeChat.autoLoad truncated=\(store.truncatedCount)")
            onNearTopLoadMore?(false)
        } else if !isPinnedToBottom {
            let chatId = store.currentChatId ?? bridge?.currentSourceChatId ?? ""
            if !chatId.isEmpty, probedUntruncatedChatId != chatId {
                probedUntruncatedChatId = chatId
                onNearTopLoadMore?(true)
            }
        }
    }
    #endif

    private func rebuildOrderedRowFrames() {
        guard !rowFrames.isEmpty else {
            orderedRowFrames = []
            return
        }
        if let store, !store.rows.isEmpty {
            var ordered: [(id: String, frame: CGRect)] = []
            ordered.reserveCapacity(store.rows.count)
            var previousMaxY: CGFloat = -.infinity
            var isMonotonic = true
            for row in store.rows {
                guard let frame = rowFrames[row.id] else { continue }
                if frame.maxY < previousMaxY {
                    isMonotonic = false
                }
                previousMaxY = frame.maxY
                ordered.append((id: row.id, frame: frame))
            }
            if !isMonotonic {
                ordered.sort { $0.frame.maxY < $1.frame.maxY }
            }
            orderedRowFrames = ordered
        } else {
            orderedRowFrames = rowFrames
                .map { (id: $0.key, frame: $0.value) }
                .sorted { $0.frame.maxY < $1.frame.maxY }
        }
    }

    static func firstCandidateIntersecting(
        in candidates: [(key: String, value: CGRect)],
        thresholdMaxY: CGFloat
    ) -> (key: String, value: CGRect)? {
        guard !candidates.isEmpty else { return nil }
        var low = 0
        var high = candidates.count
        while low < high {
            let mid = (low + high) / 2
            if candidates[mid].value.maxY > thresholdMaxY {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low < candidates.count ? candidates[low] : nil
    }

    func firstRowIntersecting(thresholdMaxY: CGFloat, in store: NativeChatMessageStore? = nil) -> (id: String, frame: CGRect)? {
        let frames = orderedRowFrames
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].frame.maxY > thresholdMaxY {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let targetStore = store ?? self.store
        var idx = low
        while idx < frames.count {
            let candidate = frames[idx]
            if let targetStore {
                if targetStore.containsNativeRowId(candidate.id) {
                    return candidate
                }
            } else {
                return candidate
            }
            idx += 1
        }
        return nil
    }

    func captureSnapshot(forceReadingAnchor: Bool = false) -> NativeChatScrollPosition? {
        guard let store else { return nil }
        let chatId = store.currentChatId ?? bridge?.currentSourceChatId ?? ""
        guard !chatId.isEmpty, !store.rows.isEmpty else { return nil }
        if !forceReadingAnchor, let pending = activeRestoration, pending.chatId == chatId {
            return pending
        }
        if !forceReadingAnchor && isPinnedToBottom {
            return NativeChatScrollPosition(chatId: chatId, webRowId: nil, offset: 0, following: true)
        }
        #if os(iOS)
        guard let sv = scrollView, let anchor = vstackAnchorView, anchor.window != nil else {
            return store.lastScrollSnapshot
        }
        if !forceReadingAnchor && distanceFromBottom(in: sv) <= 24 {
            return NativeChatScrollPosition(chatId: chatId, webRowId: nil, offset: 0, following: true)
        }
        if orderedRowFrames.isEmpty && !rowFrames.isEmpty {
            rebuildOrderedRowFrames()
        }
        let origin = anchor.convert(CGPoint.zero, to: sv).y
        let baseThreshold = sv.contentOffset.y - origin
        let visibleTop = topInset
        let match = firstRowIntersecting(thresholdMaxY: baseThreshold + visibleTop + 4, in: store)
            ?? firstRowIntersecting(thresholdMaxY: baseThreshold, in: store)
        guard let chosen = match else {
            return store.lastScrollSnapshot
        }
        let chosenScrollerMinY = origin + chosen.frame.minY - sv.contentOffset.y
        let webRowId = store.resolveWebRowId(forNativeRowId: chosen.id)
        return NativeChatScrollPosition(chatId: chatId, webRowId: webRowId, offset: chosenScrollerMinY, following: false)
        #else
        return store.lastScrollSnapshot
        #endif
    }

    private func scheduleWebSync() {
        syncWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let snap = self.captureSnapshot() else { return }
            self.store?.lastScrollSnapshot = snap
            self.sendSyncToWeb(snap)
        }
        syncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func sendSyncToWeb(_ snapshot: NativeChatScrollPosition) {
        bridge?.send(Self.syncPayload(snapshot))
    }

    /// The page's message for where the reader is.
    static func syncPayload(_ snapshot: NativeChatScrollPosition) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "agent-framework:nativeChat:action",
            "op": "syncScrollPosition",
            "chatId": snapshot.chatId,
            "offset": Double(snapshot.offset),
            "following": snapshot.following,
        ]
        if let rowId = snapshot.webRowId {
            payload["rowId"] = rowId
        }
        return payload
    }
}

#if os(iOS)
@available(iOS 16.0, *)
extension NativeChatScrollCoordinator: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            var current = touch.view
            while let view = current {
                if view is UITextField || view is UITextView || view is WKWebView {
                    return false
                }
                current = view.superview
            }
            return true
        }
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif

@available(iOS 16.0, macOS 14.0, *)
private struct NativeScrollViewIntrospector: View {
    let coordinator: NativeChatScrollCoordinator

    var body: some View {
        #if os(iOS)
        NativeScrollViewIntrospectorRepresentable(coordinator: coordinator)
            .allowsHitTesting(false)
        #else
        Color.clear
        #endif
    }
}

#if os(iOS)
@available(iOS 16.0, *)
private struct NativeScrollViewIntrospectorRepresentable: UIViewRepresentable {
    let coordinator: NativeChatScrollCoordinator

    final class ProbeView: UIView {
        weak var coordinator: NativeChatScrollCoordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfPossible()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfPossible()
        }

        func attachIfPossible() {
            guard window != nil, let coordinator else { return }
            var current: UIView? = superview
            while let view = current {
                if let sv = view as? UIScrollView {
                    coordinator.attach(scrollView: sv, anchorView: self)
                    return
                }
                current = view.superview
            }
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = coordinator
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.coordinator = coordinator
        uiView.attachIfPossible()
    }
}
#endif

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatRowMarker: View {
    let id: String
    let coordinator: NativeChatScrollCoordinator

    var body: some View {
        #if os(iOS)
        NativeChatRowMarkerRepresentable(id: id, coordinator: coordinator)
            .allowsHitTesting(false)
        #else
        Color.clear
        #endif
    }
}

#if os(iOS)
@available(iOS 16.0, *)
private struct NativeChatRowMarkerRepresentable: UIViewRepresentable {
    let id: String
    let coordinator: NativeChatScrollCoordinator

    final class MarkerView: UIView {
        var rowId: String = ""
        weak var coordinator: NativeChatScrollCoordinator?

        override var frame: CGRect {
            didSet { coordinator?.notifyMarkerLayoutChanged() }
        }

        override var center: CGPoint {
            didSet { coordinator?.notifyMarkerLayoutChanged() }
        }

        override var bounds: CGRect {
            didSet { coordinator?.notifyMarkerLayoutChanged() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.registerRowMarker(self, for: rowId)
            coordinator?.notifyMarkerLayoutChanged()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.notifyMarkerLayoutChanged()
        }
    }

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.rowId = id
        view.coordinator = coordinator
        coordinator.registerRowMarker(view, for: id)
        return view
    }

    func updateUIView(_ uiView: MarkerView, context: Context) {
        if uiView.rowId != id {
            coordinator.unregisterRowMarker(uiView, for: uiView.rowId)
            uiView.rowId = id
        }
        uiView.coordinator = coordinator
        coordinator.registerRowMarker(uiView, for: id)
        coordinator.notifyMarkerLayoutChanged()
    }

    static func dismantleUIView(_ uiView: MarkerView, coordinator: ()) {
        uiView.coordinator?.unregisterRowMarker(uiView, for: uiView.rowId)
    }
}
#endif

@available(iOS 16.0, macOS 14.0, *)
private struct NativeAssistantImagesView: View {
    let attachments: [NativeChatImageAttachment]
    let onZoomImage: (NativeChatImageAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { img in
                Button {
                    onZoomImage(img)
                } label: {
                    NativeChatProportionalImage(attachment: img)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(img.name ?? "Attached image")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatProportionalImage: View {
    let attachment: NativeChatImageAttachment
    private let preloader = NativeChatImagePreloader.shared
    @State private var loadedRevision: Int = 0

    private static let maxDisplayWidth: CGFloat = 340
    private static let maxDisplayHeight: CGFloat = 420

    var body: some View {
        let _ = loadedRevision
        let key = preloader.cacheKey(for: attachment)
        imageContent
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.ripul(.separator), lineWidth: 1)
            )
            .onAppear {
                if preloader.cachedImage(for: attachment) != nil {
                    loadedRevision &+= 1
                }
            }
            .onReceive(preloader.keyLoaded) { loadedKey in
                if loadedKey == key {
                    loadedRevision &+= 1
                }
            }
    }

    private var reservedDimensions: CGSize? {
        if let w = attachment.width, let h = attachment.height, w > 0, h > 0 {
            return Self.fitSize(width: CGFloat(w), height: CGFloat(h))
        }
        if let known = preloader.knownSize(for: attachment), known.width > 0, known.height > 0 {
            return Self.fitSize(width: known.width, height: known.height)
        }
        if let img = preloader.cachedImage(for: attachment), img.size.width > 0, img.size.height > 0 {
            return Self.fitSize(width: img.size.width, height: img.size.height)
        }
        return nil
    }

    private static func fitSize(width: CGFloat, height: CGFloat) -> CGSize {
        let scale = min(1.0, min(maxDisplayWidth / width, maxDisplayHeight / height))
        return CGSize(width: round(width * scale), height: round(height * scale))
    }

    @ViewBuilder
    private var imageContent: some View {
        if let img = preloader.cachedImage(for: attachment) {
            let size = reservedDimensions ?? Self.fitSize(width: max(1, img.size.width), height: max(1, img.size.height))
            #if os(iOS)
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
            #elseif os(macOS)
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
            #endif
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        let size = reservedDimensions ?? CGSize(width: 193, height: 420)
        return ZStack {
            Color.ripul(.text).opacity(0.06)
            RenderServerSpinner(size: 20)
        }
        .frame(width: size.width, height: size.height)
    }
}

private func formatTimestamp(_ ms: Double) -> String {
    let date = Date(timeIntervalSince1970: ms / 1000)
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

import SwiftUI
@testable import RipulAgent

/// The session list's family layout with the real rows: a chat, the chats it
/// started, and the control that folds the quiet ones away.
struct SessionFamiliesHarness: View {
    @State private var store = SessionListStore()
    @State private var open: Set<String> = []
    @StoredDefault("ripulClosedSessionFamilies") private var closed: Set<String> = []
    /// Where a row was dropped: a chat's id to the id of the chat it was dropped on.
    @State private var placed: [String: String] = [:]
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    /// Chats that have just spoken, in the order they did: each moves to the top.
    @State private var spoke: [String] = []

    /// `--animation-demo`: the chats open in Ripul get a new tool every 0.75 s,
    /// about 80 a minute each (Peter's phone saw 43-83 on 18 October 2026), and
    /// unless `--no-bumps` the next of three chats speaks every 4 s and moves
    /// to the top. `--no-animations` turns the list's animations off, the
    /// control when measuring what they cost, and `--list-covered` draws the
    /// list as an iPhone does behind an open chat.
    private static let arguments = ProcessInfo.processInfo.arguments
    private static let demo = arguments.contains("--animation-demo")
    private static let openInRipul: Set<String> = demo ? ["tools", "thermals", "rows"] : []
    private static let speakers = ["claude-cli:thermals", "claude-cli:parser", "claude-cli:tools"]

    /// Every family starts open, unless `--keep-closed-families`. Once a
    /// launch, not in `init`: a view's `init` runs again whenever SwiftUI
    /// rebuilds it, and clearing the key there opened a family the moment it
    /// was closed (23 October 2026).
    private static let familiesStartOpen: Void = {
        if !ProcessInfo.processInfo.arguments.contains("--keep-closed-families") {
            UserDefaults.standard.removeObject(forKey: "ripulClosedSessionFamilies")
        }
    }()

    init() {
        Self.familiesStartOpen
        _closed = StoredDefault(wrappedValue: [], "ripulClosedSessionFamilies", store: .standard)
    }

    private static let now = Date()
    /// - Parameter running: Mid-turn on its Mac and not open on this device, as a chat an agent has just started is.
    private static func chat(_ title: String, minutesAgo: Double, model: String = "claude-opus-5-5", branch: String? = "main",
                             startedBy starter: (id: String, title: String)? = nil, id: String? = nil,
                             running: Bool = false) -> UnifiedSession {
        let key = id ?? title
        return UnifiedSession(
            id: "claude-cli:\(key)", title: title, lastUsed: now.addingTimeInterval(-minutesAgo * 60),
            gitBranch: branch, messageCount: 12, projectName: "ripul", provider: "claude-cli", providerLabel: "Claude Code",
            model: model, machineName: "Studio", machineId: "studio", matchKeys: ["claude-cli:\(key)", "cli_\(key)"],
            startedBy: starter.map { SessionStartedBy(agentId: "cli_\($0.id)", sessionId: "claude-cli:\($0.id)", title: $0.title) },
            runningOnHost: running,
            ripulSession: openInRipul.contains(key)
                ? ChatSession(id: "cli_\(key)", sourceChatId: "cli_\(key)", displayName: title, createdAt: now) : nil)
    }

    /// The fixture, or with `--many-sessions` fifteen copies of it, each older
    /// than the last: a list as long as a real one, for measuring scrolling.
    private static let sessions: [UnifiedSession] = ProcessInfo.processInfo.arguments.contains("--many-sessions")
        ? (0..<15).flatMap { fixture(copy: $0) }
        : fixture(copy: 0)

    private static func fixture(copy: Int) -> [UnifiedSession] {
        let n = copy == 0 ? "" : " \(copy)", k = copy == 0 ? "" : "-\(copy)", ago = Double(copy) * 120
        let design = (id: "design\(k)", title: "Design alignment\(n)")
        return [
            chat("Tool panel renders\(n)", minutesAgo: ago + 14, id: "tools\(k)"),
            chat("Design alignment\(n)", minutesAgo: ago + 95, id: "design\(k)"),
            chat("Theme: chat panels\(n)", minutesAgo: ago + 1, startedBy: design, id: "panels\(k)"),
            // Mid-turn, two steps under the head: the head has to say so when the family is put away.
            chat("Check the bubble colours for contrast\(n)", minutesAgo: ago + 3, model: "claude-haiku-4-5",
                 startedBy: (id: "panels\(k)", title: "Theme: chat panels\(n)"), running: true),
            chat("Theme: session rows\(n)", minutesAgo: ago + 4, startedBy: design, id: "rows\(k)"),
            // On a branch of its own, so it is the one started chat that says where it is.
            chat("Theme: tool sheets\(n)", minutesAgo: ago + 9, branch: "tool-sheets", startedBy: design),
            chat("Theme: settings screens\(n)", minutesAgo: ago + 16, startedBy: design),
            chat("Theme: plan review\(n)", minutesAgo: ago + 21, startedBy: design),
            chat("Theme: browser\(n)", minutesAgo: ago + 33, startedBy: design),
            chat("Thermals\(n)", minutesAgo: ago + 40, branch: "thermals", id: "thermals\(k)"),
            // Its starter is not in the list, so it says whose it is.
            chat("Port the parser to the new grammar\(n)", minutesAgo: ago + 55, model: "gpt-5-codex",
                 startedBy: (id: "gone\(k)", title: "Codex migration\(n)"), id: "parser\(k)"),
        ]
    }

    var body: some View {
        // The list's own reading of the store for what may not be folded away.
        let families = SessionFamilies.arrange(
            Self.sessions, open: open, closed: closed,
            recency: { session in
                spoke.lastIndex(of: session.id).map { Int.max / 2 + $0 } ?? Int(session.lastUsed.timeIntervalSince1970 / 30)
            },
            mustShow: { store.isWorkingOrAsking($0) },
            placedUnder: { placed[$0.id] })
        // Every chat, whatever is folded: what is under a chat does not depend on what is showing.
        let every = SessionFamilies.arrange(Self.sessions, folds: false, recency: { _ in 0 }, placedUnder: { placed[$0.id] })
        NavigationStack {
            GlassRichList(
                items: families.rowsWithFolds(families.visible), emptyState: nil, identifierPrefix: "SessionFamiliesHarness",
                isSelecting: isSelecting,
                selectedIds: selectedIds,
                onTap: { row in
                    if !selectedIds.isEmpty { selectedIds.removeAll() }
                    if let fold = families.fold(ofRow: row.id) { toggle(fold) }
                },
                onToggleSelect: { row in
                    guard families.fold(ofRow: row.id) == nil else { return }
                    if selectedIds.contains(row.id) {
                        selectedIds.remove(row.id)
                    } else {
                        if !isSelecting { isSelecting = true }
                        selectedIds.insert(row.id)
                    }
                },
                row: { session in
                    if let fold = SessionFamilies.foldDrawn(by: session) {
                        SessionFamilyFoldButton(fold: fold) { families.fold(ofRow: session.id).map(toggle) }
                    } else {
                        UnifiedSessionRow(
                            sessionStore: store, session: session,
                            hideProjectName: families.sharesFolder.contains(session.id),
                            hideBranch: families.sharesBranch.contains(session.id),
                            isSelectMode: isSelecting,
                            isSelected: selectedIds.contains(session.id),
                            familyDepth: families.depth[session.id] ?? 0,
                            startedChats: families.heads[session.id]?.started ?? 0,
                            startedChatsClosed: families.heads[session.id]?.isClosed ?? false,
                            startedChatsNeedLooking: families.heads[session.id]?.needsLooking ?? false,
                            startedChatsPutAway: families.heads[session.id]?.putAway ?? [],
                            onToggleStartedChats: {
                                if families.heads[session.id]?.isClosed == true {
                                    closed.subtract([session.id, session.metadataKey])
                                } else {
                                    closed.insert(session.id)
                                    closed.insert(session.metadataKey)
                                }
                            })
                    }
                },
                swipe: { _ in EmptyView() },
                rowMenu: { _ in EmptyView() })
            // The list's own wiring: a chat dropped on another goes under it.
            .draggableRows(
                payload: { session in
                    guard families.fold(ofRow: session.id) == nil else { return nil }
                    guard selectedIds.contains(session.id), selectedIds.count > 1 else {
                        return SessionFamilies.dragPayload(for: session)
                    }
                    let selected = families.all.filter { selectedIds.contains($0.id) && families.fold(ofRow: $0.id) == nil }
                    return selected.isEmpty ? SessionFamilies.dragPayload(for: session) : SessionFamilies.dragPayload(for: selected)
                },
                canDrop: { carried, target in
                    let destinationId = families.fold(ofRow: target.id)?.parentId
                        ?? (target.id.hasPrefix(SessionFamilies.foldRowPrefix) ? nil : target.id)
                    guard let destinationId else { return false }
                    let ids = SessionFamilies.draggedSessionIds(carried)
                    return every.canPlace(ids, under: destinationId)
                },
                onDrop: { carried, target in
                    let destinationId = families.fold(ofRow: target.id)?.parentId
                        ?? (target.id.hasPrefix(SessionFamilies.foldRowPrefix) ? nil : target.id)
                    guard let destinationId else { return }
                    let ids = SessionFamilies.draggedSessionIds(carried)
                    guard every.canPlace(ids, under: destinationId) else { return }
                    for id in ids { placed[id] = destinationId }
                    selectedIds.removeAll()
                    isSelecting = false
                })
            .groupedRows({ families.groupSlice(ofRow: $0.id) }, joinsNext: { families.isJoinedToFold($0.id) })
            .unhighlightedRows { $0.id.hasPrefix(SessionFamilies.foldRowPrefix) }
            // `--native-drawer`: no drawer of our own; the List's own insert and remove animation.
            .revealsRowChanges(when: Self.arguments.contains("--native-drawer") ? AnyHashable("fixed") : AnyHashable([closed, open]))
            .transaction { if Self.arguments.contains("--no-animations") { $0.disablesAnimations = true } }
            .environment(\.ripulSessionListCanBeSeen, !Self.arguments.contains("--list-covered"))
            .navigationTitle("Sessions")
            .toolbar {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selectedIds.removeAll() }
                }
            }
        }
        .overlay(alignment: .top) { if Self.arguments.contains("--pill-demo") { pillDemoBar } }
        .task { await runAnimationDemo() }
        .task { await runToggleDemo() }
    }

    /// `--pill-demo`: the chat's top-bar pill as RipulAgentScreen draws it
    /// (chatTitleMorphOverlay): the open chat's row in its compact
    /// presentation, filling its slot while the agent works, in glass between
    /// two glass buttons. With `--animation-demo` it gets a new tool every
    /// 0.75 s, to measure what the pill's tool change costs.
    private var pillDemoBar: some View {
        let session = Self.sessions.first { $0.id == "claude-cli:tools" } ?? Self.sessions[0]
        return HStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
            UnifiedSessionRow(sessionStore: store, session: session, presentation: .lozenge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
        }
        .padding(.horizontal, 12)
        .transaction { if Self.arguments.contains("--no-animations") { $0.disablesAnimations = true } }
    }

    /// `--toggle-demo`: the first family closes and opens again every 2.5 s,
    /// through the same stored set as a tap, to record and profile the drawer.
    /// With `--frame-log` each toggle's frames are written to
    /// `tmp/session-families-frames.log`: how many came late, the longest gap.
    private func runToggleDemo() async {
        guard Self.arguments.contains("--toggle-demo") else { return }
        let frames = Self.arguments.contains("--frame-log") ? FrameLog() : nil
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2500))
            frames?.mark(closed.contains("claude-cli:design") ? "open" : "close")
            if closed.contains("claude-cli:design") {
                closed.subtract(["claude-cli:design", "design"])
            } else {
                closed.insert("claude-cli:design")
            }
        }
    }

    private func runAnimationDemo() async {
        guard Self.demo else { return }
        let tools: [(name: String, label: String, detail: String)] = [
            ("Read", "Read", "GlassRichList.swift"), ("Bash", "Bash", "swift build"),
            ("Grep", "Search", "recencyRevision"), ("Edit", "Edit", "UnifiedSessionRow.swift"),
        ]
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            tick += 1
            for (index, key) in Self.openInRipul.sorted().enumerated() {
                let tool = tools[(tick + index) % tools.count]
                store.latestActivityByChatId["cli_\(key)"] = .toolStart(
                    toolName: tool.name, toolId: "\(key)-\(tick)", toolLabel: tool.label, toolDetail: tool.detail)
            }
            if !Self.arguments.contains("--no-bumps"), tick % 5 == 0 {
                spoke.append(Self.speakers[(tick / 5 - 1) % Self.speakers.count])
            }
        }
    }

    private func toggle(_ fold: SessionFamilies.Fold) {
        if fold.isOpen { open.remove(fold.parentId) } else { open.insert(fold.parentId) }
    }
}

/// Every frame's gap from the one before, summed up for the second after each
/// mark: frames drawn, frames late (a gap over 1.5 frames), the longest gap,
/// and each late frame as when it ended after the mark and how long it was
/// (`+ms:ms`), which tells a stall before the rows move from jitter while they
/// do. One line a mark in `tmp/session-families-frames.log`.
@MainActor
final class FrameLog: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var label = ""
    private var markedAt: CFTimeInterval = 0
    private var windowEnds: CFTimeInterval = 0
    private var frames = 0, late = 0
    private var longest: CFTimeInterval = 0
    private var lateGaps: [String] = []
    private let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("session-families-frames.log")

    override init() {
        super.init()
        try? FileManager.default.removeItem(at: url)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func mark(_ label: String) {
        flush()
        self.label = label
        markedAt = CACurrentMediaTime()
        windowEnds = markedAt + 1
        frames = 0; late = 0; longest = 0; lateGaps = []
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0, !label.isEmpty else { return }
        let gap = link.timestamp - last
        let frame = link.targetTimestamp - link.timestamp
        frames += 1
        if gap > frame * 1.5 {
            late += 1
            lateGaps.append(String(format: "+%.0f:%.0f", (link.timestamp - markedAt) * 1000, gap * 1000))
        }
        longest = max(longest, gap)
        if link.timestamp >= windowEnds { flush() }
    }

    private func flush() {
        guard !label.isEmpty else { return }
        let line = String(format: "%@ frames=%d late=%d longest=%.1fms gaps=%@\n", label, frames, late, longest * 1000,
                          lateGaps.joined(separator: ","))
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        label = ""
    }
}

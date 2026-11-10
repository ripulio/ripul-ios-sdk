import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// One place for everything waiting on you.
//
// Peter, 30 October 2026: "a unified question-answer center that pulls together
// everything that is waiting on me". Every question an agent waits on, every
// permission request, every mention and every macOS question on a Mac, from
// every chat and every Mac (the account's list of open questions,
// PendingQuestionStore), one card each, swiped through. A card is answered on
// the card: a choice, several, typed words or a date, sent through the app's
// page to the Mac that asked (__ripulAnswerPendingQuestion,
// pendingQuestionAnswer.ts), which checks it as it checks a tap on the card in
// the chat. A card can be left by swiping on, and the whole screen put away, at
// any time; what is left stays waiting, counted on the Agents screen.
//
// It comes forward by itself when Ripul opens, or comes back after a while
// away (UX Settings: Show When I Open Ripul, After Being Away For), as an
// agent's question arrives from a chat other than the one on screen (Bring
// Questions Forward; QuestionArrivals), and as a permission request or a macOS
// question arrives (Bring Permission Requests Forward;
// PendingQuestionStore.broughtForward), in place of
// the sheet that held each permission request in front until it was answered
// (29 October). The question mark on the Agents screen opens it.
// Show Floating Button (on by default) offers these automatic prompts as a FAB;
// tapping it opens the same cards. Explicit opens still show the cards directly.
// The rules: chrome-extension/docs/architecture/waitingOnYou.md.

/// The UX Settings that say when the screen comes forward by itself. In the standard defaults, read here.
public enum WaitingOnYouSettings {
    public static let showOnOpenKey = "ripul.waitingOnYou.showOnOpen"
    public static let awayMinutesKey = "ripul.waitingOnYou.awayMinutes"
    public static let permissionsForwardKey = "ripul.waitingOnYou.permissionsForward"
    public static let questionsForwardKey = "ripul.waitingOnYou.questionsForward"
    public static let floatingButtonKey = "ripul.waitingOnYou.floatingButton"
    public static let defaultFloatingButton = true
    /// The choices for After Being Away For, in minutes. Nought is any time.
    public static let awayChoices = [0, 1, 5, 15, 60]
    public static let defaultAwayMinutes = 5

    public static var showOnOpen: Bool { UserDefaults.standard.object(forKey: showOnOpenKey) as? Bool ?? true }
    public static var awayMinutes: Int { UserDefaults.standard.object(forKey: awayMinutesKey) as? Int ?? defaultAwayMinutes }
    public static var permissionsForward: Bool { UserDefaults.standard.object(forKey: permissionsForwardKey) as? Bool ?? true }
    public static var questionsForward: Bool { UserDefaults.standard.object(forKey: questionsForwardKey) as? Bool ?? true }
    public static var floatingButton: Bool { UserDefaults.standard.object(forKey: floatingButtonKey) as? Bool ?? defaultFloatingButton }

    public static func awayTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Any Time"
        case 1: return "1 Minute"
        case 60: return "1 Hour"
        default: return "\(minutes) Minutes"
        }
    }
}

/// When the screen comes forward, in what order its cards are, and what each answer sends. Kept apart so the checks can hold them.
public enum WaitingOnYouRules {
    /// On opening Ripul, or on coming back after being away at least the setting's minutes.
    public static func comesForward(launch: Bool, awaySince: Date?, now: Date, showOnOpen: Bool, awayMinutes: Int) -> Bool {
        guard showOnOpen else { return false }
        if launch { return true }
        guard let awaySince else { return false }
        return now.timeIntervalSince(awaySince) >= Double(awayMinutes) * 60
    }

    /// Newest first, whatever the kind (Peter, 30 October 2026: "The cards should start with newest to oldest, newest first").
    public static func ordered(_ items: [PendingAgentQuestion]) -> [PendingAgentQuestion] {
        items.enumerated().sorted { a, b in
            a.element.createdAt != b.element.createdAt ? a.element.createdAt > b.element.createdAt : a.offset < b.offset
        }.map(\.element)
    }

    /// Several choices go as a JSON array of their answers, as the card in the chat sends them.
    public static func answer(choosing indices: [Int], of item: PendingAgentQuestion) -> String? {
        let options = item.options ?? []
        let chosen = indices.sorted().filter(options.indices.contains).map { options[$0].answer }
        guard !chosen.isEmpty else { return nil }
        if item.multiSelect != true { return chosen.first }
        guard let data = try? JSONSerialization.data(withJSONObject: chosen, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A local day ("2026-10-30") or local time ("2026-10-30T14:05"), as the card's date picker sends it.
    public static func dateAnswer(_ date: Date, includeTime: Bool, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return includeTime ? day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : day
    }

    /// The card's own date, read as a local day or time.
    public static func date(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text, text.count == 10 || text.count == 16 else { return nil }
        let numbers = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard numbers.count == (text.count == 10 ? 3 : 5) else { return nil }
        var parts = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        if numbers.count == 5 { parts.hour = numbers[3]; parts.minute = numbers[4] }
        return calendar.date(from: parts)
    }
}

/// The agents' questions seen on this run of the app, so that one arriving from another chat brings the screen
/// forward (Peter, 4 November 2026: "if I'm in another chat and there's a pending question, I'm not gonna see
/// it"). A mention is read in its chat and does not; permission requests and macOS questions come forward by
/// their own rule (`PendingQuestionStore.broughtForward`).
public struct QuestionArrivals {
    private var seen: Set<String>?

    public init() {}

    /// The newest question in `items` not seen before, outside the chat on screen. The first list only says what
    /// was already waiting, which comes forward on opening (Show When I Open Ripul), so it gives nothing. A
    /// question asked in the chat on screen was seen there and never comes forward later.
    public mutating func take(_ items: [PendingAgentQuestion], isViewing: (String) -> Bool) -> PendingAgentQuestion? {
        let questions = items.filter { !$0.isMention && !$0.isPermission && !$0.isMacDialog }
        guard let known = seen else {
            seen = Set(questions.map(\.id))
            return nil
        }
        seen = known.union(questions.map(\.id))
        return WaitingOnYouRules.ordered(questions.filter { !known.contains($0.id) && !isViewing($0.chatId) }).first
    }
}

/// Whether the screen is up, and which card it shows first. Opened by the Agents screen's question mark and by the app shell.
@MainActor @Observable
public final class WaitingOnYouCentre {
    public static let shared = WaitingOnYouCentre()
    public private(set) var isPresented = false
    /// The card to show first, or nil for the first in order.
    public private(set) var focusId: String?
    /// Counts each opening, so an open screen turns to a new focus.
    public private(set) var openings = 0
    /// An automatic prompt offered as a button. It stays available after the
    /// cards are put away, until nothing waits or the preference is turned off.
    private(set) var offersButton = false

    func offer(focusing id: String? = nil, asButton: Bool) {
        if asButton {
            focusId = id
            offersButton = true
        } else {
            open(focusing: id)
        }
    }

    func clearButton() { offersButton = false }

    public func open(focusing id: String? = nil) {
        focusId = id
        openings += 1
        isPresented = true
    }

    public func close() { isPresented = false }

    /// Something else is taking the person to a chat (a tapped notification for a mention, or for a
    /// question answered only in its chat): the screen does not come forward over it by itself for a minute.
    public func holdOff() { heldOffAt = Date() }
    @ObservationIgnored private var heldOffAt: Date?
    /// Something took the person to a chat in the last minute. A host app's own
    /// start screen holds off for it too.
    public var isHeldOff: Bool { heldOffAt.map { Date().timeIntervalSince($0) < 60 } ?? false }
}

/// What the app's page says to an answer.
public struct PendingAnswerResult: Decodable, Equatable {
    public let ok: Bool
    public let error: String?
    /// Nothing waits for the answer any more: the question can go.
    public let closed: Bool?
}

extension AgentBridge {
    /// Send an answer to the Mac that asked, whichever chat is open.
    public func answerPendingQuestion(_ question: PendingAgentQuestion, value: String) async -> PendingAnswerResult {
        let request: [String: Any] = [
            "chatId": question.chatId, "questionId": question.questionId, "value": value,
            "threadId": question.threadId ?? "", "actionId": question.actionId ?? "", "machineId": question.machineId ?? "",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            let literal = String(decoding: data, as: UTF8.self)
            let result = try await callAsyncJavaScript("""
                const request = \(literal);
                if (!window.__ripulAnswerPendingQuestion) return { ok: false, error: 'This answer needs the newest Ripul page. Answer it in its chat, or try again shortly.' };
                return await window.__ripulAnswerPendingQuestion(request);
                """)
            guard let result else { return PendingAnswerResult(ok: false, error: "The app's page did not answer.", closed: nil) }
            return try JSONDecoder().decode(PendingAnswerResult.self, from: JSONSerialization.data(withJSONObject: result))
        } catch {
            return PendingAnswerResult(ok: false, error: error.localizedDescription, closed: nil)
        }
    }
}

#if os(iOS)
extension View {
    /// Mount once on the app shell: brings the Waiting on You screen forward on opening, on coming back after a
    /// while away, as a question arrives from another chat and as a permission request arrives, as UX Settings
    /// say, and shows it whenever it is opened.
    ///
    /// `comesForwardOnOpen: false` is for an app that opens on a screen of its own showing what waits and wants
    /// nothing over it. Questions and permission requests still come forward as they arrive.
    public func waitingOnYou(bridge: AgentBridge, comesForwardOnOpen: Bool = true) -> some View {
        modifier(WaitingOnYouPresenter(bridge: bridge, comesForwardOnOpen: comesForwardOnOpen))
    }
}

struct WaitingOnYouPresenter: ViewModifier {
    let bridge: AgentBridge
    var comesForwardOnOpen = true

    /// Behind the shell, in a view of its own: what it watches (each read of
    /// the list, `refreshedAt`) then redraws it alone. As the shell's own
    /// modifier, every refresh of the questions redrew the whole shell, Home
    /// and its lists with it (100 ms on Peter's Duo, 5 November 2026).
    func body(content: Content) -> some View {
        content.background { WaitingOnYouPresence(bridge: bridge, comesForwardOnOpen: comesForwardOnOpen) }
    }
}

/// What `WaitingOnYouPresenter` does: brings the screen forward as the rules say.
private struct WaitingOnYouPresence: View {
    let bridge: AgentBridge
    var comesForwardOnOpen = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var launched = false
    @State private var awaySince: Date?
    /// When the app last came to the front. Only a list read since then brings anything forward, so
    /// nothing answered elsewhere while it was away comes forward from the copy it kept.
    @State private var arrivedAt: Date?
    /// Set on opening or coming back: the screen comes forward at the next fresh list, if anything waits.
    @State private var dueSince: Date?
    /// Permission requests already brought forward on this run of the app.
    @State private var broughtForward: Set<String> = []
    /// Questions already seen on this run of the app.
    @State private var arrivals = QuestionArrivals()
    // Kept in this small leaf: defaults writes must not redraw the app shell.
    @AppStorage(WaitingOnYouSettings.floatingButtonKey) private var floatingButton = WaitingOnYouSettings.defaultFloatingButton

    private var store: PendingQuestionStore { .shared }
    private var centre: WaitingOnYouCentre { .shared }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear {
                if scenePhase == .active { arrive() }
                if store.waitingCount == 0 { centre.clearButton() }
                updateFloatingButton()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { arrive() } else if awaySince == nil { awaySince = Date() }
                updateFloatingButton()
            }
            .onChange(of: store.refreshedAt) { _, _ in
                comeForwardIfDue()
                bringPermissionsForward()
                bringQuestionsForward()
                updateFloatingButton()
            }
            .onChange(of: store.waitingCount) { _, count in
                if count == 0 { centre.clearButton() }
                updateFloatingButton()
            }
            .onChange(of: store.accountId) { _, _ in
                centre.clearButton()
                arrivals = QuestionArrivals()
                broughtForward = []
                updateFloatingButton()
            }
            .onChange(of: floatingButton) { _, enabled in
                if enabled, store.waitingCount > 0, !centre.isPresented {
                    centre.offer(asButton: true)
                } else if !enabled {
                    centre.clearButton()
                }
                updateFloatingButton()
            }
            .onChange(of: centre.offersButton) { _, _ in updateFloatingButton() }
            .onChange(of: store.broughtForward.map(\.id)) { _, _ in bringPermissionsForward() }
            .onChange(of: centre.isPresented) { _, shown in
                updateFloatingButton()
                if shown { WaitingOnYouWindow.show(bridge: bridge) } else { WaitingOnYouWindow.hide() }
            }
            // Opened again while it is meant to be up: show it, in case nothing could show it before.
            .onChange(of: centre.openings) { _, _ in
                if centre.isPresented { WaitingOnYouWindow.show(bridge: bridge) }
            }
            .onDisappear { WaitingOnYouFloatingButtonWindow.hide() }
    }

    private func updateFloatingButton() {
        if floatingButton, centre.offersButton, !centre.isPresented,
           scenePhase == .active, store.waitingCount > 0 {
            WaitingOnYouFloatingButtonWindow.show(count: store.waitingCount)
        } else {
            WaitingOnYouFloatingButtonWindow.hide()
        }
    }

    private func arrive() {
        let launch = !launched
        if comesForwardOnOpen, WaitingOnYouRules.comesForward(launch: launch, awaySince: awaySince, now: Date(),
                                          showOnOpen: WaitingOnYouSettings.showOnOpen, awayMinutes: WaitingOnYouSettings.awayMinutes) {
            dueSince = Date()
        }
        launched = true
        awaySince = nil
        arrivedAt = Date()
    }

    /// The list the screen comes forward on is a fresh one, so it never shows what was answered elsewhere while away.
    private func comeForwardIfDue() {
        guard let due = dueSince else { return }
        dueSince = nil
        guard Date().timeIntervalSince(due) < 60, !store.waiting.isEmpty, !centre.isPresented, !centre.isHeldOff else { return }
        centre.offer(asButton: floatingButton)
    }

    private func bringPermissionsForward() {
        guard scenePhase == .active, WaitingOnYouSettings.permissionsForward,
              let read = store.refreshedAt, let arrived = arrivedAt, read >= arrived else { return }
        let fresh = store.broughtForward.map(\.id).filter { !broughtForward.contains($0) }
        guard let first = fresh.first, !centre.isHeldOff else { return }
        broughtForward.formUnion(fresh)
        // An open screen shows the new request first in order already.
        if !centre.isPresented { centre.offer(focusing: first, asButton: floatingButton) }
    }

    /// A question that arrived while the app was away is taken at the first list read since it came back.
    private func bringQuestionsForward() {
        guard scenePhase == .active, let read = store.refreshedAt, let arrived = arrivedAt, read >= arrived else { return }
        // Taken whether or not it comes forward: one put aside now (the screen up, the setting off, a
        // notification taking the person to a chat) does not come forward later.
        guard let newest = arrivals.take(store.waiting, isViewing: { store.isViewing($0) }),
              WaitingOnYouSettings.questionsForward, !centre.isPresented, !centre.isHeldOff else { return }
        centre.offer(focusing: newest.id, asButton: floatingButton)
    }
}

/// The screen, over whatever is on screen, sheets included.
@MainActor
enum WaitingOnYouWindow {
    private static weak var shown: UIViewController?
    private static let watcher = DismissWatcher()

    static func show(bridge: AgentBridge, attempt: Int = 0) {
        guard shown == nil, WaitingOnYouCentre.shared.isPresented, let top = topViewController() else { return }
        // An alert that must be answered (a team invitation, iOS asking for a permission) goes first:
        // the screen comes up once it has gone, rather than over it or not at all.
        if top is UIAlertController || top.isBeingPresented || top.isBeingDismissed {
            guard attempt < 300 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                show(bridge: bridge, attempt: attempt + 1)
            }
            return
        }
        let host = UIHostingController(rootView: WaitingOnYouScreen(bridge: bridge).ripulThemeRoot())
        #if targetEnvironment(macCatalyst)
        host.modalPresentationStyle = .formSheet
        host.preferredContentSize = CGSize(width: 620, height: 760)
        #else
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        #endif
        host.view.accessibilityIdentifier = "WaitingOnYou.screen"
        host.presentationController?.delegate = watcher
        shown = host
        top.present(host, animated: true)
    }

    /// Put the screen away, then do what was asked (open a chat) once it has gone.
    static func hide(then: (() -> Void)? = nil) {
        guard let host = shown else { then?(); return }
        shown = nil
        host.dismiss(animated: true, completion: then)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// Swiped down: the screen is put away, and nothing on it is answered.
    private final class DismissWatcher: NSObject, UIAdaptivePresentationControllerDelegate {
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            MainActor.assumeIsolated {
                WaitingOnYouWindow.shown = nil
                WaitingOnYouCentre.shared.close()
            }
        }
    }
}

/// Where a card has got to.
private enum WaitingCardPhase: Equatable {
    case sending(String)
    case failed(String)
    case sent(String)
    case closed
}

struct WaitingOnYouScreen: View {
    let bridge: AgentBridge
    @State private var current: String?
    @State private var phases: [String: WaitingCardPhase] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var selections: [String: Set<Int>] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var now = Date()

    private var store: PendingQuestionStore { .shared }
    private var centre: WaitingOnYouCentre { .shared }
    private var items: [PendingAgentQuestion] { WaitingOnYouRules.ordered(store.waiting) }
    private var index: Int { current.flatMap { id in items.firstIndex { $0.id == id } } ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty { allClear } else { pager }
            }
            .background(.ripul(.surfaceSunken))
            .navigationTitle("Waiting on You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { centre.close() }
                        .keyboardShortcut(.cancelAction)
                        .uiKitIdentifier("WaitingOnYou.done")
                }
            }
        }
        .dismissesKeyboardOnTapAway()
        .onAppear { focus() }
        .onChange(of: centre.openings) { _, _ in focus() }
        // A card answered elsewhere goes; the one beside it takes its place.
        .onChange(of: items.map(\.id)) { old, ids in
            guard let current, !ids.contains(current) else { return }
            let at = old.firstIndex(of: current) ?? 0
            self.current = ids.isEmpty ? nil : ids[min(at, ids.count - 1)]
        }
        .task {
            let machines = await bridge.listMachines()
            store.pruneMacDialogs(activeMachines: machines.map { ($0.machineId, $0.displayName) })
            // Keeps "4 min ago" true while the screen is up.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    private func focus() {
        let ids = items.map(\.id)
        current = centre.focusId.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    private var pager: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        card(item)
                            .containerRelativeFrame(.horizontal)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            pageControls
        }
        .padding(.bottom, 8)
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Button { turn(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .accessibilityLabel("Previous")
                .uiKitIdentifier("WaitingOnYou.previous")
            if items.count > 1 {
                WaitingPageDots(count: items.count, current: index) { page in
                    withAnimation(.snappy) { current = items[page].id }
                }
                .fixedSize()
            }
            Text("\(index + 1) of \(items.count)")
                .font(.ripul(.footnote))
                .foregroundStyle(.ripul(.textSecondary))
                .monospacedDigit()
                .uiKitIdentifier("WaitingOnYou.count")
            Button { turn(1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= items.count - 1)
                .accessibilityLabel("Next")
                .uiKitIdentifier("WaitingOnYou.next")
        }
        .buttonStyle(.borderless)
        .font(.ripul(.body, weight: .semibold))
        .padding(.horizontal, 16)
    }

    private func turn(_ by: Int) {
        let target = index + by
        guard items.indices.contains(target) else { return }
        withAnimation(.snappy) { current = items[target].id }
    }

    private var allClear: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.ripulIcon(size: 44, weight: .regular))
                .foregroundStyle(.ripul(.success))
            Text("Nothing is waiting on you")
                .font(.ripul(.headline))
                .foregroundStyle(.ripul(.text))
            Text("Questions and permission requests from all your chats come here.")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uiKitIdentifier("WaitingOnYou.allClear")
    }

    // MARK: - A card

    private func card(_ item: PendingAgentQuestion) -> some View {
        let phase = phases[item.id]
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    kindChip(item)
                    Spacer(minLength: 8)
                    Text(age(item))
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                }
                Button { openInChat(item) } label: {
                    HStack(spacing: 4) {
                        Text(item.isMacDialog || item.isFleetAsk ? item.title : item.title.isEmpty ? "A chat" : item.title)
                            .font(.ripul(.subheadline, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.ripulIcon(.caption2, weight: .semibold))
                    }
                    .foregroundStyle(.ripul(.textSecondary))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the chat")
                .uiKitIdentifier("WaitingOnYou.card.chat")

                Text(questionText(item))
                    .font(.ripul(.body))
                    .foregroundStyle(.ripul(.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .uiKitIdentifier("WaitingOnYou.card.question")

                // Peter, 30 October 2026: "What about questions that have timed out and the agent has moved on then?"
                if item.agentMovedOn(now: now) {
                    Label("The agent has moved on. Your answer still reaches it.", systemImage: "arrow.uturn.forward")
                        .font(.ripul(.footnote))
                        .foregroundStyle(.ripul(.textSecondary))
                        .uiKitIdentifier("WaitingOnYou.card.movedOn")
                }

                answerArea(item, phase: phase)

                if case .failed(let message) = phase {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.ripul(.footnote))
                            .foregroundStyle(.ripul(.warning))
                        Text("Choose again to try once more, or answer it in its chat.")
                            .font(.ripul(.footnote))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .uiKitIdentifier("WaitingOnYou.card.failure")
                }

                footer(item, phase: phase)
            }
            .padding(18)
            .background(.ripul(.surface), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .uiKitIdentifier("WaitingOnYou.card")
    }

    private func kindChip(_ item: PendingAgentQuestion) -> some View {
        let (icon, words): (String, String) = item.isMacDialog ? ("macwindow", "macOS is asking")
            : item.isFleetAsk ? ("desktopcomputer", "Your Mac asks")
            : item.isMention ? ("at", "\(item.fromName ?? "Someone") mentioned you")
            : item.isPermission ? ("lock.shield", item.header ?? "Permission needed")
            : ("questionmark.bubble", item.header ?? "Question")
        return Label(words, systemImage: icon)
            .font(.ripul(.caption, weight: .semibold))
            .foregroundStyle(item.isPermission || item.isMacDialog ? Color.ripul(.warning) : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((item.isPermission || item.isMacDialog ? Color.ripul(.warning) : Color.accentColor).opacity(0.14), in: Capsule())
            .lineLimit(1)
            .uiKitIdentifier("WaitingOnYou.card.kind")
    }

    private func questionText(_ item: PendingAgentQuestion) -> AttributedString {
        (try? AttributedString(markdown: item.question, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(item.question)
    }

    private func age(_ item: PendingAgentQuestion) -> String {
        let asked = Date(timeIntervalSince1970: item.createdAt / 1000)
        if now.timeIntervalSince(asked) < 60 { return "Just now" }
        return RelativeDateTimeFormatter().localizedString(for: asked, relativeTo: now)
    }

    // MARK: - Answering

    @ViewBuilder
    private func answerArea(_ item: PendingAgentQuestion, phase: WaitingCardPhase?) -> some View {
        if case .sent(let answer) = phase {
            Label(answer.isEmpty ? "Sent" : "Sent: \(answer)", systemImage: "checkmark.circle.fill")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.success))
                .uiKitIdentifier("WaitingOnYou.card.sent")
        } else if phase == .closed {
            Label("Nothing is waiting for this any more.", systemImage: "checkmark.circle")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
        } else if item.isMention || item.isMacDialog || item.isFleetAsk {
            Button { openInChat(item) } label: {
                Label(item.isMacDialog ? "Show the Question" : item.isFleetAsk ? "Answer" : "Open the Chat",
                      systemImage: item.isMacDialog ? "macwindow" : item.isFleetAsk ? "checkmark.circle" : "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .modifier(WaitingProminentButton())
            .uiKitIdentifier("WaitingOnYou.card.open")
        } else if item.isAnswerableHere {
            let sending: String? = { if case .sending(let value) = phase { return value } else { return nil } }()
            VStack(alignment: .leading, spacing: 10) {
                if let options = item.options, !options.isEmpty { choices(item, options: options, sending: sending) }
                if let input = item.dateInput { datePicker(item, input: input, sending: sending) }
                if item.allowsText == true { textAnswer(item, sending: sending) }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // "This one is answered in its chat" read as already answered (Peter, 30 October 2026).
                Text("Not answered yet. This one can only be answered in its chat.")
                    .font(.ripul(.footnote))
                    .foregroundStyle(.ripul(.textSecondary))
                Button { openInChat(item) } label: {
                    Label("Answer in the Chat", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity)
                }
                .modifier(WaitingProminentButton())
                .uiKitIdentifier("WaitingOnYou.card.answerInChat")
            }
        }
    }

    private func choices(_ item: PendingAgentQuestion, options: [PendingQuestionOption], sending: String?) -> some View {
        let multiple = item.multiSelect == true
        let chosen = selections[item.id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    if multiple {
                        var next = chosen
                        if next.contains(index) { next.remove(index) } else { next.insert(index) }
                        selections[item.id] = next
                    } else if let value = WaitingOnYouRules.answer(choosing: [index], of: item) {
                        send(item, value: value, shown: option.label)
                    }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        if multiple {
                            Image(systemName: chosen.contains(index) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(index) ? Color.accentColor : Color.ripul(.textSecondary))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.ripul(.body, weight: .semibold))
                                .foregroundStyle(.ripul(.text))
                                .multilineTextAlignment(.leading)
                            if let detail = option.description, !detail.isEmpty {
                                Text(detail)
                                    .font(.ripul(.footnote))
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        if sending == option.label { ProgressView() }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .modifier(WaitingChoiceButton(selected: chosen.contains(index)))
                .disabled(sending != nil)
                .uiKitIdentifier("WaitingOnYou.card.option")
            }
            if multiple {
                let shown = chosen.sorted().map { options[$0].label }.joined(separator: ", ")
                Button {
                    if let value = WaitingOnYouRules.answer(choosing: Array(chosen), of: item) { send(item, value: value, shown: shown) }
                } label: {
                    HStack {
                        Text(chosen.isEmpty ? "Choose Any That Apply" : "Send \(chosen.count) Chosen")
                        if sending != nil { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .modifier(WaitingProminentButton())
                .disabled(chosen.isEmpty || sending != nil)
                .uiKitIdentifier("WaitingOnYou.card.sendChosen")
            }
        }
    }

    private func datePicker(_ item: PendingAgentQuestion, input: PendingQuestionDateInput, sending: String?) -> some View {
        let includeTime = input.includeTime == true
        let lower = WaitingOnYouRules.date(input.minDate) ?? .distantPast
        let upper = max(lower, WaitingOnYouRules.date(input.maxDate).map { includeTime ? $0 : $0.addingTimeInterval(86_399) } ?? .distantFuture)
        let selection = Binding<Date>(
            get: { dates[item.id] ?? WaitingOnYouRules.date(input.defaultDate) ?? min(max(Date(), lower), upper) },
            set: { dates[item.id] = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            DatePicker(includeTime ? "Date and time" : "Date", selection: selection, in: lower...upper,
                       displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                .font(.ripul(.body))
                .uiKitIdentifier("WaitingOnYou.card.date")
            Button {
                let value = WaitingOnYouRules.dateAnswer(selection.wrappedValue, includeTime: includeTime)
                send(item, value: value, shown: selection.wrappedValue.formatted(date: .abbreviated, time: includeTime ? .shortened : .omitted))
            } label: {
                HStack {
                    Text(includeTime ? "Send Date and Time" : "Send Date")
                    if sending != nil { ProgressView() }
                }
                .frame(maxWidth: .infinity)
            }
            .modifier(WaitingProminentButton())
            .disabled(sending != nil)
            .uiKitIdentifier("WaitingOnYou.card.sendDate")
        }
    }

    private func textAnswer(_ item: PendingAgentQuestion, sending: String?) -> some View {
        let text = Binding<String>(get: { drafts[item.id] ?? "" }, set: { drafts[item.id] = $0 })
        let words = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = item.isPassword ? "••••••••" : words
        return HStack(alignment: .bottom, spacing: 8) {
            Group {
                if item.isPassword {
                    SecureField("Enter password or secret", text: text)
                } else {
                    TextField(item.options?.isEmpty == false ? "Or type an answer" : "Type an answer", text: text, axis: .vertical)
                        .lineLimit(1...6)
                }
            }
            .font(.ripul(.body))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ripul(.surfaceSunken), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .submitLabel(.send)
            .onSubmit {
                if !words.isEmpty {
                    let value = text.wrappedValue
                    if item.isPassword { drafts[item.id] = "" }
                    send(item, value: value, shown: shown)
                }
            }
            .uiKitIdentifier("WaitingOnYou.card.text")
            Button {
                let value = text.wrappedValue
                if item.isPassword { drafts[item.id] = "" }
                send(item, value: value, shown: shown)
            } label: {
                if sending != nil { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.ripulIcon(size: 30, weight: .regular)) }
            }
            .buttonStyle(.borderless)
            .disabled(words.isEmpty || sending != nil)
            .accessibilityLabel("Send")
            .uiKitIdentifier("WaitingOnYou.card.sendText")
        }
    }

    private func footer(_ item: PendingAgentQuestion, phase: WaitingCardPhase?) -> some View {
        HStack(spacing: 16) {
            // A card whose main button already opens the chat does not offer it twice.
            if item.isAnswerableHere {
                Button("Open the Chat") { openInChat(item) }
                    .uiKitIdentifier("WaitingOnYou.card.openChat")
            }
            Spacer(minLength: 0)
            // Clearing never answers: a permission request stays until it is answered.
            // A macOS dialog can be dismissed permanently (for example if the Mac was
            // erased or the person already handled it at the Mac).
            if !item.isPermission {
                Button(item.isMention ? "Mark as Read" : item.isMacDialog ? "Dismiss" : "Clear") { clear(item) }
                    .foregroundStyle(.ripul(.textSecondary))
                    .uiKitIdentifier("WaitingOnYou.card.clear")
            }
            if index < items.count - 1 {
                Button("Later") { turn(1) }
                    .uiKitIdentifier("WaitingOnYou.card.later")
            }
        }
        .font(.ripul(.subheadline, weight: .semibold))
        .buttonStyle(.borderless)
        .padding(.top, 4)
    }

    private func send(_ item: PendingAgentQuestion, value: String, shown: String) {
        if case .sending = phases[item.id] { return }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phases[item.id] = .sending(shown)
        Task { @MainActor in
            let result = await bridge.answerPendingQuestion(item, value: value)
            if result.ok {
                phases[item.id] = .sent(shown)
                drafts[item.id] = nil
                await finish(item)
            } else if result.closed == true {
                phases[item.id] = .closed
                await finish(item)
            } else {
                phases[item.id] = .failed(result.error ?? "Your answer could not be sent.")
            }
        }
    }

    /// Show the outcome for a moment, turn to the next card, then let the answered one go.
    private func finish(_ item: PendingAgentQuestion) async {
        try? await Task.sleep(for: .milliseconds(700))
        let ids = items.map(\.id)
        if current == item.id, let at = ids.firstIndex(of: item.id) {
            let next = ids.indices.contains(at + 1) ? ids[at + 1] : at > 0 ? ids[at - 1] : nil
            if let next { withAnimation(.snappy) { current = next } }
        }
        try? await Task.sleep(for: .milliseconds(350))
        store.settle(item)
        phases[item.id] = nil
        selections[item.id] = nil
        // The last one answered: the screen goes by itself.
        if store.waiting.isEmpty {
            try? await Task.sleep(for: .milliseconds(900))
            if store.waiting.isEmpty { centre.close() }
        }
    }

    private func clear(_ item: PendingAgentQuestion) {
        if item.isMention { store.clearMentions(anyOf: [item.chatId]) } else { store.dismiss(item) }
    }

    private func openInChat(_ item: PendingAgentQuestion) {
        let open = store.openQuestion
        centre.close()
        WaitingOnYouWindow.hide { open?(item) }
    }
}

/// The system's page dots, tappable.
private struct WaitingPageDots: UIViewRepresentable {
    let count: Int
    let current: Int
    let select: (Int) -> Void

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.hidesForSinglePage = true
        control.backgroundStyle = .minimal
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.select = select
        control.numberOfPages = count
        control.currentPage = current
        control.pageIndicatorTintColor = UIColor.ripul(.textTertiary)
        control.currentPageIndicatorTintColor = UIColor.ripul(.text)
    }

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    final class Coordinator: NSObject {
        var select: (Int) -> Void
        init(select: @escaping (Int) -> Void) { self.select = select }
        @objc func changed(_ control: UIPageControl) { select(control.currentPage) }
    }
}

/// A choice: Liquid Glass on iOS 26, bordered before it.
private struct WaitingChoiceButton: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if selected { content.buttonStyle(.glassProminent).buttonBorderShape(.roundedRectangle(radius: 14)) }
            else { content.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 14)) }
        } else {
            if selected { content.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14)) }
            else { content.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)) }
        }
    }
}

/// The card's main action.
private struct WaitingProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
#endif

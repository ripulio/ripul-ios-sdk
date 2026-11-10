#if canImport(UIKit)
import UIKit

/// While this device is shared with someone else's chat for reading, a pill at
/// the top of the screen says so, with Stop, for as long as it lasts: "“Wac
/// theme” can read this app". It shrinks to a small "Shared" mark after a few
/// seconds and opens again each time the chat reads something.
///
/// The page decides what is shared and keeps the person's choice
/// (`chrome-extension/src/relay/memberDevice.ts`); it reports every change as
/// `agent-framework:device:sharing`. Each of an app's agent pages reports its
/// own shares, so the pill shows them all together, and Stop stops them all.
/// See `docs/sharing-a-device.md`.
@MainActor
final class DeviceSharingIndicator {
    static let shared = DeviceSharingIndicator()

    struct Share: Equatable {
        let chatId: String
        let title: String?
        let screen: Bool
        let until: Date
        let lastUse: Date?

        init?(_ raw: [String: Any]) {
            guard let chatId = raw["chatId"] as? String, !chatId.isEmpty,
                  let until = (raw["until"] as? NSNumber)?.doubleValue else { return nil }
            self.chatId = chatId
            let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = title?.isEmpty == false ? title : nil
            self.screen = raw["screen"] as? Bool ?? false
            self.until = Date(timeIntervalSince1970: until / 1000)
            self.lastUse = ((raw["lastUse"] as? [String: Any])?["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
    }

    private struct Source {
        var shares: [Share]
        let stop: () -> Void
    }

    private let indicator = LiveStreamIndicator(mark: "Shared", lead: "This app is shared",
                                                hint: "Shows which chat can read it, and Stop")
    private var sources: [ObjectIdentifier: Source] = [:]
    private var shown: [Share] = []
    private var ending: Task<Void, Never>?

    /// One page's shares, replacing what it said before. `stop` ends all of that page's.
    func update(from page: AnyObject, shares raw: [[String: Any]], stop: @escaping () -> Void) {
        let shares = raw.compactMap(Share.init).filter { $0.until > Date() }
        if shares.isEmpty { sources[ObjectIdentifier(page)] = nil }
        else { sources[ObjectIdentifier(page)] = Source(shares: shares, stop: stop) }
        refresh()
    }

    /// A page that has gone takes its shares with it: it can no longer answer for them.
    func forget(_ page: ObjectIdentifier) {
        guard sources.removeValue(forKey: page) != nil else { return }
        refresh()
    }

    private func refresh() {
        let now = Date()
        for key in sources.keys {
            sources[key]?.shares.removeAll { $0.until <= now }
            if sources[key]?.shares.isEmpty == true { sources[key] = nil }
        }
        let all = sources.values.flatMap(\.shares)
        ending?.cancel()
        guard let soonest = all.map(\.until).min() else {
            shown = []
            indicator.hide()
            return
        }
        // Down at the end the page gave, even if the page is too busy to say so.
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, soonest.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
        guard all != shown else { return }
        shown = all
        let stops = sources.values.map(\.stop)
        indicator.show(Self.text(for: all)) { [weak self] in
            for stop in stops { stop() }
            self?.sources = [:]
            self?.refresh()
        }
    }

    /// "“Wac theme” can read this app", "… and its screen", or "2 chats can read …".
    static func text(for shares: [Share]) -> String {
        let what = shares.contains(where: \.screen) ? "can read this app and its screen" : "can read this app"
        let chats = Set(shares.map(\.chatId))
        if chats.count == 1, let title = shares.first?.title { return "“\(title)” \(what)" }
        return chats.count == 1 ? "A chat \(what)" : "\(chats.count) chats \(what)"
    }
}
#endif

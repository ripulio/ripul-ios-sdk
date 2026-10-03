#if canImport(UIKit)
import Foundation
import Observation
import UIKit

// MARK: - Support sessions
//
// Lets an app's customer show the app to somebody helping them. The customer
// asks for help and gets a six-digit code to read out; the supporter, signed
// in to Ripul and allowed to support the app's site key, enters it; the
// customer is told who that is and agrees; the supporter then sees this app
// (never the rest of the phone) and can point at things in it. They can't
// tap, type or do anything else: the customer does that. A pill at the top of
// the screen says who is watching, with Stop, for as long as they are.
//
// The customer signs in to nothing. The app's site key says which app is
// asking; only that key's creator, owners and admins can use the code.
//
// Everything here is public Apple API and is the same in every build.
// The session's own screen is `RipulSupportView`.

/// What a support session needs to know about the app.
public struct RipulSupportConfiguration: Sendable {
    /// The app's publishable site key (`pk_live_…`).
    public var siteKey: String
    /// Where Ripul is served from.
    public var baseURL: URL
    /// The Origin sent with the request for a code: one the site key allows.
    /// Nil sends `baseURL`'s own.
    public var origin: String?
    /// Ripul's API host, which the session's WebSocket goes to directly.
    public var socketURL: URL

    public init(siteKey: String, baseURL: URL = AgentConfiguration.defaultBaseURL, origin: String? = nil,
                socketURL: URL = LiveStreamRelay.server) {
        self.siteKey = siteKey
        self.baseURL = baseURL
        self.origin = origin
        self.socketURL = socketURL
    }

    var apiURL: URL { baseURL.appendingPathComponent("api") }

    var originHeader: String {
        if let origin { return origin }
        var parts = URLComponents()
        parts.scheme = baseURL.scheme
        parts.host = baseURL.host
        parts.port = baseURL.port
        return parts.url?.absoluteString ?? baseURL.absoluteString
    }
}

/// The app's one support session. Start it when the customer asks for help;
/// `RipulSupportView` shows it and takes their answers.
@MainActor
@Observable
public final class RipulSupport {
    public static let shared = RipulSupport()

    public enum Phase: Equatable, Sendable {
        case idle
        /// Asking for a code.
        case starting
        /// The code to read out. Nobody has taken it yet.
        case waiting(code: String)
        /// A supporter has taken the code and waits for the customer's answer.
        case asking(code: String, supporter: String)
        /// The supporter is seeing the app.
        case sharing(supporter: String)
        /// It is over; why, in words for the customer.
        case ended(String)
        /// It never started; why.
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    /// While sharing: the supporter's connection has dropped, or this app left the foreground.
    /// The pill stays up, saying so, with Stop: the picture carries on by itself when both are back.
    public private(set) var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                showPaused()
            } else if !LiveStreamHost.shared.isSupporting {
                LiveStreamHost.shared.supportWaiting(nil)
            }
        }
    }

    private func showPaused() {
        guard isPaused, case .sharing(let name) = phase else { return }
        LiveStreamHost.shared.supportWaiting("Paused · \(name)") { [weak self] in self?.stop() }
    }

    /// True from asking for a code until the session is over.
    public var isActive: Bool {
        switch phase {
        case .idle, .ended, .failed: false
        default: true
        }
    }

    /// A supporter who doesn't come back is given this long.
    static let supporterPatience: TimeInterval = 120
    /// Tries at getting the connection to the room back before giving up.
    static let mostReconnects = 5

    @ObservationIgnored private var configuration: RipulSupportConfiguration?
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var channel: LiveStreamChannel?
    @ObservationIgnored private var run: Task<Void, Never>?
    /// The supporter in the room, as the room names them; nil while there is none.
    @ObservationIgnored private var supporter: (name: String, who: String)?
    /// The supporter the customer agreed to. Somebody else means asking again.
    @ObservationIgnored private var agreedTo: String?
    @ObservationIgnored private var away: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: Starting and stopping

    /// Asks for a code and waits for a supporter. Does nothing while a session is under way.
    public func start(_ configuration: RipulSupportConfiguration) {
        guard !isActive else { return }
        self.configuration = configuration
        phase = .starting
        isPaused = false
        supporter = nil
        agreedTo = nil
        run = Task { [weak self] in await self?.open(configuration) }
        watchForeground()
    }

    /// The customer agrees to the supporter who is asking.
    public func allow() {
        guard case .asking = phase, let supporter else { return }
        agreedTo = supporter.who
        share()
    }

    /// The customer says no, or stops: the session ends and its code is spent.
    public func stop() {
        guard isActive else { return }
        let wasSharing = if case .sharing = phase { true } else { false }
        finish(wasSharing ? "You stopped sharing." : "The request for help was cancelled.",
               goodbye: "The customer ended the session")
    }

    /// Back to the start, from a session that has ended or failed.
    public func reset() {
        guard !isActive else { return }
        phase = .idle
    }

    // MARK: The session

    private func open(_ configuration: RipulSupportConfiguration) async {
        do {
            let made = try await Self.request(configuration)
            guard case .starting = phase else { return }
            code = made.code
            token = made.token
            let channel = try await LiveStreamRelay.connect(server: configuration.socketURL, code: made.code,
                                                            role: .customer, token: made.token)
            guard case .starting = phase else {
                channel.close()
                return
            }
            self.channel = channel
            phase = .waiting(code: made.code)
            await listen(configuration)
        } catch {
            guard case .starting = phase else { return }
            fail((error as? LocalizedError)?.errorDescription ?? "Couldn't reach Ripul. Check the connection and try again.")
        }
    }

    /// Reads the room until the session is over, reconnecting when the connection drops.
    private func listen(_ configuration: RipulSupportConfiguration) async {
        var reconnects = 0
        while isActive, !Task.isCancelled {
            guard let channel else { return }
            let alive = Task { [weak channel] in
                // The room's way here closes a connection that says nothing for a while.
                while !Task.isCancelled, let channel {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    channel.keepAlive()
                }
            }
            do {
                while true {
                    let (type, payload) = try await channel.receive()
                    guard self.channel === channel else { break }
                    reconnects = 0
                    if type == .room {
                        heard(LiveStreamWire.json(payload))
                    } else {
                        await LiveStreamHost.shared.supportHeard(type, payload)
                    }
                }
            } catch {
                // Dropped, or closed by us or by the room: which, is in `phase`.
            }
            alive.cancel()
            guard isActive, !Task.isCancelled, self.channel === channel else { return }

            // The connection dropped under a live session: sharing stops until it is back.
            self.channel = nil
            if LiveStreamHost.shared.isSupporting { LiveStreamHost.shared.end("The connection dropped", ending: .background) }
            supporter = nil
            while isActive, self.channel == nil {
                reconnects += 1
                if reconnects > Self.mostReconnects {
                    finish("The connection to the support session was lost.", goodbye: nil)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(min(reconnects, 4)) * 1_000_000_000)
                guard isActive, UIApplication.shared.applicationState == .active else {
                    // In the background nothing connects; `returned` tries again.
                    reconnects -= 1
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                // No way through and "the room has forgotten this session" look alike from
                // here, so both get the same few tries.
                self.channel = try? await LiveStreamRelay.connect(server: configuration.socketURL, code: code,
                                                                  role: .customer, token: token)
            }
        }
    }

    /// What the room says: who is there, and when it is over.
    private func heard(_ message: [String: Any]) {
        switch message["event"] as? String {
        case "peer":
            guard message["role"] as? String == "supporter" else { return }
            if message["present"] as? Bool == true, let name = message["name"] as? String {
                away?.cancel()
                away = nil
                let who = message["who"] as? String ?? name
                supporter = (name, who)
                if agreedTo == who {
                    // The one already agreed to, back after a dropped connection.
                    share()
                } else {
                    // Somebody new: nothing is shown until the customer says so.
                    if LiveStreamHost.shared.isSupporting {
                        LiveStreamHost.shared.end("Another supporter joined", ending: .background)
                    }
                    agreedTo = nil
                    isPaused = false
                    phase = .asking(code: code, supporter: name)
                }
            } else {
                supporter = nil
                switch phase {
                case .asking:
                    phase = .waiting(code: code)
                case .sharing:
                    isPaused = true
                    away?.cancel()
                    away = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(Self.supporterPatience * 1_000_000_000))
                        guard !Task.isCancelled, let self, self.supporter == nil else { return }
                        self.finish("The supporter's connection was lost.", goodbye: "The supporter did not come back")
                    }
                default:
                    break
                }
            }
        case "ended":
            let reason = message["reason"] as? String ?? "The support session has ended."
            finish(reason.hasSuffix(".") ? reason : reason + ".", goodbye: nil)
        default:
            break
        }
    }

    /// Starts showing the app to the supporter in the room, whom the customer has agreed to.
    private func share() {
        guard let supporter, let channel, agreedTo == supporter.who else { return }
        if LiveStreamHost.shared.isSupporting {
            // Still showing on this connection: the supporter is back, and their hello restarts the picture.
            isPaused = false
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            // Agreed, but the app isn't in front: it starts when it is (`returned`).
            phase = .sharing(supporter: supporter.name)
            isPaused = true
            return
        }
        let refusal = LiveStreamHost.shared.beginSupport(channel: channel, supporter: supporter.name) { [weak self] ending in
            self?.sharingEnded(ending)
        }
        if let refusal {
            finish(refusal + ".", goodbye: refusal)
            return
        }
        phase = .sharing(supporter: supporter.name)
        isPaused = false
    }

    private func sharingEnded(_ ending: LiveStreamHost.SupportEnding) {
        guard case .sharing(let name) = phase else { return }
        switch ending {
        case .stopped:
            finish("You stopped sharing.", goodbye: "The customer stopped sharing")
        case .background:
            // Out of the app, or the connection went: it carries on when both are back.
            isPaused = true
        case .left:
            finish("\(name) has left. The session is over.", goodbye: nil)
        case .failed(let reason):
            finish("This device couldn't share its screen.", goodbye: reason)
        }
    }

    /// Ends the session here. `goodbye` is said to the room first, which ends it for the supporter too.
    private func finish(_ reason: String, goodbye: String?) {
        guard isActive else { return }
        phase = .ended(reason)
        close(goodbye: goodbye)
    }

    private func fail(_ reason: String) {
        phase = .failed(reason)
        close(goodbye: nil)
    }

    private func close(goodbye: String?) {
        isPaused = false
        away?.cancel()
        away = nil
        run?.cancel()
        run = nil
        supporter = nil
        agreedTo = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if LiveStreamHost.shared.isSupporting { LiveStreamHost.shared.end("The session ended", ending: .background) }
        guard let channel else { return }
        self.channel = nil
        Task {
            if let goodbye { try? await channel.send(.bye, json: ["reason": goodbye]) }
            channel.close()
        }
    }

    // MARK: Leaving the app and coming back

    private func watchForeground() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RipulSupport.shared.returned() }
        }]
    }

    /// The app is in front again: sharing carries on if the customer had agreed and the supporter is still there.
    private func returned() {
        guard case .sharing = phase, isPaused, !LiveStreamHost.shared.isSupporting else { return }
        share()
        // Nobody to show it to yet: the pill says the session is still open.
        showPaused()
    }

    // MARK: Asking for a code

    struct Made {
        let code: String
        let token: String
    }

    struct Refused: LocalizedError {
        let errorDescription: String?
    }

    static func request(_ configuration: RipulSupportConfiguration) async throws -> Made {
        var request = URLRequest(url: configuration.apiURL.appendingPathComponent("v1/support/sessions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.siteKey, forHTTPHeaderField: "X-Site-Key")
        request.setValue(configuration.originHeader, forHTTPHeaderField: "Origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "app": RipulLiveViewIdentity.appName,
            "device": RipulLiveViewIdentity.modelName,
            "system": UIDevice.current.systemVersion,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let code = json["code"] as? String, let token = json["token"] as? String else {
            let said = (json["error"] as? [String: Any])?["message"] as? String
            nwarn("[Support] no code: status \(status), \(said ?? "no message")")
            // The server's words for being asked too often are for the customer; the rest are for a developer.
            throw Refused(errorDescription: status == 429 ? said : "Help isn't available just now. Try again in a moment.")
        }
        return Made(code: code, token: token)
    }
}
#endif

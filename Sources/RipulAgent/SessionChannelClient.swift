//
//  SessionChannelClient.swift
//  RipulAgent
//
//  Swift port of `chrome-extension/src/relay/SessionChannelClient.ts`.
//
//  Phase 3.5 host-as-writer: ClaudeCliServer streams CLI events to the
//  SessionChannel Durable Object via `session.apply`, replacing the bridge
//  push as the system of record. This client is the writer side — one
//  WebSocket per subscribed chatId, with ack-correlated `applyActions`,
//  exponential-backoff reconnect, and heartbeat liveness.
//
//  The web-app TS implementation is the reference; we omit the rich
//  diagnostic surface (frame buffer, visibility handler) that the web app
//  needs but the host doesn't. Wire format and semantics match exactly.
//

import Foundation

// MARK: - Public types

public enum SessionErrorCode: String, Sendable {
    case unauthorized
    case tooLarge = "too_large"
    case rateLimited = "rate_limited"
    case notFound = "not_found"
    case `internal`
}

public enum SessionConnectionState: String, Sendable {
    case connecting
    case connected
    case reconnecting
    case failed
    case disposed
}

public enum SessionChannelError: Error, CustomStringConvertible {
    case disposed
    case notSubscribed(chatId: String)
    case notConnected(state: SessionConnectionState)
    case socketClosed
    case ackTimeout(timeoutMs: Int)
    case server(code: SessionErrorCode, message: String)
    case tokenUnavailable

    public var description: String {
        switch self {
        case .disposed:
            return "SessionChannelClient disposed"
        case .notSubscribed(let chatId):
            return "Not subscribed to chat \(chatId)"
        case .notConnected(let state):
            return "SessionChannel not connected (state=\(state.rawValue))"
        case .socketClosed:
            return "WebSocket closed before ack"
        case .ackTimeout(let ms):
            return "session.apply ack timeout after \(ms)ms"
        case .server(let code, let message):
            return "session.error: \(code.rawValue) — \(message)"
        case .tokenUnavailable:
            return "No auth token available"
        }
    }
}

public typealias SessionSnapshotListener = (_ chatId: String, _ actions: [[String: Any]], _ seq: Int) -> Void
public typealias SessionDeltaListener = (_ chatId: String, _ actions: [[String: Any]], _ seq: Int) -> Void
public typealias SessionErrorListener = (_ chatId: String, _ code: SessionErrorCode, _ message: String) -> Void

public struct SessionChannelClientConfig {
    /// Returns a fresh Clerk JWT; called before every connect attempt.
    public var getToken: () async -> String?
    /// LLM-proxy base URL (http/https). Auto-converted to ws/wss.
    public var baseUrl: String
    /// Stable per-device clientId (used for DO reconnect de-dup).
    public var clientId: String
    /// Heartbeat interval in ms (default 30 000 — matches DO STALE_TIMEOUT_MS / 3).
    public var heartbeatIntervalMs: Int
    /// Max reconnect attempts before giving up.
    public var maxReconnectAttempts: Int
    /// How long to wait for a session.ack before rejecting applyActions.
    public var applyAckTimeoutMs: Int

    public init(
        getToken: @escaping () async -> String?,
        baseUrl: String = RipulDomain.llmProxyURL,
        clientId: String,
        heartbeatIntervalMs: Int = 30_000,
        maxReconnectAttempts: Int = 10,
        applyAckTimeoutMs: Int = 15_000
    ) {
        self.getToken = getToken
        self.baseUrl = baseUrl
        self.clientId = clientId
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.maxReconnectAttempts = maxReconnectAttempts
        self.applyAckTimeoutMs = applyAckTimeoutMs
    }
}

// MARK: - Internal types

private final class ChatSocket {
    let chatId: String
    var session: URLSession?
    var task: URLSessionWebSocketTask?
    var state: SessionConnectionState = .connecting
    var reconnectAttempts: Int = 0
    var reconnectTimer: DispatchSourceTimer?
    var heartbeatTimer: DispatchSourceTimer?
    var lastPongAt: Date = Date()
    var highestSeqSeen: Int = 0
    var pendingApplies: [String: PendingApply] = [:]
    var doId: String? = nil
    var subscriberCount: Int? = nil

    init(chatId: String) {
        self.chatId = chatId
    }
}

private struct PendingApply {
    let continuation: CheckedContinuation<Int, Error>
    let timer: DispatchSourceTimer
}

// MARK: - SessionChannelClient

public final class SessionChannelClient: NSObject {
    private let config: SessionChannelClientConfig
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "ripul.session-channel.work")

    /// Delegate queue for URLSession callbacks. Mirrors GuardianProcess —
    /// running delegate methods on .main keeps state mutations serialized
    /// against subscribe/dispose calls coming from app code.
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "ripul.session-channel.delegate"
        return q
    }()

    private var sockets: [String: ChatSocket] = [:]
    /// Reverse map for delegate lookups (task -> chatId).
    private var taskToChatId: [ObjectIdentifier: String] = [:]
    private var disposed: Bool = false

    private var snapshotListeners: [UUID: SessionSnapshotListener] = [:]
    private var deltaListeners: [UUID: SessionDeltaListener] = [:]
    private var errorListeners: [UUID: SessionErrorListener] = [:]

    public init(config: SessionChannelClientConfig) {
        self.config = config
        super.init()
    }

    public var clientId: String { config.clientId }

    // MARK: Sync helpers (NSLock-safe — never call across `await`)

    /// Sync precondition check for applyActions. Extracted so the async
    /// caller doesn't hold NSLock across an await boundary (Swift 6 disallows).
    private func validateApplyPrecondition(chatId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if disposed { throw SessionChannelError.disposed }
        guard let sock = sockets[chatId] else {
            throw SessionChannelError.notSubscribed(chatId: chatId)
        }
        if sock.state != .connected || sock.task == nil {
            throw SessionChannelError.notConnected(state: sock.state)
        }
    }

    // MARK: Public API

    public func subscribe(chatId: String) {
        guard !chatId.isEmpty else { return }
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        if sockets[chatId] != nil {
            lock.unlock()
            return
        }
        let sock = ChatSocket(chatId: chatId)
        sock.state = .connecting
        sockets[chatId] = sock
        lock.unlock()

        Task { [weak self] in
            await self?.connect(chatId: chatId)
        }
    }

    public func unsubscribe(chatId: String) {
        lock.lock()
        guard let sock = sockets.removeValue(forKey: chatId) else {
            lock.unlock()
            return
        }
        if let task = sock.task {
            taskToChatId.removeValue(forKey: ObjectIdentifier(task))
        }
        lock.unlock()
        teardown(sock)
    }

    /// Send an apply batch and wait for the matching ack. Throws
    /// `SessionChannelError` on server error, socket loss, or timeout —
    /// callers should fall back to the POST batch endpoint in that case.
    public func applyActions(chatId: String, actions: [[String: Any]]) async throws -> Int {
        try validateApplyPrecondition(chatId: chatId)

        let clientSeq = UUID().uuidString

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            // Timer fires on workQueue; cancellation is safe from any thread.
            let timer = DispatchSource.makeTimerSource(queue: workQueue)
            timer.schedule(deadline: .now() + .milliseconds(config.applyAckTimeoutMs))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let sock = self.sockets[chatId]
                let pending = sock?.pendingApplies.removeValue(forKey: clientSeq)
                self.lock.unlock()
                if pending != nil {
                    continuation.resume(throwing: SessionChannelError.ackTimeout(timeoutMs: self.config.applyAckTimeoutMs))
                }
            }
            timer.resume()

            self.lock.lock()
            // Re-check in case dispose/unsubscribe raced us.
            guard let sock = self.sockets[chatId], sock.state == .connected, let task = sock.task else {
                self.lock.unlock()
                timer.cancel()
                continuation.resume(throwing: SessionChannelError.notConnected(state: self.sockets[chatId]?.state ?? .disposed))
                return
            }
            sock.pendingApplies[clientSeq] = PendingApply(continuation: continuation, timer: timer)
            self.lock.unlock()

            let payload: [String: Any] = [
                "type": "session.apply",
                "chatId": chatId,
                "clientSeq": clientSeq,
                "actions": actions,
            ]
            self.send(task: task, payload: payload)
        }
    }

    public func dispose() {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        let allSockets = Array(sockets.values)
        sockets.removeAll()
        taskToChatId.removeAll()
        snapshotListeners.removeAll()
        deltaListeners.removeAll()
        errorListeners.removeAll()
        lock.unlock()

        for sock in allSockets {
            teardown(sock)
        }
    }

    // MARK: Listener registration

    @discardableResult
    public func onSnapshot(_ cb: @escaping SessionSnapshotListener) -> UUID {
        let id = UUID()
        lock.lock()
        snapshotListeners[id] = cb
        lock.unlock()
        return id
    }

    @discardableResult
    public func onDelta(_ cb: @escaping SessionDeltaListener) -> UUID {
        let id = UUID()
        lock.lock()
        deltaListeners[id] = cb
        lock.unlock()
        return id
    }

    @discardableResult
    public func onError(_ cb: @escaping SessionErrorListener) -> UUID {
        let id = UUID()
        lock.lock()
        errorListeners[id] = cb
        lock.unlock()
        return id
    }

    public func removeListener(id: UUID) {
        lock.lock()
        snapshotListeners.removeValue(forKey: id)
        deltaListeners.removeValue(forKey: id)
        errorListeners.removeValue(forKey: id)
        lock.unlock()
    }

    public func subscribedChatIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sockets.keys)
    }

    public func chatState(for chatId: String) -> SessionConnectionState? {
        lock.lock()
        defer { lock.unlock() }
        return sockets[chatId]?.state
    }

    // MARK: Connect / reconnect

    /// NSLock is not async-safe — Swift 6 disallows holding it across `await`.
    /// `connect` does its locked state mutations in synchronous helpers and
    /// only awaits `getToken()` between them.
    private func connect(chatId: String) async {
        guard prepareConnect(chatId: chatId) else { return }

        let token = await config.getToken()

        guard let task = finalizeConnect(chatId: chatId, token: token) else {
            return
        }

        task.resume()
        receiveLoop(chatId: chatId, task: task)
    }

    /// Sync prelude — flips state to connecting/reconnecting if still subscribed.
    /// Returns false if the subscription was torn down before connect ran.
    private func prepareConnect(chatId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed, let sock = sockets[chatId] else { return false }
        sock.state = sock.reconnectAttempts > 0 ? .reconnecting : .connecting
        return true
    }

    /// Sync postlude — builds URL, creates URLSession + task, stores them on
    /// the ChatSocket. Returns the task so the caller (still on the async
    /// path, but no longer holding the lock) can resume() it and start the
    /// receive loop. Returns nil if the subscription was torn down or token
    /// is missing/URL invalid.
    private func finalizeConnect(chatId: String, token: String?) -> URLSessionWebSocketTask? {
        lock.lock()
        guard !disposed, let sock = sockets[chatId] else {
            lock.unlock()
            return nil
        }
        guard let token, !token.isEmpty else {
            lock.unlock()
            emitError(chatId: chatId, code: .unauthorized, message: SessionChannelError.tokenUnavailable.description)
            scheduleReconnect(chatId: chatId)
            return nil
        }

        let wsBase = toWsUrl(config.baseUrl)
        let encodedChatId = chatId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatId
        var components = URLComponents(string: "\(wsBase)/v1/session/\(encodedChatId)")
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "clientId", value: config.clientId),
        ]
        guard let url = components?.url else {
            lock.unlock()
            emitError(chatId: chatId, code: .internal, message: "Invalid WebSocket URL")
            scheduleReconnect(chatId: chatId)
            return nil
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1_048_576

        sock.session = session
        sock.task = task
        taskToChatId[ObjectIdentifier(task)] = chatId
        lock.unlock()
        return task
    }

    private func receiveLoop(chatId: String, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // didCloseWith / didCompleteWithError will fire and trigger reconnect.
                return
            case .success(let message):
                self.handleIncoming(chatId: chatId, message: message)
                // Continue listening on the same task instance.
                self.lock.lock()
                let stillCurrent = self.sockets[chatId]?.task === task
                self.lock.unlock()
                if stillCurrent {
                    self.receiveLoop(chatId: chatId, task: task)
                }
            }
        }
    }

    private func handleIncoming(chatId: String, message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s):
            text = s
        case .data(let d):
            text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:
            return
        }
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }
        handleServerMessage(chatId: chatId, type: type, json: json)
    }

    private func handleServerMessage(chatId: String, type: String, json: [String: Any]) {
        switch type {
        case "session.pong":
            lock.lock()
            sockets[chatId]?.lastPongAt = Date()
            lock.unlock()

        case "session.snapshot":
            let actions = (json["actions"] as? [[String: Any]]) ?? []
            let seq = (json["seq"] as? Int) ?? 0
            lock.lock()
            if let sock = sockets[chatId] {
                if seq > sock.highestSeqSeen { sock.highestSeqSeen = seq }
                if let doId = json["doId"] as? String { sock.doId = doId }
                if let count = json["subscriberCount"] as? Int { sock.subscriberCount = count }
            }
            let listeners = Array(snapshotListeners.values)
            lock.unlock()
            for cb in listeners {
                cb(chatId, actions, seq)
            }

        case "session.delta":
            let actions = (json["actions"] as? [[String: Any]]) ?? []
            let seq = (json["seq"] as? Int) ?? 0
            lock.lock()
            if let sock = sockets[chatId] {
                if seq > sock.highestSeqSeen { sock.highestSeqSeen = seq }
                if let doId = json["doId"] as? String { sock.doId = doId }
                if let count = json["subscriberCount"] as? Int { sock.subscriberCount = count }
            }
            let listeners = Array(deltaListeners.values)
            lock.unlock()
            for cb in listeners {
                cb(chatId, actions, seq)
            }

        case "session.ack":
            guard let clientSeq = json["clientSeq"] as? String else { return }
            let seq = (json["seq"] as? Int) ?? 0
            lock.lock()
            let pending = sockets[chatId]?.pendingApplies.removeValue(forKey: clientSeq)
            if let sock = sockets[chatId], seq > sock.highestSeqSeen {
                sock.highestSeqSeen = seq
            }
            lock.unlock()
            if let pending {
                pending.timer.cancel()
                pending.continuation.resume(returning: seq)
            }

        case "session.error":
            let codeStr = json["code"] as? String ?? "internal"
            let code = SessionErrorCode(rawValue: codeStr) ?? .internal
            let message = json["message"] as? String ?? ""
            let targetChatId = json["chatId"] as? String ?? chatId
            emitError(chatId: targetChatId, code: code, message: message)
            // unauthorized/too_large means our last apply was rejected — fail
            // any pendings so the caller falls back to the POST endpoint.
            if code == .tooLarge || code == .unauthorized {
                rejectAllPending(
                    chatId: targetChatId,
                    error: SessionChannelError.server(code: code, message: message)
                )
            }

        default:
            return
        }
    }

    private func send(task: URLSessionWebSocketTask, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(text)) { _ in
            // didCloseWith handles failure paths.
        }
    }

    // MARK: Heartbeat / reconnect

    private func startHeartbeat(chatId: String) {
        lock.lock()
        guard let sock = sockets[chatId] else {
            lock.unlock()
            return
        }
        sock.heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        let interval = config.heartbeatIntervalMs
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            self?.heartbeatTick(chatId: chatId)
        }
        sock.heartbeatTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func heartbeatTick(chatId: String) {
        lock.lock()
        guard let sock = sockets[chatId], let task = sock.task else {
            lock.unlock()
            return
        }
        let elapsed = Date().timeIntervalSince(sock.lastPongAt) * 1000
        let staleThreshold = Double(config.heartbeatIntervalMs * 3)
        if elapsed > staleThreshold {
            lock.unlock()
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        lock.unlock()
        send(task: task, payload: ["type": "session.ping"])
    }

    private func teardownHeartbeat(_ sock: ChatSocket) {
        sock.heartbeatTimer?.cancel()
        sock.heartbeatTimer = nil
    }

    private func scheduleReconnect(chatId: String) {
        lock.lock()
        guard !disposed, let sock = sockets[chatId], sock.state != .disposed else {
            lock.unlock()
            return
        }
        if sock.reconnectAttempts >= config.maxReconnectAttempts {
            sock.state = .failed
            let attempts = config.maxReconnectAttempts
            lock.unlock()
            emitError(chatId: chatId, code: .internal, message: "Failed to reconnect after \(attempts) attempts")
            return
        }
        // 1s, 2s, 4s, … capped at 30s — mirrors RelayConnection / GuardianProcess.
        let attempt = sock.reconnectAttempts
        let delaySec = min(pow(2.0, Double(attempt)), 30.0)
        sock.reconnectAttempts += 1
        sock.state = .reconnecting

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + delaySec)
        timer.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.connect(chatId: chatId)
            }
        }
        sock.reconnectTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func teardown(_ sock: ChatSocket) {
        sock.state = .disposed
        sock.heartbeatTimer?.cancel()
        sock.heartbeatTimer = nil
        sock.reconnectTimer?.cancel()
        sock.reconnectTimer = nil

        // Reject pendings outside the per-sock lock domain — the continuation
        // resume calls don't need our state lock.
        let pendings = Array(sock.pendingApplies.values)
        sock.pendingApplies.removeAll()
        for pending in pendings {
            pending.timer.cancel()
            pending.continuation.resume(throwing: SessionChannelError.disposed)
        }

        sock.task?.cancel(with: .goingAway, reason: nil)
        sock.task = nil
        sock.session?.invalidateAndCancel()
        sock.session = nil
    }

    private func rejectAllPending(chatId: String, error: Error) {
        lock.lock()
        guard let sock = sockets[chatId] else {
            lock.unlock()
            return
        }
        let pendings = Array(sock.pendingApplies.values)
        sock.pendingApplies.removeAll()
        lock.unlock()
        for pending in pendings {
            pending.timer.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func emitError(chatId: String, code: SessionErrorCode, message: String) {
        lock.lock()
        let listeners = Array(errorListeners.values)
        lock.unlock()
        for cb in listeners {
            cb(chatId, code, message)
        }
    }

    private func toWsUrl(_ baseUrl: String) -> String {
        if baseUrl.hasPrefix("https://") {
            return "wss://" + baseUrl.dropFirst("https://".count)
        }
        if baseUrl.hasPrefix("http://") {
            return "ws://" + baseUrl.dropFirst("http://".count)
        }
        return baseUrl
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SessionChannelClient: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        guard let chatId = taskToChatId[ObjectIdentifier(webSocketTask)],
              let sock = sockets[chatId],
              sock.task === webSocketTask
        else {
            lock.unlock()
            return
        }
        sock.state = .connected
        sock.reconnectAttempts = 0
        sock.lastPongAt = Date()
        let highestSeq = sock.highestSeqSeen
        lock.unlock()

        startHeartbeat(chatId: chatId)

        // Fresh subscribe (highestSeq == 0) gets a snapshot; reconnect uses
        // sinceSeq for delta catch-up.
        var subscribeMsg: [String: Any] = ["type": "session.subscribe", "chatId": chatId]
        if highestSeq > 0 {
            subscribeMsg["sinceSeq"] = highestSeq
        }
        send(task: webSocketTask, payload: subscribeMsg)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleSocketClosed(task: webSocketTask)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // didCompleteWithError fires for both clean closes and errors — we
        // treat any task completion the same way: drop pendings, reconnect.
        if let wsTask = task as? URLSessionWebSocketTask {
            handleSocketClosed(task: wsTask)
        }
    }

    private func handleSocketClosed(task: URLSessionWebSocketTask) {
        lock.lock()
        guard let chatId = taskToChatId.removeValue(forKey: ObjectIdentifier(task)),
              let sock = sockets[chatId],
              sock.task === task
        else {
            lock.unlock()
            return
        }
        sock.heartbeatTimer?.cancel()
        sock.heartbeatTimer = nil
        sock.task = nil
        sock.session?.invalidateAndCancel()
        sock.session = nil

        let pendings = Array(sock.pendingApplies.values)
        sock.pendingApplies.removeAll()
        let stillSubscribed = !disposed && sock.state != .disposed
        lock.unlock()

        for pending in pendings {
            pending.timer.cancel()
            pending.continuation.resume(throwing: SessionChannelError.socketClosed)
        }

        if stillSubscribed {
            scheduleReconnect(chatId: chatId)
        }
    }
}

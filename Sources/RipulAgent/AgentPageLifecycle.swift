import Foundation
import WebKit
import os

/// A record of every page `AgentWebView` creates and shuts down.
///
/// A host's page is infrastructure: the relay, CLI sessions and tool calls run
/// in it. SwiftUI can replace it without anything saying so. On 2026-09-28 a Mac
/// host built a second page mid-session, nothing logged it, and tool calls went
/// to the first. Every creation and teardown is now counted and reported, with
/// the number of pages alive, so an unplanned one is visible when it happens.
@MainActor
public enum AgentPageLifecycle {
    public struct Event: Sendable {
        public enum Kind: String, Sendable { case created, retired }

        public let kind: Kind
        /// Order of creation in this process, from 1. Zero for a page retired
        /// without having been counted.
        public let page: Int
        /// Pages alive once this event has happened.
        public let livePages: Int
        /// Why, when the caller said so beforehand (`expectNextPage`). A page
        /// created with no reason after the first is an unplanned rebuild.
        public let reason: String?
        public let date: Date

        public var isUnplannedRebuild: Bool { kind == .created && page > 1 && reason == nil }

        public var summary: String {
            let cause = reason.map { "reason: \($0)" }
                ?? (kind == .created ? (page == 1 ? "reason: first page" : "reason: none given") : "")
            return ["page \(page) \(kind.rawValue)", "live pages: \(livePages)", cause]
                .filter { !$0.isEmpty }.joined(separator: "; ")
        }
    }

    /// Called on the main actor for every event, after the counts are updated.
    public static var observer: ((Event) -> Void)?

    public private(set) static var pagesCreated = 0
    public private(set) static var lastEvent: Event?
    public static var livePages: Int { live.count }

    private static var live: [ObjectIdentifier: Int] = [:]
    private static var expectedReason: String?
    private static let log = Logger(subsystem: "io.ripul.app", category: "AgentPage")

    /// Name the cause of the next page creation, e.g. a restart the host asked
    /// for. Used once.
    public static func expectNextPage(reason: String) {
        expectedReason = reason
    }

    /// For diagnostics endpoints.
    public static var snapshot: [String: Any] {
        var result: [String: Any] = ["live": livePages, "created": pagesCreated]
        if let lastEvent {
            result["lastEvent"] = lastEvent.summary
            result["lastEventAt"] = ISO8601DateFormatter().string(from: lastEvent.date)
        }
        return result
    }

    static func created(_ webView: WKWebView, bridge: AgentBridge?) {
        pagesCreated += 1
        live[ObjectIdentifier(webView)] = pagesCreated
        let reason = expectedReason
        expectedReason = nil
        report(Event(kind: .created, page: pagesCreated, livePages: livePages, reason: reason, date: Date()), bridge: bridge)
    }

    static func retired(_ webView: WKWebView, bridge: AgentBridge?) {
        let page = live.removeValue(forKey: ObjectIdentifier(webView)) ?? 0
        report(Event(kind: .retired, page: page, livePages: livePages, reason: nil, date: Date()), bridge: bridge)
    }

    private static func report(_ event: Event, bridge: AgentBridge?) {
        lastEvent = event
        let line = "[AgentPage] \(event.summary)"
        if event.isUnplannedRebuild {
            log.error("\(line, privacy: .public)")
            (bridge ?? AgentBridge.current)?.handleConsoleLog("WARN: \(line)")
        } else {
            log.notice("\(line, privacy: .public)")
            (bridge ?? AgentBridge.current)?.handleConsoleLog(line)
        }
        observer?(event)
    }
}

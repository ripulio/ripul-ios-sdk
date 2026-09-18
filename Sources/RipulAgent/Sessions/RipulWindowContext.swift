import SwiftUI
import WebKit

/// Navigation belongs to a scene; account and session catalogues can stay shared.
/// Hosts opt in by supplying this context. Embedded SDK screens remain single-window.
public final class RipulWindowContext: ObservableObject {
    public let id: UUID
    public let websiteDataStore: WKWebsiteDataStore
    public let storage: RipulWorkspaceStorage
    /// Used only while the restored session's selection callback runs.
    public var isRestoringSelection = false
    public var restoresPendingSession = false
    @Published public var pendingSessionID: String?
    @Published public var selectedSessionID: String? {
        didSet { storage.updateSelection { $0.sessionID = selectedSessionID } }
    }
    @Published public var title = "Ripul"
    @Published public var openWindow: ((String?) -> Void)?
    #if os(iOS)
    public weak var window: UIWindow?
    #endif

    public init(id: UUID, sessionID: String? = nil, websiteDataStore: WKWebsiteDataStore, storage: RipulWorkspaceStorage? = nil) {
        self.id = id
        self.storage = storage ?? RipulWorkspaceStorage(id: id)
        self.pendingSessionID = sessionID
        self.selectedSessionID = nil
        self.websiteDataStore = websiteDataStore
    }
}

private struct RipulWindowContextKey: EnvironmentKey {
    static let defaultValue: RipulWindowContext? = nil
}
public extension EnvironmentValues {
    var ripulWindowContext: RipulWindowContext? {
        get { self[RipulWindowContextKey.self] }
        set { self[RipulWindowContextKey.self] = newValue }
    }
}

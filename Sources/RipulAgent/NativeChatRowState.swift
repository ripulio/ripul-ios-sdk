import Combine
import Foundation
import SwiftUI

/// Per-row UI state registry for `NativeChatView`.
/// Keeps interactive layout state (disclosures, tool strip collapse/expansion,
/// progressive code/list reveal, tab selection, and unsent question answers)
/// stable when windowed rows unmount and later remount.
@available(iOS 16.0, macOS 14.0, *)
@MainActor
public final class NativeChatRowStateRegistry {
    public struct Key: Hashable {
        public let rowId: String
        public let componentId: String

        public init(rowId: String, componentId: String) {
            self.rowId = rowId
            self.componentId = componentId
        }
    }

    private struct Entry {
        var value: Any
        var access: UInt64
        var affectsHeight: Bool
    }

    private struct RevisionEntry {
        var revision: UInt64
        var access: UInt64
    }

    private struct StripSignature: Equatable {
        let chatId: String
        let groupId: String
        let updatedAt: Double
        let tools: [NativeToolStripItem]

        init(group: NativeChatToolGroup) {
            self.chatId = group.chatId
            self.groupId = group.id
            self.updatedAt = group.updatedAt
            self.tools = group.tools
        }
    }

    private struct StripCacheEntry {
        var store: NativeToolStripStore
        var signature: StripSignature
        var access: UInt64
    }

    #if os(iOS)
    private struct TaskRunCacheEntry {
        var state: NativeTaskRunState
        var access: UInt64
    }
    #endif

    private var entries: [Key: Entry] = [:]
    private var rowRevisions: [String: RevisionEntry] = [:]
    private var stripStores: [Key: StripCacheEntry] = [:]
    private var stripSubscriptions: [Key: AnyCancellable] = [:]
    #if os(iOS)
    private var taskRunStates: [Key: TaskRunCacheEntry] = [:]
    #endif
    private var clock: UInt64 = 0
    private var evictedRevisionFloor: UInt64 = 0
    private var isSyncingStrip = false
    private let maxEntries: Int

    /// Invoked whenever a height-affecting state value changes or is evicted for a row ID.
    public var onRowStateChanged: ((String) -> Void)?

    /// Process-lifetime set of saved secure-connection IDs so remounting a
    /// `NativeSecureConnectionToolView` never reverts to the unsaved button.
    public static var savedSecureConnectionIds: Set<String> = []

    var entryCount: Int { entries.count }
    var revisionCount: Int { rowRevisions.count }
    var stripStoreCount: Int { stripStores.count }
    var stripSubscriptionCount: Int { stripSubscriptions.count }
    #if os(iOS)
    var taskRunStateCount: Int { taskRunStates.count }
    #endif

    public init(maxEntries: Int = 4096) {
        self.maxEntries = max(1, maxEntries)
    }

    public func clear() {
        entries.removeAll()
        rowRevisions.removeAll()
        for (_, sub) in stripSubscriptions {
            sub.cancel()
        }
        stripSubscriptions.removeAll()
        for (_, entry) in stripStores {
            entry.store.hide()
        }
        stripStores.removeAll()
        #if os(iOS)
        taskRunStates.removeAll()
        #endif
        clock = 0
        evictedRevisionFloor = 0
    }

    public func value<Value>(
        forRow rowId: String,
        component componentId: String,
        default defaultValue: Value
    ) -> Value {
        guard !rowId.isEmpty else { return defaultValue }
        let key = Key(rowId: rowId, componentId: componentId)
        guard var hit = entries[key], let typed = hit.value as? Value else {
            return defaultValue
        }
        clock &+= 1
        hit.access = clock
        entries[key] = hit
        if var rev = rowRevisions[rowId] {
            rev.access = clock
            rowRevisions[rowId] = rev
        }
        return typed
    }

    @discardableResult
    public func setValue<Value: Equatable>(
        _ newValue: Value,
        forRow rowId: String,
        component componentId: String,
        default defaultValue: Value? = nil,
        affectsHeight: Bool = true
    ) -> Bool {
        guard !rowId.isEmpty else { return false }
        let key = Key(rowId: rowId, componentId: componentId)
        if let existing = entries[key]?.value as? Value {
            if existing == newValue {
                clock &+= 1
                entries[key]?.access = clock
                if var rev = rowRevisions[rowId] {
                    rev.access = clock
                    rowRevisions[rowId] = rev
                }
                return false
            }
        } else if let defaultValue, newValue == defaultValue {
            return false
        }
        clock &+= 1
        entries[key] = Entry(value: newValue, access: clock, affectsHeight: affectsHeight)
        if affectsHeight {
            bumpRevision(forRow: rowId)
        }
        evictEntriesIfNeeded()
        evictRevisionsIfNeeded()
        return true
    }

    public func revision(forRow rowId: String) -> UInt64 {
        guard !rowId.isEmpty else { return 0 }
        guard var hit = rowRevisions[rowId] else { return evictedRevisionFloor }
        clock &+= 1
        hit.access = clock
        rowRevisions[rowId] = hit
        return hit.revision
    }

    public func bumpRevision(forRow rowId: String) {
        guard !rowId.isEmpty else { return }
        clock &+= 1
        let base = max(rowRevisions[rowId]?.revision ?? 0, evictedRevisionFloor)
        let next = base &+ 1
        rowRevisions[rowId] = RevisionEntry(revision: next, access: clock)
        onRowStateChanged?(rowId)
    }

    func toolStripStore(forRow rowId: String, group: NativeChatToolGroup) -> NativeToolStripStore {
        let targetRowId = rowId.isEmpty ? group.id : rowId
        let key = Key(rowId: targetRowId, componentId: "strip:\(group.id)")
        let signature = StripSignature(group: group)
        if var existing = stripStores[key] {
            clock &+= 1
            existing.access = clock
            // If the group updated while the row was unmounted (`!isPresented`),
            // synchronize before returning so pass-1 layout sees the latest tools
            // without publishing on an actively mounted view body.
            if existing.signature != signature && !existing.store.isPresented {
                isSyncingStrip = true
                Self.syncToolStripStore(existing.store, with: group)
                isSyncingStrip = false
                existing.signature = signature
            }
            stripStores[key] = existing
            return existing.store
        }
        let store = NativeToolStripStore()
        // Populate before any SwiftUI view subscribes so pass-1 layout sees
        // the real tool lozenges and collapsed/expanded state.
        isSyncingStrip = true
        Self.syncToolStripStore(store, with: group)
        isSyncingStrip = false
        clock &+= 1
        stripStores[key] = StripCacheEntry(store: store, signature: signature, access: clock)
        stripSubscriptions[key] = store.$collapsed
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.isSyncingStrip else { return }
                self.bumpRevision(forRow: targetRowId)
                self.evictRevisionsIfNeeded()
            }
        evictStripStoresIfNeeded()
        evictRevisionsIfNeeded()
        return store
    }

    static func syncToolStripStore(_ store: NativeToolStripStore, with group: NativeChatToolGroup) {
        let toolsPayload: [[String: Any]] = group.tools.map { tool in
            var dict: [String: Any] = [
                "id": tool.id,
                "label": tool.label,
                "count": tool.count,
            ]
            if let r = tool.rendererName { dict["rendererName"] = r }
            if let s = tool.symbol { dict["symbol"] = s }
            if let st = tool.status { dict["status"] = st }
            if let da = tool.defaultAction {
                dict["defaultAction"] = ["id": da.id, "title": da.title]
            }
            return dict
        }
        store.receive([
            "ownerId": "native-chat",
            "chatId": group.chatId,
            "groupId": group.id,
            "updatedAt": group.updatedAt,
            "tools": toolsPayload,
        ])
    }

    #if os(iOS)
    func taskRunState(forRow rowId: String, item: NativeChatTaskRunItem) -> NativeTaskRunState {
        let targetRowId = rowId.isEmpty ? item.id : rowId
        let key = Key(rowId: targetRowId, componentId: "taskRun:\(item.id)")
        if var existing = taskRunStates[key] {
            clock &+= 1
            existing.access = clock
            if existing.state.snapshot == item.snapshot {
                taskRunStates[key] = existing
                return existing.state
            }
            // Snapshot changed while unmounted (or before onChange): replace with a
            // pre-seeded instance so pass-1 layout renders the latest snapshot
            // without firing ObservableObject.objectWillChange during body evaluation.
            let updatedState = NativeTaskRunState()
            updatedState.snapshot = item.snapshot
            updatedState.open = existing.state.open
            existing.state = updatedState
            taskRunStates[key] = existing
            return updatedState
        }
        let state = NativeTaskRunState()
        // Seed snapshot before any SwiftUI view subscribes so pass-1 layout has
        // the true task-run height instead of waiting for .onAppear.
        state.snapshot = item.snapshot
        clock &+= 1
        taskRunStates[key] = TaskRunCacheEntry(state: state, access: clock)
        evictTaskRunStatesIfNeeded()
        evictRevisionsIfNeeded()
        return state
    }
    #endif

    private var evictionTargetCount: Int {
        maxEntries < 10 ? maxEntries : max(1, maxEntries * 9 / 10)
    }

    private func evictEntriesIfNeeded() {
        guard entries.count > maxEntries else { return }
        let excess = entries.count - evictionTargetCount
        let oldest = entries
            .sorted { $0.value.access < $1.value.access }
            .prefix(excess)
        for (key, entry) in oldest {
            entries.removeValue(forKey: key)
            if entry.affectsHeight {
                bumpRevision(forRow: key.rowId)
            }
        }
    }

    private func evictStripStoresIfNeeded() {
        guard stripStores.count > maxEntries else { return }
        let excess = stripStores.count - evictionTargetCount
        let oldestKeys = stripStores
            .sorted { $0.value.access < $1.value.access }
            .prefix(excess)
            .map(\.key)
        for key in oldestKeys {
            if let sub = stripSubscriptions.removeValue(forKey: key) {
                sub.cancel()
            }
            if let removed = stripStores.removeValue(forKey: key) {
                removed.store.hide()
            }
            bumpRevision(forRow: key.rowId)
        }
    }

    #if os(iOS)
    private func evictTaskRunStatesIfNeeded() {
        guard taskRunStates.count > maxEntries else { return }
        let excess = taskRunStates.count - evictionTargetCount
        let oldestKeys = taskRunStates
            .sorted { $0.value.access < $1.value.access }
            .prefix(excess)
            .map(\.key)
        for key in oldestKeys {
            taskRunStates.removeValue(forKey: key)
            bumpRevision(forRow: key.rowId)
        }
    }
    #endif

    private func evictRevisionsIfNeeded() {
        guard rowRevisions.count > maxEntries else { return }
        let excess = rowRevisions.count - evictionTargetCount
        let oldestRowIds = rowRevisions
            .sorted { $0.value.access < $1.value.access }
            .prefix(excess)
            .map(\.key)
        for rowId in oldestRowIds {
            if let removed = rowRevisions.removeValue(forKey: rowId) {
                evictedRevisionFloor = max(evictedRevisionFloor, removed.revision)
            }
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatRowStateContext {
    weak var registry: NativeChatRowStateRegistry?
    var rowId: String = ""
    var scopePath: String = ""

    func scoped(_ childScope: String) -> NativeChatRowStateContext {
        guard !childScope.isEmpty else { return self }
        let nextScope = scopePath.isEmpty ? childScope : "\(scopePath)/\(childScope)"
        return NativeChatRowStateContext(registry: registry, rowId: rowId, scopePath: nextScope)
    }

    func scopedComponentId(_ componentId: String) -> String {
        scopePath.isEmpty ? componentId : "\(scopePath)/\(componentId)"
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatRowStateContextKey: EnvironmentKey {
    static var defaultValue: NativeChatRowStateContext { NativeChatRowStateContext() }
}

@available(iOS 16.0, macOS 14.0, *)
extension EnvironmentValues {
    var nativeChatRowStateContext: NativeChatRowStateContext {
        get { self[NativeChatRowStateContextKey.self] }
        set { self[NativeChatRowStateContextKey.self] = newValue }
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatRowStateScopeModifier: ViewModifier {
    let scope: String
    @Environment(\.nativeChatRowStateContext) private var context

    func body(content: Content) -> some View {
        content.environment(\.nativeChatRowStateContext, context.scoped(scope))
    }
}

@available(iOS 16.0, macOS 14.0, *)
extension View {
    func nativeChatRowStateRoot(registry: NativeChatRowStateRegistry?, rowId: String) -> some View {
        environment(
            \.nativeChatRowStateContext,
            NativeChatRowStateContext(registry: registry, rowId: rowId, scopePath: "")
        )
    }

    func nativeChatRowStateScope(_ scope: String) -> some View {
        modifier(NativeChatRowStateScopeModifier(scope: scope))
    }
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
final class NativeRowFallbackStore<Value: Equatable> {
    private var values: [String: Value] = [:]
    private(set) var revision: UInt64 = 0

    init() {}

    func value(forKey key: String, default defaultValue: Value) -> Value {
        values[key] ?? defaultValue
    }

    @discardableResult
    func setValue(_ newValue: Value, forKey key: String, default defaultValue: Value) -> Bool {
        let current = values[key] ?? defaultValue
        guard current != newValue else { return false }
        values[key] = newValue
        revision &+= 1
        return true
    }

    func recordExternalChange() {
        revision &+= 1
    }
}

/// Drop-in replacement for row-local `@State` that persists values in the
/// enclosing `NativeChatRowStateRegistry` across window unmount/remount cycles,
/// falling back to per-subscope local state when rendered outside a chat row (e.g. sheets).
@available(iOS 16.0, macOS 14.0, *)
@MainActor
@propertyWrapper
struct NativeRowState<Value: Equatable>: DynamicProperty {
    @Environment(\.nativeChatRowStateContext) private var context
    @State private var mountedFallbacks: [String: Value] = [:]
    @State private var localRevision: UInt64 = 0
    private let detachedStore = NativeRowFallbackStore<Value>()
    private let defaultValue: Value
    private let componentId: String
    private let affectsHeight: Bool

    init(wrappedValue: Value, _ componentId: String, affectsHeight: Bool = true) {
        self.defaultValue = wrappedValue
        self.componentId = componentId
        self.affectsHeight = affectsHeight
    }

    var wrappedValue: Value {
        get { value(subscope: nil) }
        nonmutating set { setValue(newValue, subscope: nil) }
    }

    var projectedValue: Binding<Value> {
        binding(subscope: nil)
    }

    var debugLocalRevision: UInt64 {
        max(localRevision, detachedStore.revision)
    }

    func value(subscope: String?) -> Value {
        _ = localRevision
        let key = resolvedKey(subscope: subscope)
        guard let registry = context.registry, !context.rowId.isEmpty else {
            if let mounted = mountedFallbacks[key] {
                return mounted
            }
            return detachedStore.value(forKey: key, default: defaultValue)
        }
        return registry.value(
            forRow: context.rowId,
            component: key,
            default: defaultValue
        )
    }

    func setValue(_ newValue: Value, subscope: String?) {
        let key = resolvedKey(subscope: subscope)
        let changed: Bool
        if let registry = context.registry, !context.rowId.isEmpty {
            _ = detachedStore.setValue(newValue, forKey: key, default: defaultValue)
            changed = registry.setValue(
                newValue,
                forRow: context.rowId,
                component: key,
                default: defaultValue,
                affectsHeight: affectsHeight
            )
            if changed {
                mountedFallbacks[key] = newValue
                localRevision &+= 1
            }
        } else {
            let current = mountedFallbacks[key] ?? detachedStore.value(forKey: key, default: defaultValue)
            changed = (current != newValue)
            _ = detachedStore.setValue(newValue, forKey: key, default: defaultValue)
            if changed {
                mountedFallbacks[key] = newValue
                localRevision &+= 1
            }
        }
    }

    func binding(subscope: String?) -> Binding<Value> {
        Binding(
            get: { value(subscope: subscope) },
            set: { setValue($0, subscope: subscope) }
        )
    }

    func resolvedKey(subscope: String?) -> String {
        let base = context.scopedComponentId(componentId)
        guard let subscope, !subscope.isEmpty else { return base }
        return "\(base):\(subscope)"
    }
}

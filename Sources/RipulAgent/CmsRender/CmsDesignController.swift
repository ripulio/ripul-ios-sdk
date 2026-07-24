import Foundation

/// Design-mode store: owns the CMS pages tree as RAW JSON while designing,
/// applies property edits in place (optimistic), and persists the whole
/// pages array with the web designer's 3 s debounce.
///
/// WHY RAW JSON: the typed `CmsPage`/`CmsBlock` models don't carry every
/// wire field (page `scriptIds`/`mobileBurgers`, block `description`/
/// `exportMode`, canvas `designWidth`, carousel settings, …). The save
/// endpoint REPLACES the pages array with what it receives — round-tripping
/// through the typed models would silently drop those fields. Editing the
/// raw tree mutates exactly one prop and leaves everything else
/// byte-identical; typed pages are decoded from the raw tree for rendering.
@MainActor
public final class CmsDesignController: ObservableObject {
    public enum SaveState: Equatable {
        case idle
        case dirty
        case saving
        case saved
        case failed(String)
    }

    /// Raw page objects (each a `.object`) — authoritative while designing.
    public private(set) var rawPages: [CmsJSON]

    @Published public private(set) var saveState: SaveState = .idle
    /// Bumped on every applied edit — inspector views re-read typed blocks.
    @Published public private(set) var revision = 0

    /// Called after `rawPages` changes so the loader can re-present the
    /// currently-rendered page (typed decode + shell/outlet refresh).
    public var onPagesDidChange: (() -> Void)?

    private let cmsId: String
    private let client: CmsClient
    /// Delegated (per-site) save path: the portal site key's PUBLISHABLE key.
    /// nil = owner/admin save path.
    private let delegatedSiteKey: String?
    private var saveTask: Task<Void, Never>?

    /// Mirror of the web designer's SAVE_DEBOUNCE_MS.
    private static let saveDebounceNs: UInt64 = 3_000_000_000

    public init(cmsId: String, client: CmsClient, rawPages: [CmsJSON], delegatedSiteKey: String? = nil) {
        self.cmsId = cmsId
        self.client = client
        self.rawPages = rawPages
        self.delegatedSiteKey = delegatedSiteKey
    }

    // MARK: - Typed views of the raw tree

    /// All pages decoded. A page that fails to decode is dropped from the
    /// RENDERED set only — its raw JSON still round-trips in the save.
    public var typedPages: [CmsPage] {
        rawPages.compactMap { Self.decode(CmsPage.self, from: $0) }
    }

    public func typedPage(id: String) -> CmsPage? {
        typedPages.first { $0.id == id }
    }

    /// Locate a block (typed) by id across every page — the inspector reads
    /// its subject through here so edits re-render on `revision`. Walks the
    /// raw tree (cheap key lookups) and decodes only the one block.
    public func block(_ blockId: String) -> CmsBlock? {
        for page in rawPages {
            guard let pageObj = page.objectValue, let blocks = pageObj["blocks"] else { continue }
            if let raw = Self.findRawBlock(id: blockId, in: blocks) {
                return Self.decode(CmsBlock.self, from: raw)
            }
        }
        return nil
    }

    /// Flat list of every block across all pages, in document order (depth-first).
    /// Includes nesting depth so callers can render indentation in pickers.
    public func allBlocks() -> [(block: CmsBlock, depth: Int)] {
        var result: [(block: CmsBlock, depth: Int)] = []
        for page in typedPages {
            guard let blocks = page.blocks else { continue }
            Self.collectBlocks(from: blocks, depth: 0, into: &result)
        }
        return result
    }

    private static func collectBlocks(from container: CmsPageBlocks, depth: Int, into result: inout [(block: CmsBlock, depth: Int)]) {
        switch container {
        case .list(let items, _), .canvas(let items, _, _, _), .carousel(let items, _):
            for item in items {
                result.append((item, depth))
                if let children = item.children {
                    collectBlocks(from: children, depth: depth + 1, into: &result)
                }
            }
        case .template(_, let slots, _), .sidebar(_, let slots, _):
            for (_, slot) in slots.sorted(by: { $0.key < $1.key }) {
                collectBlocks(from: slot, depth: depth, into: &result)
            }
        }
    }

    // MARK: - Edits

    /// Set (or remove, when nil) one prop on a block, anywhere in the pages
    /// tree. Applies to the raw tree, republishes, and schedules the
    /// debounced save — the native reading of the web designer's
    /// `updateBlockInContainer` + `flushSave`.
    public func setProp(blockId: String, key: String, value: CmsJSON?) {
        var changed = false
        rawPages = rawPages.map { page in
            guard !changed, var pageObj = page.objectValue,
                  let blocks = pageObj["blocks"] else { return page }
            if let updated = Self.updatingBlock(in: blocks, blockId: blockId, mutate: { obj in
                var props = obj["props"]?.objectValue ?? [:]
                if let value {
                    props[key] = value
                } else {
                    props.removeValue(forKey: key)
                }
                obj["props"] = .object(props)
            }) {
                pageObj["blocks"] = updated
                changed = true
                return .object(pageObj)
            }
            return page
        }
        guard changed else { return }
        revision += 1
        saveState = .dirty
        onPagesDidChange?()
        scheduleSave()
    }

    /// Set (or remove) block-level metadata — `hidden` and `visibleOn` —
    /// in the raw tree. Mirrors the web BlockPropertyPanel's
    /// `onBlockMetaChange`. Removing a key (nil value) keeps the JSON
    /// round-trip minimal, matching the web's "All" / unset convention.
    public func setBlockMeta(blockId: String, hidden: CmsJSON? = nil, visibleOn: CmsJSON? = nil) {
        var changed = false
        rawPages = rawPages.map { page in
            guard !changed, var pageObj = page.objectValue,
                  let blocks = pageObj["blocks"] else { return page }
            if let updated = Self.updatingBlock(in: blocks, blockId: blockId, mutate: { obj in
                if let hidden {
                    obj["hidden"] = hidden
                } else {
                    obj.removeValue(forKey: "hidden")
                }
                if let visibleOn {
                    obj["visibleOn"] = visibleOn
                } else {
                    obj.removeValue(forKey: "visibleOn")
                }
            }) {
                pageObj["blocks"] = updated
                changed = true
                return .object(pageObj)
            }
            return page
        }
        guard changed else { return }
        revision += 1
        saveState = .dirty
        onPagesDidChange?()
        scheduleSave()
    }

    // MARK: - Save

    /// Flush immediately — used by the design-mode toggle (exit) and the
    /// inspector's retry. Cancels any pending debounce.
    public func saveNow() async {
        saveTask?.cancel()
        guard saveState != .saving else { return }
        saveState = .saving
        do {
            if let siteKey = delegatedSiteKey {
                try await client.patchPortalDesign(cmsId: cmsId, siteKey: siteKey, pages: rawPages)
            } else {
                try await client.patchDefinitionPages(cmsId: cmsId, pages: rawPages)
            }
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNs)
            guard !Task.isCancelled, let self else { return }
            await self.saveNow()
        }
    }

    /// Write a prop edit into the persisted view definition in the
    /// gridViewSwitcher block, so the change survives when the user switches
    /// views and the switcher re-applies the saved snapshot. The in-memory
    /// patch (CmsRuntime.updateViewStateProp) handles immediate display;
    /// this handles persistence and server save.
    public func setPropInActiveViewState(
        gridSlug: String,
        activeViewId: String,
        key: String,
        value: CmsJSON?
    ) {
        var switcherBlockId: String?
        var views: [CmsJSON]?
        for page in rawPages {
            guard let pageObj = page.objectValue, let blocks = pageObj["blocks"] else { continue }
            if let result = Self.findSwitcherBlock(targetingGrid: gridSlug, in: blocks) {
                switcherBlockId = result.id
                views = result.views
                break
            }
        }
        guard let switcherBlockId, var views else { return }
        guard let viewIdx = views.firstIndex(where: {
            $0.objectValue?["id"]?.stringValue == activeViewId
        }) else { return }
        var viewObj = views[viewIdx].objectValue ?? [:]
        var state = viewObj["state"]?.objectValue ?? [:]
        if let value { state[key] = value } else { state.removeValue(forKey: key) }
        viewObj["state"] = .object(state)
        views[viewIdx] = .object(viewObj)
        setProp(blockId: switcherBlockId, key: "views", value: .array(views))
    }

    // MARK: - Raw-tree walking

    /// Walk the page tree looking for the gridViewSwitcher block that targets
    /// `gridSlug`. Returns its id + the raw `views` array so the caller can
    /// patch a specific view's state and re-save.
    private static func findSwitcherBlock(
        targetingGrid gridSlug: String,
        in container: CmsJSON
    ) -> (id: String, views: [CmsJSON])? {
        guard let obj = container.objectValue else { return nil }
        if let items = obj["items"]?.arrayValue {
            for item in items {
                guard case .object(let blockObj) = item else { continue }
                if blockObj["type"]?.stringValue == "gridViewSwitcher",
                   let id = blockObj["id"]?.stringValue {
                    let props = blockObj["props"]?.objectValue ?? [:]
                    if props["targetGridId"]?.stringValue == gridSlug,
                       let views = props["views"]?.arrayValue {
                        return (id: id, views: views)
                    }
                }
                if let children = blockObj["children"],
                   let found = findSwitcherBlock(targetingGrid: gridSlug, in: children) {
                    return found
                }
            }
        }
        if let slots = obj["slots"]?.objectValue {
            for slot in slots.values {
                if let found = findSwitcherBlock(targetingGrid: gridSlug, in: slot) {
                    return found
                }
            }
        }
        return nil
    }

    /// Decode a typed model from a raw JSON subtree (encode-then-decode —
    /// page-scale subtrees, once per edit, never per frame).
    static func decode<T: Decodable>(_ type: T.Type, from json: CmsJSON) -> T? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Find a block by id in a typed container, recursing into block
    /// children and template/sidebar slots.
    static func findBlock(id: String, in container: CmsPageBlocks) -> CmsBlock? {
        switch container {
        case .list(let items, _), .canvas(let items, _, _, _), .carousel(let items, _):
            for item in items {
                if item.id == id { return item }
                if let children = item.children, let found = findBlock(id: id, in: children) {
                    return found
                }
            }
        case .template(_, let slots, _), .sidebar(_, let slots, _):
            for slot in slots.values {
                if let found = findBlock(id: id, in: slot) { return found }
            }
        }
        return nil
    }

    /// Find a block's raw object by id in a raw container — same traversal
    /// as `updatingBlock`, read-only.
    static func findRawBlock(id: String, in container: CmsJSON) -> CmsJSON? {
        guard let obj = container.objectValue else { return nil }
        if let items = obj["items"]?.arrayValue {
            for item in items {
                guard case .object(let blockObj) = item else { continue }
                if blockObj["id"]?.stringValue == id { return item }
                if let children = blockObj["children"],
                   let found = findRawBlock(id: id, in: children) {
                    return found
                }
            }
        }
        if let slots = obj["slots"]?.objectValue {
            for slot in slots.values {
                if let found = findRawBlock(id: id, in: slot) { return found }
            }
        }
        return nil
    }

    /// Returns a copy of the container JSON with `mutate` applied to the
    /// block object whose id matches, or nil when the block isn't inside.
    /// Walks `items` arrays (list/canvas/carousel), `children` containers,
    /// and `slots` objects (template/sidebar) — every place a block can live.
    static func updatingBlock(
        in container: CmsJSON,
        blockId: String,
        mutate: (inout [String: CmsJSON]) -> Void
    ) -> CmsJSON? {
        guard var obj = container.objectValue else { return nil }
        if let items = obj["items"]?.arrayValue {
            var newItems = items
            for index in items.indices {
                guard case .object(var blockObj) = items[index] else { continue }
                if blockObj["id"]?.stringValue == blockId {
                    mutate(&blockObj)
                    newItems[index] = .object(blockObj)
                    obj["items"] = .array(newItems)
                    return .object(obj)
                }
                if let children = blockObj["children"],
                   let updatedChildren = updatingBlock(in: children, blockId: blockId, mutate: mutate) {
                    blockObj["children"] = updatedChildren
                    newItems[index] = .object(blockObj)
                    obj["items"] = .array(newItems)
                    return .object(obj)
                }
            }
        }
        if let slots = obj["slots"]?.objectValue {
            for (key, slotContainer) in slots {
                if let updated = updatingBlock(in: slotContainer, blockId: blockId, mutate: mutate) {
                    var newSlots = slots
                    newSlots[key] = updated
                    obj["slots"] = .object(newSlots)
                    return .object(obj)
                }
            }
        }
        return nil
    }
}

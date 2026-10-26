import Foundation
import CoreGraphics

/// Pure geometry/data model. Coordinates exclude outer chat chrome and padding.
/// Revisions come from exact row equality in the adapter, never a persisted hash.
struct NativeChatWindowModel {
    struct LayoutKey: Hashable {
        let width: CGFloat
        var scale: CGFloat = 1
        var textMetrics: String = "default"
        var styleRevision: Int = 0
        var rightToLeft: Bool = false
    }
    enum Confidence { case estimated, mounted }
    struct Descriptor: Equatable {
        let id: String
        let revision: UInt64
        let kind: String
        var estimate: CGFloat = 100
    }
    struct HeightKey: Hashable {
        let id: String
        let revision: UInt64
        let layout: LayoutKey
    }
    struct HeightEntry {
        let height: CGFloat
        let confidence: Confidence
        fileprivate var access: UInt64
    }
    enum Direction { case stationary, up, down }
    /// Reserved for the fallback integration; the model never writes scroll offsets.
    enum CorrectionMode { case immediate, deferUntilRest }
    struct Configuration {
        var spacing: CGFloat = 10
        var overscan: CGFloat = 1
        var fastOverscan: CGFloat = 2
        var triggerMargin: CGFloat = 0.5
        var chunk: Int = 4
        var softCap: Int = 32
        var hardCap: Int = 48
        var cacheLimit: Int = 4096
    }
    struct Plan: Equatable {
        let generation: UInt64
        let structureGeneration: UInt64
        let range: Range<Int>
        let top: CGFloat
        let bottom: CGFloat
        let totalHeight: CGFloat
        let mandatory: Range<Int>
        let exceedsCap: Bool
    }
    private(set) var descriptors: [Descriptor] = []
    private(set) var heights: [CGFloat] = []
    /// P[k] includes only layout slots and their trailing gaps. No-slot rows add nothing.
    private(set) var prefix: [CGFloat] = [0]
    private(set) var layout: LayoutKey
    private(set) var generation: UInt64 = 0
    private(set) var structureGeneration: UInt64 = 0
    private var indexByID: [String: Int] = [:]
    private var noSlot: Set<HeightKey> = []
    private var activeIndices: [Int] = []
    private var slotCounts: [Int] = [0]
    private(set) var cache: [HeightKey: HeightEntry] = [:]
    let configuration: Configuration
    private var clock: UInt64 = 0
    private var samples: [String: [CGFloat]] = [:]
    private(set) var correctionMode: CorrectionMode = .immediate

    init(layout: LayoutKey, configuration: Configuration = Configuration()) {
        precondition(layout.width.isFinite && layout.width > 0)
        precondition(layout.scale.isFinite && layout.scale > 0)
        precondition(configuration.spacing >= 0 && configuration.chunk > 0)
        precondition(configuration.softCap > 0 && configuration.hardCap >= configuration.softCap)
        precondition(configuration.cacheLimit > 0)
        self.layout = layout
        self.configuration = configuration
    }

    mutating func setCorrectionMode(_ mode: CorrectionMode) { correctionMode = mode }

    mutating func update(_ rows: [Descriptor], layout: LayoutKey? = nil) {
        precondition(Set(rows.map(\.id)).count == rows.count, "Row IDs must be unique")
        if let layout {
            precondition(layout.width.isFinite && layout.width > 0 && layout.scale.isFinite && layout.scale > 0)
            if self.layout != layout { samples.removeAll() }
            self.layout = layout
        }
        if descriptors.map(\.id) != rows.map(\.id) { structureGeneration &+= 1 }
        descriptors = rows
        indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        noSlot = noSlot.filter { key in
            key.layout == self.layout && indexByID[key.id].map { rows[$0].revision == key.revision } == true
        }
        rebuild()
    }

    /// Resize keeps distant rows at their previous heights as provisional estimates.
    /// Only newly mounted measurements should move their ledger coordinates.
    mutating func changeLayoutPreservingEstimates(_ layout: LayoutKey) {
        guard self.layout != layout else { return }
        let previous = heights
        self.layout = layout
        samples.removeAll()
        noSlot.removeAll()
        for (index, row) in descriptors.enumerated() {
            clock &+= 1
            cache[key(for: row)] = HeightEntry(height: previous[index], confidence: .estimated, access: clock)
        }
        rebuild()
    }

    func key(for row: Descriptor) -> HeightKey {
        HeightKey(id: row.id, revision: row.revision, layout: layout)
    }

    /// Reject delayed measurements from a different content/layout generation.
    @discardableResult
    mutating func measure(_ height: CGFloat, for key: HeightKey) -> Bool {
        measure([(key, height)]) == 1
    }

    /// One geometry generation should arrive as one batch: O(batch + N), not N per row.
    /// The return value counts accepted entries, including unchanged measurements.
    @discardableResult
    mutating func measure(_ batch: [(HeightKey, CGFloat)]) -> Int {
        var accepted = 0
        var changed = false
        for (key, height) in batch {
            guard height.isFinite, height >= 0, isCurrent(key), let index = indexByID[key.id] else { continue }
            accepted += 1
            clock &+= 1
            let previous = cache[key]
            let wasEmpty = noSlot.remove(key) != nil
            cache[key] = HeightEntry(height: height, confidence: .mounted, access: clock)
            guard previous?.height != height || previous?.confidence != .mounted || wasEmpty else { continue }
            changed = true
            let kind = descriptors[index].kind
            if samples[kind] == nil && samples.count >= 32 { samples.removeAll() }
            var values = samples[kind, default: []]
            values.append(height)
            if values.count > 31 { values.removeFirst(values.count - 31) }
            samples[kind] = values
        }
        if changed { rebuild() } else { evict() }
        return accepted
    }

    private func isCurrent(_ key: HeightKey) -> Bool {
        key.layout == layout && indexByID[key.id].map { descriptors[$0].revision == key.revision } == true
    }

    /// Only report absent slots after a complete mounted layout batch, never merely
    /// because an offscreen row has no marker. A measured zero-height slot is distinct.
    mutating func setNoSlot(_ keys: [HeightKey]) {
        var changed = false
        for key in keys where isCurrent(key) {
            if noSlot.insert(key).inserted { changed = true }
        }
        if changed { rebuild() }
    }

    func hasSlot(at index: Int) -> Bool { !noSlot.contains(key(for: descriptors[index])) }

    private mutating func rebuild() {
        // Compute each median once. Old-revision mounted heights are provisional
        // estimates for the same ID/layout, not evidence the new content was measured.
        let medians = samples.mapValues { values -> CGFloat in
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        var lastMeasured: [String: HeightEntry] = [:]
        for (key, entry) in cache where key.layout == layout && entry.confidence == .mounted {
            if lastMeasured[key.id].map({ $0.access < entry.access }) ?? true { lastMeasured[key.id] = entry }
        }
        heights = descriptors.map { row in
            let key = key(for: row)
            if noSlot.contains(key) { return 0 }
            clock &+= 1
            if var hit = cache[key] {
                hit.access = clock
                cache[key] = hit
                return hit.height
            }
            let estimate = lastMeasured[row.id]?.height ?? medians[row.kind] ?? row.estimate
            let safe = estimate.isFinite ? max(0, estimate) : 100
            cache[key] = HeightEntry(height: safe, confidence: .estimated, access: clock)
            return safe
        }
        prefix = [0]
        slotCounts = [0]
        activeIndices = []
        for (index, height) in heights.enumerated() {
            let hasSlot = hasSlot(at: index)
            if hasSlot { activeIndices.append(index) }
            prefix.append(prefix.last! + (hasSlot ? height + configuration.spacing : 0))
            slotCounts.append(slotCounts.last! + (hasSlot ? 1 : 0))
        }
        generation &+= 1
        evict()
    }

    private mutating func evict() {
        guard cache.count > configuration.cacheLimit else { return }
        let target = max(1, configuration.cacheLimit * 9 / 10)
        let excess = cache.count - target
        let oldest = cache.sorted { $0.value.access < $1.value.access }.prefix(excess).map(\.key)
        for key in oldest { cache.removeValue(forKey: key) }
    }

    var totalHeight: CGFloat { activeIndices.isEmpty ? 0 : prefix.last! - configuration.spacing }

    /// Exact fillers for a spacing:0 section enclosing a spacing:s mounted stack.
    func geometry(for range: Range<Int>, mandatory: Range<Int> = 0..<0) -> Plan {
        precondition(range.lowerBound >= 0 && range.upperBound <= descriptors.count)
        precondition(!range.isEmpty || descriptors.isEmpty)
        let slots = slotCounts[range.upperBound] - slotCounts[range.lowerBound]
        let top = range.isEmpty ? 0 : min(totalHeight, prefix[range.lowerBound])
        let bottom = slots == 0 ? totalHeight - top : max(0, totalHeight - (prefix[range.upperBound] - configuration.spacing))
        return Plan(generation: generation, structureGeneration: structureGeneration, range: range, top: top, bottom: bottom,
                    totalHeight: totalHeight, mandatory: mandatory,
                    exceedsCap: range.count > configuration.hardCap)
    }

    /// First row whose maxY is strictly greater than y (gaps belong to the next row).
    func firstRow(after y: CGFloat) -> Int {
        var low = 0
        var high = activeIndices.count
        while low < high {
            let mid = (low + high) / 2
            let index = activeIndices[mid]
            if prefix[index] + heights[index] > y { high = mid } else { low = mid + 1 }
        }
        return low < activeIndices.count ? activeIndices[low] : heights.count
    }

    private func intersecting(_ viewport: Range<CGFloat>) -> Range<Int> {
        guard !heights.isEmpty else { return 0..<0 }
        let start = min(heights.count - 1, firstRow(after: viewport.lowerBound))
        var low = start
        var high = heights.count
        while low < high {
            let mid = (low + high) / 2
            if prefix[mid] < viewport.upperBound { low = mid + 1 } else { high = mid }
        }
        return start..<max(start + 1, low)
    }

    func plan(viewport: Range<CGFloat>, current: Plan? = nil,
              direction: Direction = .stationary, fast: Bool = false,
              targetID: String? = nil) -> Plan {
        guard !heights.isEmpty else { return geometry(for: 0..<0) }
        let screen = max(1, viewport.upperBound - viewport.lowerBound)
        var visible = viewport
        if let targetID, let index = indexByID[targetID] {
            let center = prefix[index] + heights[index] / 2
            visible = (center - screen / 2)..<(center + screen / 2)
        }
        let mandatory = intersecting(visible)
        if targetID == nil, let current, current.structureGeneration == structureGeneration,
           current.range.lowerBound <= mandatory.lowerBound, current.range.upperBound >= mandatory.upperBound {
            let topSafe = current.range.lowerBound == 0 || visible.lowerBound - prefix[current.range.lowerBound] >= screen * configuration.triggerMargin
            let endY = min(totalHeight, prefix[current.range.upperBound] - configuration.spacing)
            let bottomSafe = current.range.upperBound == heights.count || endY - visible.upperBound >= screen * configuration.triggerMargin
            if topSafe && bottomSafe { return geometry(for: current.range, mandatory: mandatory) }
        }
        let before = fast && direction == .up ? configuration.fastOverscan : configuration.overscan
        let after = fast && direction == .down ? configuration.fastOverscan : configuration.overscan
        let desired = intersecting((visible.lowerBound - screen * before)..<(visible.upperBound + screen * after))
        let chunk = configuration.chunk
        var lower = (desired.lowerBound / chunk) * chunk
        var upper = min(heights.count, ((desired.upperBound + chunk - 1) / chunk) * chunk)
        // Cap only overscan, never rows actually needed for the viewport.
        // Soft cap is preferred; fast travel may use the hard cap.
        let cap = max(mandatory.count, fast ? configuration.hardCap : configuration.softCap)
        while upper - lower > cap {
            let left = mandatory.lowerBound - lower
            let right = upper - mandatory.upperBound
            if left > 0 && (right == 0 || (direction == .down ? left >= right / 2 : direction == .up ? left > right * 2 : left > right)) { lower += 1 }
            else if right > 0 { upper -= 1 }
            else { break }
        }
        return geometry(for: lower..<upper, mandatory: mandatory)
    }
}

/// Adapter helper: exact equality drives revisions, including nested message fields.
struct NativeChatRowRevisionTracker<Value: Equatable> {
    private var previous: [String: (Value, UInt64)] = [:]
    private var serial: UInt64 = 0
    mutating func revisions(for values: [(id: String, value: Value)]) -> [UInt64] {
        var next: [String: (Value, UInt64)] = [:]
        let revisions = values.map { item -> UInt64 in
            let revision: UInt64
            if let old = previous[item.id], old.0 == item.value { revision = old.1 }
            else { serial &+= 1; revision = serial }
            next[item.id] = (item.value, revision)
            return revision
        }
        previous = next
        return revisions
    }
}

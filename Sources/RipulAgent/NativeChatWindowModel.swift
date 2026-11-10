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
    private var lastMeasuredByLayout: [LayoutKey: [String: HeightEntry]] = [:]
    let configuration: Configuration
    private var clock: UInt64 = 0
    private var samples: [String: [CGFloat]] = [:]
    private var cachedMedians: [String: CGFloat] = [:]
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
        if let layout {
            precondition(layout.width.isFinite && layout.width > 0 && layout.scale.isFinite && layout.scale > 0)
            if self.layout != layout {
                samples.removeAll()
                cachedMedians.removeAll()
            }
            self.layout = layout
        }
        if NativeChatPerformance.isEnabled(.incrementalRows) {
            let sameIDs = descriptors.count == rows.count && zip(descriptors, rows).allSatisfy { $0.id == $1.id }
            if !sameIDs {
                precondition(Set(rows.map(\.id)).count == rows.count, "Row IDs must be unique")
                structureGeneration &+= 1
                indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            }
            descriptors = rows
            if !noSlot.isEmpty {
                noSlot = noSlot.filter { key in
                    key.layout == self.layout && indexByID[key.id].map { rows[$0].revision == key.revision } == true
                }
            }
        } else {
            precondition(Set(rows.map(\.id)).count == rows.count, "Row IDs must be unique")
            if descriptors.map(\.id) != rows.map(\.id) { structureGeneration &+= 1 }
            descriptors = rows
            indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            noSlot = noSlot.filter { key in
                key.layout == self.layout && indexByID[key.id].map { rows[$0].revision == key.revision } == true
            }
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
        cachedMedians.removeAll()
        noSlot.removeAll()
        for (index, row) in descriptors.enumerated() {
            clock &+= 1
            let key = key(for: row)
            let replaced = cache.updateValue(HeightEntry(height: previous[index], confidence: .estimated, access: clock), forKey: key)
            if let replaced { forgetMeasuredEntry(key, entry: replaced) }
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
            let entry = HeightEntry(height: height, confidence: .mounted, access: clock)
            cache[key] = entry
            lastMeasuredByLayout[key.layout, default: [:]][key.id] = entry
            guard previous?.height != height || previous?.confidence != .mounted || wasEmpty else { continue }
            changed = true
            let kind = descriptors[index].kind
            if samples[kind] == nil && samples.count >= 32 {
                samples.removeAll()
                cachedMedians.removeAll()
            }
            var values = samples[kind, default: []]
            values.append(height)
            if values.count > 31 { values.removeFirst(values.count - 31) }
            samples[kind] = values
            let sorted = values.sorted()
            cachedMedians[kind] = sorted[sorted.count / 2]
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

    /// The row's current height was measured while mounted, not estimated.
    func isMeasured(_ index: Int) -> Bool { cache[key(for: descriptors[index])]?.confidence == .mounted }

    private mutating func rebuild() {
        let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
        let medians: [String: CGFloat]
        let lastMeasured: [String: HeightEntry]?
        if incremental {
            // Old-revision mounted heights are provisional estimates for the same ID/layout,
            // not evidence the new content was measured. Iterate rows O(M), not the 4096 cache.
            lastMeasured = lastMeasuredByLayout[layout]
            medians = cachedMedians
        } else {
            medians = samples.mapValues { values -> CGFloat in
                let sorted = values.sorted()
                return sorted[sorted.count / 2]
            }
            var scanned: [String: HeightEntry] = [:]
            for (key, entry) in cache where key.layout == layout && entry.confidence == .mounted {
                if scanned[key.id].map({ $0.access < entry.access }) ?? true { scanned[key.id] = entry }
            }
            lastMeasured = scanned
        }
        heights = descriptors.map { row in
            let key = key(for: row)
            if noSlot.contains(key) { return 0 }
            clock &+= 1
            if var hit = cache[key] {
                hit.access = clock
                cache[key] = hit
                // The secondary index uses access to identify an evicted entry.
                // Keep it in step with LRU touches, not just measurements.
                if hit.confidence == .mounted {
                    lastMeasuredByLayout[key.layout, default: [:]][key.id] = hit
                }
                return hit.height
            }
            let estimate = lastMeasured?[row.id]?.height ?? medians[row.kind] ?? row.estimate
            let safe = estimate.isFinite ? max(0, estimate) : 100
            cache[key] = HeightEntry(height: safe, confidence: .estimated, access: clock)
            return safe
        }
        prefix = [0]
        prefix.reserveCapacity(heights.count + 1)
        slotCounts = [0]
        slotCounts.reserveCapacity(heights.count + 1)
        activeIndices = []
        activeIndices.reserveCapacity(heights.count)
        let hasAnyNoSlot = !noSlot.isEmpty
        for (index, height) in heights.enumerated() {
            let hasSlot = incremental ? (!hasAnyNoSlot || self.hasSlot(at: index)) : self.hasSlot(at: index)
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
        let oldest = cache.sorted { $0.value.access < $1.value.access }.prefix(excess)
        for (key, evictedEntry) in oldest {
            cache.removeValue(forKey: key)
            forgetMeasuredEntry(key, entry: evictedEntry)
        }
    }

    /// Called after a cache entry is removed or replaced by a resize estimate.
    private mutating func forgetMeasuredEntry(_ key: HeightKey, entry: HeightEntry) {
        guard entry.confidence == .mounted,
              lastMeasuredByLayout[key.layout]?[key.id]?.access == entry.access else { return }
        lastMeasuredByLayout[key.layout]?.removeValue(forKey: key.id)
        for (remainingKey, remainingEntry) in cache where remainingKey.layout == key.layout && remainingKey.id == key.id && remainingEntry.confidence == .mounted {
            if lastMeasuredByLayout[key.layout]?[key.id].map({ $0.access < remainingEntry.access }) ?? true {
                lastMeasuredByLayout[key.layout, default: [:]][key.id] = remainingEntry
            }
        }
        if lastMeasuredByLayout[key.layout]?.isEmpty == true {
            lastMeasuredByLayout.removeValue(forKey: key.layout)
        }
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

    /// While a finger or a coast moves the view the band holds still: mounting rows
    /// mid-fling is what dropped frames (27 Oct 2026, Duo: 2–5 band moves a fling lost
    /// 75–173 ms; the same chat with every row mounted lost about 8 ms a fling). Keep
    /// `current`, extending only the edge the view travels toward, only once the
    /// viewport comes within `margin` screens of it, and then `reach` screens ahead
    /// in one change of at most `step` rows (a row still on an estimate counts twice).
    /// Rows behind stay mounted up to `cap` (the rest band's size, so a long fling
    /// never mounts more than streaming is measured with); past it the farthest go,
    /// already measured, in the same publication. A viewport that has left the band
    /// (a jump, not a scroll) gets a fresh plan.
    func motionPlan(viewport: Range<CGFloat>, current: Plan, direction: Direction,
                    margin: CGFloat = 0.5, reach: CGFloat = 2, step: Int = 24, cap: Int = 64) -> Plan {
        guard !heights.isEmpty, current.structureGeneration == structureGeneration,
              current.range.upperBound <= heights.count, !current.range.isEmpty else {
            return plan(viewport: viewport, direction: direction)
        }
        let screen = max(1, viewport.upperBound - viewport.lowerBound)
        let mandatory = intersecting(viewport)
        var lower = current.range.lowerBound
        var upper = current.range.upperBound
        guard mandatory.upperBound + configuration.chunk >= lower, mandatory.lowerBound <= upper + configuration.chunk else {
            return plan(viewport: viewport, direction: direction)
        }
        // Hysteresis: nothing changes until the screen comes within `margin` screens of
        // the leading edge; then that edge moves `reach` screens ahead in one change.
        // Every band change costs about a frame, whatever its size (Duo, 27 Oct 2026: a
        // few rows at a time made 78 changes in six fast flings), but mounting costs per
        // row too. So `reach` bounds a change by height, and `step` by rows: a row still
        // on an estimate counts twice, since its real height (a long answer with tables)
        // may be several screens. With no direction yet (a chat just shown) nothing grows.
        let near = intersecting((viewport.lowerBound - screen * margin)..<(viewport.upperBound + screen * margin))
        let far = intersecting((viewport.lowerBound - screen * reach)..<(viewport.upperBound + screen * reach))
        if direction == .up, near.lowerBound < lower {
            let goal = min(far.lowerBound, near.lowerBound)
            var budget = step
            while lower > goal, budget > 0 {
                lower -= 1
                budget -= isMeasured(lower) ? 1 : 2
            }
        }
        if direction == .down, near.upperBound > upper {
            let goal = max(far.upperBound, near.upperBound)
            var budget = step
            while upper < goal, budget > 0 {
                budget -= isMeasured(upper) ? 1 : 2
                upper += 1
            }
        }
        lower = min(lower, mandatory.lowerBound)
        upper = max(upper, mandatory.upperBound)
        // Over the cap, only what grew is exchanged: a band larger than the cap
        // (kept across a landing) is never cut down in bulk mid-fling.
        let grew = (current.range.lowerBound - lower) + (upper - current.range.upperBound)
        let over = (upper - lower) - max(cap, mandatory.count)
        if grew > 0, over > 0 {
            let cut = min(grew, over)
            if direction == .up { upper = max(mandatory.upperBound, upper - cut) }
            else { lower = min(mandatory.lowerBound, lower + cut) }
        }
        return geometry(for: lower..<upper, mandatory: mandatory)
    }

    /// The band to grow toward at rest: `ahead` screens on the side the view was
    /// travelling toward and `behind` on the side it came from, at most `cap` rows
    /// (the rows on screen always count), shared between the sides in that ratio.
    func restPlan(viewport: Range<CGFloat>, direction: Direction,
                  ahead: CGFloat = 3, behind: CGFloat = 2, cap: Int = 64) -> Plan {
        guard !heights.isEmpty else { return geometry(for: 0..<0) }
        let screen = max(1, viewport.upperBound - viewport.lowerBound)
        let above = direction == .up ? ahead : direction == .down ? behind : (ahead + behind) / 2
        let below = direction == .down ? ahead : direction == .up ? behind : (ahead + behind) / 2
        let mandatory = intersecting(viewport)
        let desired = intersecting((viewport.lowerBound - screen * above)..<(viewport.upperBound + screen * below))
        var lower = min(desired.lowerBound, mandatory.lowerBound)
        var upper = max(desired.upperBound, mandatory.upperBound)
        let spare = max(cap, mandatory.count) - mandatory.count
        if upper - lower > mandatory.count + spare {
            let aboveShare = Int((CGFloat(spare) * above / (above + below)).rounded())
            let trimmedLower = max(lower, mandatory.lowerBound - aboveShare)
            upper = min(upper, mandatory.upperBound + spare - (mandatory.lowerBound - trimmedLower))
            // A side with fewer rows than its share gives the rest to the other.
            lower = max(lower, mandatory.lowerBound - (spare - (upper - mandatory.upperBound)))
        }
        return geometry(for: lower..<upper, mandatory: mandatory)
    }

    /// One step at rest from `current` toward `target`: at most `step` rows next to
    /// the band, on the side ahead first. Once `current` covers `target`, the rows
    /// beyond it go, at most `trimStep` a step, from the side with more to lose. Nil
    /// when there is nothing left to do.
    func growthStep(current: Range<Int>, target: Plan, direction: Direction, step: Int = 4, trimStep: Int = 16) -> Plan? {
        guard current.upperBound <= heights.count, !current.isEmpty,
              current.lowerBound <= target.range.upperBound, target.range.lowerBound <= current.upperBound else { return target }
        var lower = current.lowerBound
        var upper = current.upperBound
        var budget = step
        for side in direction == .down ? [1, 0] : [0, 1] where budget > 0 {
            if side == 0, target.range.lowerBound < lower {
                let add = min(budget, lower - target.range.lowerBound)
                lower -= add
                budget -= add
            } else if side == 1, target.range.upperBound > upper {
                let add = min(budget, target.range.upperBound - upper)
                upper += add
                budget -= add
            }
        }
        // Never larger than the band was or the target is: what grows on one side comes
        // off the other side's rows beyond the target in the same step, so an
        // interrupted growth leaves no oversized band behind.
        var over = (upper - lower) - max(current.count, target.range.count)
        if over > 0, upper > target.range.upperBound {
            let cut = min(over, upper - target.range.upperBound)
            upper -= cut
            over -= cut
        }
        if over > 0, lower < target.range.lowerBound {
            lower += min(over, target.range.lowerBound - lower)
        }
        if budget < step { return geometry(for: lower..<upper, mandatory: target.mandatory) }
        guard current != target.range else { return nil }
        // Only rows beyond the target are left: a grown band shrinks over several steps,
        // so no one frame unmounts a hundred rows (a message sent into a grown chat).
        var cut = trimStep
        while cut > 0, lower < target.range.lowerBound || upper > target.range.upperBound {
            if upper - target.range.upperBound >= target.range.lowerBound - lower { upper -= 1 } else { lower += 1 }
            cut -= 1
        }
        return geometry(for: lower..<upper, mandatory: target.mandatory)
    }
}

/// Adapter helper: exact equality drives revisions, including nested message fields.
struct NativeChatRowRevisionTracker<Value: Equatable> {
    private var previous: [String: (Value, UInt64)] = [:]
    private var serial: UInt64 = 0
    mutating func revisions(for values: [(id: String, value: Value)], dirtyIDs: Set<String>? = nil) -> [UInt64] {
        var next: [String: (Value, UInt64)] = [:]
        next.reserveCapacity(values.count)
        let revisions = values.map { item -> UInt64 in
            let revision: UInt64
            if let old = previous[item.id] {
                if let dirtyIDs, !dirtyIDs.contains(item.id) {
                    revision = old.1
                } else if old.0 == item.value {
                    revision = old.1
                } else {
                    serial &+= 1
                    revision = serial
                }
            } else {
                serial &+= 1
                revision = serial
            }
            next[item.id] = (item.value, revision)
            return revision
        }
        previous = next
        return revisions
    }
}

extension NativeChatRowRevisionTracker where Value: Identifiable, Value.ID == String {
    mutating func revisions(for values: [Value], dirtyIDs: Set<String>? = nil) -> [UInt64] {
        var next: [String: (Value, UInt64)] = [:]
        next.reserveCapacity(values.count)
        let revisions = values.map { item -> UInt64 in
            let id = item.id
            let revision: UInt64
            if let old = previous[id] {
                if let dirtyIDs, !dirtyIDs.contains(id) {
                    revision = old.1
                } else if old.0 == item {
                    revision = old.1
                } else {
                    serial &+= 1
                    revision = serial
                }
            } else {
                serial &+= 1
                revision = serial
            }
            next[id] = (item, revision)
            return revision
        }
        previous = next
        return revisions
    }
}

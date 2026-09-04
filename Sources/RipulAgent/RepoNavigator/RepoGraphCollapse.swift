import Foundation

/// Collapses long contiguous runs of "boring" commits into a single marker
/// row, so the graph's structure (merges, branch-offs, ref tips) isn't
/// drowned by linear stretches.
///
/// A row is eligible only when it is *structurally invisible*:
/// - exactly one parent (not a merge, not a root),
/// - no ref decorations (no branch/tag/HEAD pills),
/// - not the HEAD commit,
/// - no top or bottom segments — RepoGraphLayout emits segments exactly when
///   a lane starts, ends, curves in, or curves out, so empty segments mean
///   "plain node on an uninterrupted vertical". Collapse can therefore never
///   hide geometry.
///
/// Runs longer than `threshold` keep `edgeKeep` rows at both ends for
/// context; the middle becomes one `.collapsed` item carrying the lanes that
/// pass through it (identical across the run — ineligibility conditions make
/// lane changes impossible inside a run).
public enum RepoGraphItem: Sendable, Identifiable {
    case row(RepoGraphLayout.Row)
    case collapsed(CollapsedRun)

    public var id: String {
        switch self {
        case .row(let row): return row.commit.sha
        case .collapsed(let run): return run.id
        }
    }
}

public struct CollapsedRun: Sendable, Identifiable, Hashable {
    /// Stable identity: the first hidden commit's sha. Window growth (load
    /// more) reshapes runs, so identity is best-effort — acceptable for
    /// view-local expansion state.
    public let id: String
    /// Number of hidden commits (0 on the re-collapse handle).
    public let count: Int
    /// Lanes flowing through the marker (drawn dashed).
    public let lanes: [RepoGraphLayout.LaneRef]
    /// The lane the run's nodes sit on — where the marker glyph goes.
    public let nodeLane: Int
    public let nodeLaneId: Int
    /// True when the run is expanded: the marker stays in place as the
    /// collapse toggle, with the run's rows following it.
    public let isReCollapseHandle: Bool

    public init(id: String, count: Int, lanes: [RepoGraphLayout.LaneRef], nodeLane: Int, nodeLaneId: Int, isReCollapseHandle: Bool = false) {
        self.id = id
        self.count = count
        self.lanes = lanes
        self.nodeLane = nodeLane
        self.nodeLaneId = nodeLaneId
        self.isReCollapseHandle = isReCollapseHandle
    }
}

public enum RepoGraphCollapse {

    /// - threshold: runs strictly longer than this collapse. Default 9.
    /// - edgeKeep: rows kept visible at each end of a collapsed run.
    public static func items(
        rows: [RepoGraphLayout.Row],
        headSha: String?,
        expanded: Set<String> = [],
        threshold: Int = 9,
        edgeKeep: Int = 2
    ) -> [RepoGraphItem] {
        var items: [RepoGraphItem] = []
        var index = 0

        while index < rows.count {
            guard isCollapsible(rows[index], headSha: headSha) else {
                items.append(.row(rows[index]))
                index += 1
                continue
            }

            // Gather the full run.
            var runEnd = index
            while runEnd < rows.count && isCollapsible(rows[runEnd], headSha: headSha) {
                runEnd += 1
            }
            let run = rows[index..<runEnd]

            if run.count > threshold {
                let head = run.prefix(edgeKeep)
                let tail = run.suffix(edgeKeep)
                let middle = run.dropFirst(edgeKeep).dropLast(edgeKeep)
                items.append(contentsOf: head.map { .row($0) })
                let marker = CollapsedRun(
                    id: "collapse-\(middle.first!.commit.sha)",
                    count: middle.count,
                    lanes: middle.first!.verticals,
                    nodeLane: middle.first!.nodeLane,
                    nodeLaneId: middle.first!.nodeLaneId
                )
                if expanded.contains(marker.id) {
                    // The marker STAYS in place as the collapse toggle —
                    // without it, re-collapsing a long expansion meant
                    // scrolling to its foot.
                    items.append(.collapsed(CollapsedRun(
                        id: marker.id,
                        count: marker.count,
                        lanes: marker.lanes,
                        nodeLane: marker.nodeLane,
                        nodeLaneId: marker.nodeLaneId,
                        isReCollapseHandle: true
                    )))
                    items.append(contentsOf: middle.map { .row($0) })
                } else {
                    items.append(.collapsed(marker))
                }
                items.append(contentsOf: tail.map { .row($0) })
            } else {
                items.append(contentsOf: run.map { .row($0) })
            }
            index = runEnd
        }

        return items
    }

    private static func isCollapsible(_ row: RepoGraphLayout.Row, headSha: String?) -> Bool {
        guard row.commit.sha != headSha else { return false }
        guard row.commit.parents.count == 1 else { return false }
        guard row.commit.refs.isEmpty else { return false }
        guard row.topSegments.isEmpty && row.bottomSegments.isEmpty else { return false }
        return true
    }
}

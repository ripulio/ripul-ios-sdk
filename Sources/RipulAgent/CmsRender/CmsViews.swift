import Foundation

// MARK: - Views: one set of rows from several sources (docs/plans/cms-cards.md §1)
//
// A view has a base query (its rows, in its order) and named sources whose
// columns join each row under the source's alias (`estimate.net`). The server
// does every join and streams the answer: the base rows first, then each
// source's results as they finish. To a block, a view is a query: its slug
// works wherever a query's does, and its rows carry `alias.column` keys.

/// A saved view (`CmsDefinition.views`), decoded leniently.
public struct CmsViewDef: Codable, Equatable {
    public struct Source: Codable, Equatable {
        public var alias: String
        /// Matched through an existing query relationship from the base.
        public var relationship: String?
        /// Matched (`match`) or per row (`perRow`): the source's saved query.
        public var query: String?
        public var match: [String: String]?
        public var perRow: [String: CmsJSON]?

        /// Per-row sources are the ones whose rows past the first 20 come back `later`.
        public var isPerRow: Bool { perRow != nil }
    }

    public var slug: String
    public var name: String?
    public var base: String
    public var key: String
    public var sources: [Source]?

    var isUsable: Bool { !slug.isEmpty && !base.isEmpty && !key.isEmpty }

    /// Every saved query the view reads: its base and each source's query.
    public var queries: Set<String> {
        var out: Set<String> = [base]
        for s in sources ?? [] {
            if let q = s.query { out.insert(q) }
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient: a view missing its slug, base or key decodes empty and is
        // left out when the definition loads (`isUsable`), never failing it.
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        base = (try? c.decode(String.self, forKey: .base)) ?? ""
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        sources = (try? c.decodeIfPresent([CmsJSON].self, forKey: .sources))?.compactMap { raw in
            guard let o = raw.objectValue, let alias = o.string("alias"), !alias.isEmpty else { return nil }
            var match: [String: String]?
            if let m = o.object("match"), let b = m.string("base"), let s = m.string("source") {
                match = ["base": b, "source": s]
            }
            return Source(alias: alias, relationship: o.string("relationship"), query: o.string("query"),
                          match: match, perRow: o.object("perRow"))
        }
    }
}

/// One source's state for one view row.
public enum CmsViewSourceStatus: Equatable {
    /// No answer yet.
    case pending
    case ready
    case failed(String)
    /// Past the rows per-row sources run for: asked for as the row comes into view.
    case later
}

/// One line of the view route's stream (`application/x-ndjson`).
enum CmsViewEvent: Equatable {
    struct Result: Equatable {
        var key: String
        var status: CmsViewSourceStatus
        /// nil: the source has no row for this key (its columns stay empty).
        var row: [String: CmsJSON]?
    }

    case base(rows: [[String: CmsJSON]], schema: [CmsQueryResultColumn], key: String, later: [String])
    case source(alias: String, results: [Result])
    case end
    case error(String)

    /// One parsed line. Unknown or broken lines are nil (skipped).
    static func parse(_ json: CmsJSON) -> CmsViewEvent? {
        guard let o = json.objectValue else { return nil }
        switch o.string("type") {
        case "base":
            let rows = (o["rows"]?.arrayValue ?? []).compactMap(\.objectValue)
            let schema = (o["schema"]?.arrayValue ?? []).compactMap { c -> CmsQueryResultColumn? in
                guard let co = c.objectValue, let name = co.string("name") else { return nil }
                return CmsQueryResultColumn(name: name, type: co.string("type"))
            }
            return .base(rows: rows, schema: schema, key: o.string("key") ?? "",
                         later: (o["later"]?.arrayValue ?? []).map(\.displayString))
        case "source":
            guard let alias = o.string("alias") else { return nil }
            let results = (o["results"]?.arrayValue ?? []).compactMap { r -> Result? in
                guard let ro = r.objectValue, let key = ro["key"].map(\.displayString) else { return nil }
                let status: CmsViewSourceStatus
                switch ro.string("status") {
                case "ready": status = .ready
                case "failed": status = .failed(ro.string("error") ?? "Couldn't load this")
                case "later": status = .later
                default: status = .pending
                }
                return Result(key: key, status: status, row: ro.object("row"))
            }
            return .source(alias: alias, results: results)
        case "end":
            return .end
        case "error":
            return .error(o.string("error") ?? "The view failed")
        default:
            return nil
        }
    }

    static func parse(line: Substring) -> CmsViewEvent? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let json = try? JSONDecoder().decode(CmsJSON.self, from: Data(text.utf8)) else { return nil }
        return parse(json)
    }

    /// The answer without streaming (`{ ok, rows, schema, key, later, sources }`)
    /// as the same events, so one path reads both.
    static func events(fromWhole json: CmsJSON) -> [CmsViewEvent] {
        guard let o = json.objectValue else { return [.error("The view's answer couldn't be read")] }
        if o.bool("ok") == false { return [.error(o.string("error") ?? "The view failed")] }
        var out: [CmsViewEvent] = []
        if let base = parse(.object(o.merging(["type": .string("base")]) { _, new in new })) { out.append(base) }
        for (alias, perKey) in o.object("sources") ?? [:] {
            let results: [CmsJSON] = (perKey.objectValue ?? [:]).map { key, entry in
                var r = entry.objectValue ?? [:]
                r["key"] = .string(key)
                return .object(r)
            }
            if let event = parse(.object(["type": .string("source"), "alias": .string(alias), "results": .array(results)])) {
                out.append(event)
            }
        }
        out.append(.end)
        return out
    }
}

/// A view's rows and each row's source statuses, built up as its events arrive.
struct CmsViewResult: Equatable {
    var rows: [[String: CmsJSON]] = []
    var schema: [CmsQueryResultColumn] = []
    var key: String = ""
    /// Row key → alias → status.
    var status: [String: [String: CmsViewSourceStatus]] = [:]
    var failed: String?
    var ended = false

    func rowKey(_ row: [String: CmsJSON]) -> String? {
        row[key].flatMap { $0 == .null ? nil : $0.displayString }
    }

    /// Applies one event. `view` names the sources (to mark the per-row ones
    /// `later` for the keys the base listed).
    mutating func apply(_ event: CmsViewEvent, view: CmsViewDef) {
        switch event {
        case .base(let rows, let schema, let key, let later):
            self.rows = rows
            self.schema = schema
            self.key = key.isEmpty ? view.key : key
            let laterKeys = Set(later)
            var status: [String: [String: CmsViewSourceStatus]] = [:]
            for row in rows {
                guard let k = rowKey(row) else { continue }
                var perSource: [String: CmsViewSourceStatus] = [:]
                for source in view.sources ?? [] {
                    perSource[source.alias] = source.isPerRow && laterKeys.contains(k) ? .later : .pending
                }
                status[k] = perSource
            }
            self.status = status
        case .source(let alias, let results):
            merge(alias: alias, results: results)
        case .end:
            ended = true
        case .error(let message):
            failed = message
        }
    }

    /// A source's results into their rows, as `alias.column` keys. A ready
    /// result with no row clears that source's columns.
    mutating func merge(alias: String, results: [CmsViewEvent.Result]) {
        var index: [String: Int] = [:]
        for (i, row) in rows.enumerated() {
            if let k = rowKey(row), index[k] == nil { index[k] = i }
        }
        let prefix = alias + "."
        for result in results {
            status[result.key, default: [:]][alias] = result.status
            guard result.status == .ready, let i = index[result.key] else { continue }
            for k in rows[i].keys where k.hasPrefix(prefix) { rows[i][k] = nil }
            for (column, value) in result.row ?? [:] { rows[i][prefix + column] = value }
        }
    }

    /// A source's status for a row; `ready` for a row or alias the view doesn't know.
    func status(row: [String: CmsJSON], alias: String) -> CmsViewSourceStatus {
        guard let k = rowKey(row) else { return .ready }
        return status[k]?[alias] ?? .ready
    }

    init(key: String = "") { self.key = key }

    /// Marks every source still `pending` as failed (the stream ended without
    /// it), for every row or only `keys`.
    mutating func failRemainingPending(_ message: String, keys: Set<String>? = nil) {
        for (rowKey, statuses) in status where keys?.contains(rowKey) ?? true {
            for (alias, s) in statuses where s == .pending { status[rowKey]?[alias] = .failed(message) }
        }
    }

    /// Keys of rows waiting to be asked for (`later` for some source).
    var laterKeys: [String] {
        rows.compactMap { row in
            guard let k = rowKey(row), status[k]?.values.contains(.later) == true else { return nil }
            return k
        }
    }
}

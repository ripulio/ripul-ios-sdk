import Foundation
import RipulLiveActivity
#if os(iOS)
import SwiftUI
#endif
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// A running record declared on a mutation's `action.after.activity`: the
/// query whose first row is the record running now, and the elapsedTimer
/// block's fields for its time. While the query has a row, the app keeps a
/// Live Activity for it; when the row goes, the activity ends. Any mutation
/// that changes the query (WAC in, a break, WAC out) is reflected, wherever
/// it ran, because the runtime refetches the query after it.
///
///     after: { activity: { query: "running_shift", title: "{job}",
///              subtitle: "WAC'd in at {wac_in_at|HH:mm}", start: "wac_in_at",
///              minusSeconds: "live.break_seconds", pausedAt: "live.break_started_at",
///              label: "Worked", pausedLabel: "On break", open: { page: "shift_now" } } }
struct CmsRunningRecordSpec: Equatable {
    var query: String
    var key: String
    var title: String
    var subtitle: String?
    var timer: CmsElapsedTimer
    var openPage: String?

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let query = o.string("query"), !query.isEmpty,
              let start = o.string("start"), !start.isEmpty else { return nil }
        self.query = query
        key = o.string("key").flatMap { $0.isEmpty ? nil : $0 } ?? "id"
        title = o.string("title") ?? ""
        subtitle = o.string("subtitle").flatMap { $0.isEmpty ? nil : $0 }
        var props: [String: CmsJSON] = ["querySlug": .string(query), "start": .string(start)]
        for k in ["minusSeconds", "pausedAt", "label", "pausedLabel"] { if let v = o[k] { props[k] = v } }
        timer = CmsElapsedTimer(props)
        openPage = o.object("open")?.string("page")
    }

    /// Every spec the site's mutations declare, one per query.
    static func all(_ mutations: [String: CmsMutationDef]) -> [CmsRunningRecordSpec] {
        var seen = Set<String>()
        return mutations.keys.sorted().compactMap { slug in
            guard let after = mutations[slug]?.action?.after?.objectValue,
                  let spec = CmsRunningRecordSpec(after["activity"]), seen.insert(spec.query).inserted else { return nil }
            return spec
        }
    }

    /// A row's values as a template's `{path}` reads them: a view's `alias.column`
    /// keys are also nested, so `{live.break_seconds}` finds either form.
    static func run(_ row: [String: CmsJSON]) -> CmsJSON {
        var out = row
        for (k, v) in row where k.contains(".") {
            let parts = k.split(separator: ".", maxSplits: 1).map(String.init)
            var inner = out[parts[0]]?.objectValue ?? [:]
            if inner[parts[1]] == nil { inner[parts[1]] = v }
            out[parts[0]] = .object(inner)
        }
        return .object(out)
    }

    /// The row's key, as text.
    func recordKey(_ row: [String: CmsJSON]) -> String? {
        switch row[key] {
        case .string(let s)?: return s
        case .number(let n)?: return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    /// What the activity shows for a row, from the elapsedTimer block's rules:
    /// running counts from the start plus finished pauses; paused counts the pause.
    func content(_ row: [String: CmsJSON]?, offsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60) -> (title: String, state: CmsRunningActivityState)? {
        guard let row, let start = timer.start, let started = CmsElapsedTimer.time(row[start]) else { return nil }
        let run = Self.run(row)
        let title = CmsMutationAfter.fill(title, run: run, offsetMinutes: offsetMinutes).text
        let subtitle = subtitle.map { CmsMutationAfter.fill($0, run: run, offsetMinutes: offsetMinutes) }.flatMap { $0.missing ? nil : $0.text }
        if let pausedAt = timer.pausedAt, let paused = CmsElapsedTimer.time(row[pausedAt]) {
            return (title, CmsRunningActivityState(timerStart: paused, paused: true, label: timer.pausedLabel ?? "Paused", subtitle: subtitle))
        }
        var minus = 0.0
        if let m = timer.minusSeconds {
            switch row[m] {
            case .number(let n)?: minus = n
            case .string(let t)?: minus = Double(t) ?? 0
            default: break
            }
        }
        return (title, CmsRunningActivityState(timerStart: started.addingTimeInterval(minus), paused: false, label: timer.label ?? "", subtitle: subtitle))
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// The link a tap on the activity opens: `<the app's first URL scheme>://ripul-page/<slug>`,
/// which `CmsAppController.handle(url:)` opens. Nil when the app declares no scheme.
enum CmsRunningActivityLink {
    static func url(page: String?) -> String? {
        guard let page,
              let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              let scheme = types.lazy.compactMap({ ($0["CFBundleURLSchemes"] as? [String])?.first }).first else { return nil }
        return "\(scheme)://ripul-page/\(page)"
    }
}

/// Keeps each declared running record's Live Activity in step with its query.
struct CmsRunningActivitySync: ViewModifier {
    @ObservedObject var runtime: CmsRuntime

    private var specs: [CmsRunningRecordSpec] { CmsRunningRecordSpec.all(runtime.mutationDefs) }

    /// What each spec's query says now; nil while it loads (nothing changes then).
    private var snapshot: [String: SyncKey?] {
        var out: [String: SyncKey?] = [:]
        for spec in specs {
            guard case .ok(let result) = runtime.state(for: spec.query) else { continue }
            let row = result.rows.first
            // updateValue: a subscript's nil would remove the key, and "no row" must end the activity.
            out.updateValue(row.flatMap { r in spec.content(r).map { SyncKey(key: spec.recordKey(r) ?? "", title: $0.title, state: $0.state) } }, forKey: spec.query)
        }
        return out
    }

    struct SyncKey: Equatable { var key: String; var title: String; var state: CmsRunningActivityState }

    func body(content: Content) -> some View {
        content
            .task(id: specs.map(\.query)) {
                for spec in specs { runtime.ensureLoaded(spec.query) }
            }
            .onChange(of: snapshot) { now in
                for spec in specs { if let entry = now[spec.query] { sync(spec, entry) } }
            }
    }

    private func sync(_ spec: CmsRunningRecordSpec, _ entry: SyncKey?) {
        let siteId = runtime.cmsId
        let mine = Activity<CmsRunningActivityAttributes>.activities.filter { $0.attributes.siteId == siteId && $0.attributes.query == spec.query }
        Task {
            for activity in mine where activity.attributes.recordKey != entry?.key {
                await activity.end(nil, dismissalPolicy: .immediate)
                CmsFeatureLog.logger.notice("running record activity ended (\(spec.query, privacy: .public))")
            }
            guard let entry else { return }
            if let current = mine.first(where: { $0.attributes.recordKey == entry.key }) {
                if current.content.state != entry.state {
                    await current.update(ActivityContent(state: entry.state, staleDate: nil))
                    CmsFeatureLog.logger.notice("running record activity updated (\(spec.query, privacy: .public), \(entry.state.paused ? "paused" : "running", privacy: .public))")
                }
                return
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = CmsRunningActivityAttributes(
                siteId: siteId, query: spec.query, recordKey: entry.key, title: entry.title,
                accentHex: runtime.themeConfig?.palette?.primary,
                url: CmsRunningActivityLink.url(page: spec.openPage))
            do {
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: entry.state, staleDate: nil), pushType: nil)
                CmsFeatureLog.logger.notice("running record activity started (\(spec.query, privacy: .public))")
            } catch {
                CmsFeatureLog.logger.error("running record activity refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#elseif os(iOS)
/// Mac Catalyst has no Live Activities: the same modifier, doing nothing, so
/// `CmsAppView` reads the same on the Mac as on the iPhone.
struct CmsRunningActivitySync: ViewModifier {
    @ObservedObject var runtime: CmsRuntime

    func body(content: Content) -> some View { content }
}
#endif

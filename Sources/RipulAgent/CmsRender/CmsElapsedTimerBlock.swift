import SwiftUI

/// The `elapsedTimer` block natively (CmsElapsedTimer.swift has the rules): a
/// live time counting up from a column of a query's or view's first row,
/// ticking once a second while it shows (`TimelineView`; nothing ticks when
/// there is no row). WAC's running-shift timer is one configuration of it.
struct CmsElapsedTimerBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    private var timer: CmsElapsedTimer { CmsElapsedTimer(runtime.resolvedProps(for: block)) }

    private var row: [String: CmsJSON]? {
        guard let slug = timer.querySlug, case .ok(let result) = runtime.state(for: slug) else { return nil }
        return result.rows.first
    }

    @State private var lastForeground = Date.distantPast

    /// The query's state: a failure or a first load is not "nothing running".
    private var queryState: CmsRuntime.QueryState? { timer.querySlug.map { runtime.state(for: $0) } }

    var body: some View {
        let timer = self.timer
        let row = self.row
        Group {
            if case .error? = queryState {
                // A failed check: say so, with Try again, never emptyText ("You're not WAC'd in").
                VStack(spacing: 8) {
                    Text("Couldn’t check just now.")
                        .font(.ripul(.body))
                        .foregroundStyle(.ripul(.textSecondary))
                    Button("Try again") { if let slug = timer.querySlug { runtime.invalidate(slug) } }
                        .buttonStyle(.bordered)
                        .cmsInspectorID("Cms.elapsedTimer.retry")
                }
            } else if row == nil, !isLoaded {
                // Still loading for the first time: no empty text yet.
                Color.clear.frame(height: 96)
            } else if row != nil, timer.start != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    face(timer.state(row: row, now: context.date), centred: timer.centred)
                }
            } else {
                face(timer.state(row: nil, now: .now), centred: timer.centred)
            }
        }
        .frame(maxWidth: .infinity, alignment: timer.centred ? .center : .leading)
        .padding(.vertical, 8)
        .onAppear { if let slug = timer.querySlug { runtime.ensureLoaded(slug) } }
        #if os(iOS)
        // A shift started elsewhere shows when the app comes back, as WAC's app re-reads on foreground.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard let slug = timer.querySlug, Date().timeIntervalSince(lastForeground) >= CmsElapsedTimer.foregroundRefetch else { return }
            lastForeground = Date()
            runtime.invalidate(slug)
        }
        #endif
        .cmsInspectorID("Cms.elapsedTimer")
    }

    private var isLoaded: Bool {
        if case .ok? = queryState { return true }
        return timer.querySlug == nil
    }

    @ViewBuilder
    private func face(_ s: CmsElapsedTimer.State, centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 2) {
            if s.mode == .empty {
                Text(s.label)
                    .font(.ripul(.body))
                    .foregroundStyle(.ripul(.textSecondary))
            } else {
                if !s.label.isEmpty {
                    Text(s.label.uppercased())
                        .font(.ripul(.caption))
                        .fontWeight(.semibold)
                        .foregroundStyle(s.mode == .paused ? AnyShapeStyle(runtime.theme.color(role: .accent)) : AnyShapeStyle(.ripul(.textSecondary)))
                }
                Text(s.main)
                    .font(.system(size: 64, weight: .bold).monospacedDigit())
                    .foregroundStyle(.ripul(.text))
                    .contentTransition(.numericText())
                if !s.sub.isEmpty {
                    Text(s.sub)
                        .font(.ripul(.subheadline).monospacedDigit())
                        .foregroundStyle(.ripul(.textSecondary))
                }
            }
        }
        .multilineTextAlignment(centred ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

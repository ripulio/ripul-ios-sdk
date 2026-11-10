import Foundation
// Live Activities are the iPhone's: Mac Catalyst has none (ActivityAttributes is unavailable there).
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit
#endif

/// A running record on the Lock Screen and in the Dynamic Island: a CMS
/// site's shift, visit or job that counts up while it runs (WAC's Live
/// Activity after WAC in). The SDK's runtime starts, updates and ends it from
/// the site's `action.after.activity` (CmsRunningActivitySync in RipulAgent);
/// a host app's widget extension draws it with `CmsRunningActivityWidget`.
///
/// A library of its own, with no dependencies, so a widget extension links
/// this and not the whole agent stack.
public struct CmsRunningActivityState: Codable, Hashable, Sendable {
    /// The time the timer counts from: the start plus finished pauses while
    /// running, or the pause's own start while paused (as the elapsedTimer block).
    public var timerStart: Date
    public var paused: Bool
    /// "Worked", "On break": over the timer.
    public var label: String
    public var subtitle: String?

    public init(timerStart: Date, paused: Bool, label: String, subtitle: String?) {
        self.timerStart = timerStart
        self.paused = paused
        self.label = label
        self.subtitle = subtitle
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
public struct CmsRunningActivityAttributes: ActivityAttributes {
    public typealias ContentState = CmsRunningActivityState

    /// The site and the query whose row this is, and the row's key.
    public var siteId: String
    public var query: String
    public var recordKey: String
    public var title: String
    /// The site's primary colour, as #RRGGBB.
    public var accentHex: String?
    /// Opened when the activity is tapped (the host app's link to the record's page).
    public var url: String?

    public init(siteId: String, query: String, recordKey: String, title: String, accentHex: String?, url: String?) {
        self.siteId = siteId
        self.query = query
        self.recordKey = recordKey
        self.title = title
        self.accentHex = accentHex
        self.url = url
    }
}

/// The ready-made widget: a host's widget extension lists it in its bundle.
///
///     @main struct Widgets: WidgetBundle {
///         var body: some Widget { CmsRunningActivityWidget() }
///     }
public struct CmsRunningActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: CmsRunningActivityAttributes.self) { context in
            CmsRunningActivityLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(nil)
                .widgetURL(context.attributes.url.flatMap(URL.init(string:)))
        } dynamicIsland: { context in
            let accent = Color(cmsHex: context.attributes.accentHex) ?? .accentColor
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.label).font(.caption).foregroundStyle(.secondary)
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CmsRunningActivityTimer(state: context.state)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.paused ? Color.orange : accent) // theme-exempt: the site's colour, and the system's pause colour, in a widget
                        .frame(maxWidth: 110, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let subtitle = context.state.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.circle.fill" : "timer")
                    .foregroundStyle(context.state.paused ? Color.orange : accent) // theme-exempt: the site's colour in a widget
            } compactTrailing: {
                CmsRunningActivityTimer(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.circle.fill" : "timer")
                    .foregroundStyle(context.state.paused ? Color.orange : accent) // theme-exempt: the site's colour in a widget
            }
            .widgetURL(context.attributes.url.flatMap(URL.init(string:)))
            .keylineTint(accent)
        }
    }
}

/// The time since `timerStart`, ticked by the system: the app never wakes for it.
public struct CmsRunningActivityTimer: View {
    let state: CmsRunningActivityState
    public init(state: CmsRunningActivityState) { self.state = state }

    public var body: some View {
        Text(timerInterval: state.timerStart...state.timerStart.addingTimeInterval(7 * 24 * 3600), countsDown: false, showsHours: true)
            .multilineTextAlignment(.trailing)
    }
}

/// The Lock Screen's banner: the label and title on the left, the time on the right.
public struct CmsRunningActivityLockScreen: View {
    let attributes: CmsRunningActivityAttributes
    let state: CmsRunningActivityState

    public init(attributes: CmsRunningActivityAttributes, state: CmsRunningActivityState) {
        self.attributes = attributes
        self.state = state
    }

    public var body: some View {
        let accent = Color(cmsHex: attributes.accentHex) ?? .accentColor
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.paused ? "pause.circle.fill" : "timer")
                .font(.title2)
                .foregroundStyle(state.paused ? Color.orange : accent) // theme-exempt: the site's colour in a widget
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label).font(.caption).foregroundStyle(.secondary)
                Text(attributes.title).font(.headline).lineLimit(1)
                if let subtitle = state.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            CmsRunningActivityTimer(state: state)
                .font(.title.weight(.semibold).monospacedDigit())
                .frame(maxWidth: 140, alignment: .trailing)
        }
        .padding(16)
    }
}

extension Color {
    /// #RRGGBB or RRGGBB.
    init?(cmsHex: String?) {
        guard var s = cmsHex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255) // theme-exempt: the site's own colour, carried into a widget
    }
}
#endif

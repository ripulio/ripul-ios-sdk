import Foundation

/// A task's own row in a chat: a workflow run (its phase, a mark for every
/// agent and the agents at work) or a sub-agent (its type, what it has cost
/// and the last things it did), each with a clock. The web app works out the
/// words (`chrome-extension/src/taskRuns/chatTaskRuns.ts`) and sends them as
/// the embed's snapshot; this draws them.
struct NativeTaskRunSnapshot: Equatable {
  /// Which task the row is for. It is the renderer the web asked for
  /// (`workflow.run/v1`, `agent.run/v1`), not a field of the snapshot.
  enum Kind { case workflow, agent }
  enum State: String { case running, done, failed, stopped }
  enum Mark: String { case queued, running, done, failed, stopped }
  enum Invalid: Error { case invalid }

  /// One line under the detail. For a workflow, an agent at work: its name
  /// and what it last did. For a sub-agent, one thing it did: the tool and
  /// what it was used on, or a line it said, which has no label.
  struct Line: Equatable, Identifiable {
    let id: String
    let label: String
    let detail: String
  }

  let id: String
  let title: String
  let detail: String
  let state: State
  /// When the clock counts from, while the run is going.
  let since: Date?
  /// A workflow's mark for each agent. A wide run arrives already scaled down.
  let marks: [Mark]
  /// A workflow's agents at work, or a sub-agent's latest actions, newest first.
  let live: [Line]
  /// "3 more working", when `live` does not list them all.
  let more: String?

  static let maxMarks = 24
  static let maxLines = 3

  /// A run that finished cleanly needs no bar: its marks would all be the same.
  var showsMarks: Bool { !marks.isEmpty && (state == .running || marks.contains { $0 != .done }) }

  static func decode(_ value: [String: Any]) throws -> NativeTaskRunSnapshot {
    // A run's title is its script's own description, so a long one is cut, not refused.
    func text(_ value: Any?, max: Int) -> String? {
      guard let string = value as? String, !string.isEmpty else { return nil }
      return String(string.prefix(max))
    }
    guard let id = text(value["id"], max: 200), let title = text(value["title"], max: 300),
      let detail = text(value["detail"], max: 400),
      let state = (value["state"] as? String).flatMap(State.init(rawValue:))
    else { throw Invalid.invalid }
    var since: Date?
    if let n = value["since"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue > 0 {
      since = Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
    let marks = ((value["marks"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(Mark.init(rawValue:)) }
    let live = ((value["live"] as? [Any]) ?? []).compactMap { item -> Line? in
      guard let line = item as? [String: Any], let id = text(line["id"], max: 100) else { return nil }
      // A line an agent said has no label, and a tool used on nothing has no detail.
      let label = text(line["label"], max: 120) ?? ""
      let detail = text(line["detail"], max: 200) ?? ""
      guard !label.isEmpty || !detail.isEmpty else { return nil }
      return Line(id: id, label: label, detail: detail)
    }
    return NativeTaskRunSnapshot(
      id: id, title: title, detail: detail, state: state,
      since: state == .running ? since : nil,
      marks: Array(marks.prefix(maxMarks)),
      live: Array(live.prefix(maxLines)),
      more: text(value["more"], max: 60))
  }
}

extension NativeTaskRunSnapshot.Kind {
  /// The start of the row's accessibility identifiers.
  var identifier: String {
    switch self {
    case .workflow: "NativeWorkflowRun"
    case .agent: "NativeAgentRun"
    }
  }

  /// The symbol a working task pulses. A sub-agent's is its lozenge's.
  var runningSymbol: String {
    switch self {
    case .workflow: "point.3.connected.trianglepath.dotted"
    case .agent: "sparkles"
    }
  }
}

#if os(iOS)
  import SwiftUI
  import UIKit

  @MainActor final class NativeTaskRunState: ObservableObject {
    @Published var snapshot: NativeTaskRunSnapshot?
    var open: () -> Void = {}
  }

  /// Placement, scrolling and lifetime stay with NativeEmbedController.
  @MainActor final class NativeTaskRunRenderer: NativeEmbeddedRenderer {
    private let kind: NativeTaskRunSnapshot.Kind
    private let state = NativeTaskRunState()
    private lazy var host: UIHostingController<NativeTaskRunRow> = {
      let host = UIHostingController(rootView: NativeTaskRunRow(kind: kind, state: state))
      host.safeAreaRegions = []
      host.sizingOptions = [.preferredContentSize]
      host.view.backgroundColor = .clear
      host.view.accessibilityIdentifier = "\(kind.identifier).row"
      return host
    }()
    var viewController: UIViewController { host }
    var onEvent: (([String: Any]) -> Void)?
    var onSizeChange: (() -> Void)?
    var isEditing: Bool { false }
    var accessibilityElements: [Any] { [host.view!] }

    init(kind: NativeTaskRunSnapshot.Kind) {
      self.kind = kind
      // The row has no sheet of its own: the web opens the task in the tool details.
      state.open = { [weak self] in self?.onEvent?(["type": "open"]) }
    }

    func update(snapshot: [String: Any]) throws {
      let next = try NativeTaskRunSnapshot.decode(snapshot)
      guard next != state.snapshot else { return }
      let old = state.snapshot
      state.snapshot = next
      // The words can wrap, the bar comes and goes, and a line is added or
      // dropped as each agent starts and finishes, or as a sub-agent does its
      // first few things.
      if old?.title != next.title || old?.detail != next.detail || old?.live.count != next.live.count
        || old?.more != next.more || old?.showsMarks != next.showsMarks
      {
        onSizeChange?()
      }
    }

    func sizeThatFits(width: CGFloat) -> CGSize {
      host.sizeThatFits(in: CGSize(width: width, height: 20000))
    }
  }

  struct NativeTaskRunRow: View {
    let kind: NativeTaskRunSnapshot.Kind
    @ObservedObject var state: NativeTaskRunState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      if let run = state.snapshot {
        Button { state.open() } label: { row(run) }
          .buttonStyle(.plain)
          .accessibilityHint(kind == .workflow ? "Shows the run's agents" : "Shows what the agent did")
      }
    }

    private func row(_ run: NativeTaskRunSnapshot) -> some View {
      HStack(alignment: .top, spacing: 10) {
        icon(run.state)
          .frame(width: 22, height: 18)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(run.title)
            .font(.ripul(.subheadline, weight: .semibold))
            .foregroundStyle(.ripul(.text))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(kind.identifier).title")
          Text(run.detail)
            .font(.ripul(.caption))
            .foregroundStyle(.ripul(.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(kind.identifier).detail")
          if run.showsMarks {
            marks(run.marks).padding(.top, 4)
          }
          if !run.live.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(run.live) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  if !line.label.isEmpty {
                    Text(line.label)
                      .fontWeight(.medium)
                      .foregroundStyle(.ripul(.text))
                      .layoutPriority(1)
                  }
                  if !line.detail.isEmpty {
                    Text(line.detail)
                      .foregroundStyle(.ripul(.textSecondary))
                      .truncationMode(.tail)
                  }
                }
                .font(.ripul(.caption))
                .lineLimit(1)
              }
              if let more = run.more {
                Text(more).font(.ripul(.caption)).foregroundStyle(.ripul(.textTertiary))
              }
            }
            .padding(.top, 5)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let since = run.since {
          // The system counts it up; nothing here redraws each second.
          Text(since, style: .timer)
            .multilineTextAlignment(.trailing)
            .font(.ripul(.caption).monospacedDigit())
            .foregroundStyle(.ripul(.textSecondary))
            .frame(height: 18)
            .accessibilityIdentifier("\(kind.identifier).elapsed")
        }
        Image(systemName: "chevron.right")
          .font(.ripulIcon(.caption2, weight: .semibold))
          .foregroundStyle(.ripul(.textTertiary))
          .frame(height: 18)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(minHeight: 44)
      .modifier(NativeChatRowBackground())
      // Glass draws a little outside its shape; keep that inside the slot.
      .padding(.vertical, 2)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
      .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: run.detail)
    }

    @ViewBuilder private func icon(_ state: NativeTaskRunSnapshot.State) -> some View {
      switch state {
      case .running:
        // A run lasts minutes, so the pulse is the render server's, not a
        // symbol effect redrawn on the main thread (see RenderServerAnimations).
        RenderServerPulsingSymbol(systemName: kind.runningSymbol, color: .ripul(.info))
      case .done:
        settled("checkmark.circle.fill", .ripul(.success))
      case .failed:
        settled("xmark.octagon.fill", .ripul(.danger))
      case .stopped:
        settled("stop.circle.fill", .ripul(.warning))
      }
    }

    private func settled(_ symbol: String, _ color: Color) -> some View {
      Image(systemName: symbol)
        .font(.ripulIcon(size: 16, weight: .semibold))
        .foregroundStyle(color)
    }

    /// Still on purpose: the icon carries the motion.
    private func marks(_ marks: [NativeTaskRunSnapshot.Mark]) -> some View {
      HStack(spacing: 3) {
        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
          Capsule()
            .fill(style(mark))
            .frame(maxWidth: 22)
            .frame(height: 4)
        }
      }
      .accessibilityHidden(true)
    }

    private func style(_ mark: NativeTaskRunSnapshot.Mark) -> AnyShapeStyle {
      switch mark {
      case .done: AnyShapeStyle(Color.ripul(.success))
      case .failed: AnyShapeStyle(Color.ripul(.danger))
      case .running: AnyShapeStyle(Color.ripul(.info))
      case .stopped: AnyShapeStyle(Color.ripul(.warning))
      case .queued: AnyShapeStyle(.ripul(.textQuaternary))
      }
    }
  }
#endif

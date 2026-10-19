import Foundation

/// The live row for a Trainyard train a chat is waiting on. The web app works
/// out the words (`chrome-extension/src/trainyard/chatTrains.ts`) and sends
/// them as the embed's snapshot; this draws them.
struct NativeTrainSnapshot: Equatable {
  enum State: String { case waiting, running, done, failed }
  enum Invalid: Error { case invalid }

  let id: String
  let title: String
  let detail: String
  let state: State
  /// When the clock counts from, while the train is unfinished.
  let since: Date?
  /// How long it took, once finished.
  let elapsed: TimeInterval?
  let stepsDone: Int
  let stepsTotal: Int
  /// Where a tap goes: the Mac whose yard it is, the project, and the train
  /// (for a queued request, the train it waits behind). Absent on an older web build.
  let machineId: String?
  let projectId: String?
  let trainId: String?

  /// What `ripulTrainRowOpened` carries, when the row can be opened.
  var openTarget: [String: String]? {
    guard let machineId, let projectId, let trainId else { return nil }
    return ["machineId": machineId, "projectId": projectId, "trainId": trainId]
  }

  var isLive: Bool { state == .waiting || state == .running }

  /// The most of a detail that is kept. The row shows three lines of it.
  static let maxDetail = 400

  static func decode(_ value: [String: Any]) throws -> NativeTrainSnapshot {
    func text(_ key: String, max: Int) throws -> String {
      guard let string = value[key] as? String, !string.isEmpty, string.count <= max else { throw Invalid.invalid }
      return string
    }
    func number(_ key: String) -> Double? {
      guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
      return n.doubleValue
    }
    func id(_ key: String) -> String? {
      guard let string = value[key] as? String, !string.isEmpty, string.count <= 200 else { return nil }
      return string
    }
    guard let state = State(rawValue: try text("state", max: 20)) else { throw Invalid.invalid }
    let total = min(max(Int(number("stepsTotal") ?? 0), 0), 12)
    // The detail can be whatever went wrong, at any length (a failure that
    // listed its files ran to 459 characters on 12 October 2026). It is cut,
    // not refused: a refused snapshot leaves the row to the web's copy.
    guard let detail = value["detail"] as? String, !detail.isEmpty else { throw Invalid.invalid }
    return NativeTrainSnapshot(
      id: try text("id", max: 100),
      title: try text("title", max: 120),
      detail: detail.count <= maxDetail ? detail : String(detail.prefix(maxDetail - 1)) + "…",
      state: state,
      since: number("since").map { Date(timeIntervalSince1970: $0 / 1000) },
      elapsed: number("elapsedMs").map { max(0, $0 / 1000) },
      stepsDone: min(max(Int(number("stepsDone") ?? 0), 0), total),
      stepsTotal: total,
      machineId: id("machineId"), projectId: id("projectId"), trainId: id("trainId"))
  }

  /// `1:05`, or `1:02:07` past the hour: the same as the web row.
  static func elapsedText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}

public extension Notification.Name {
  /// A train row in a chat was tapped. `userInfo` holds `machineId`,
  /// `projectId` and `trainId`; the app shows that train.
  static let ripulTrainRowOpened = Notification.Name("ripulTrainRowOpened")
}

#if os(iOS)
  import SwiftUI
  import UIKit

  @MainActor final class NativeTrainState: ObservableObject {
    @Published var snapshot: NativeTrainSnapshot?
  }

  /// Placement, scrolling and lifetime stay with NativeEmbedController.
  @MainActor final class NativeTrainRenderer: NativeEmbeddedRenderer {
    private let state = NativeTrainState()
    private lazy var host: UIHostingController<NativeTrainRow> = {
      let host = UIHostingController(rootView: NativeTrainRow(state: state))
      host.safeAreaRegions = []
      host.sizingOptions = [.preferredContentSize]
      host.view.backgroundColor = .clear
      host.view.accessibilityIdentifier = "NativeTrain.row"
      return host
    }()
    var viewController: UIViewController { host }
    var onEvent: (([String: Any]) -> Void)?
    var onSizeChange: (() -> Void)?
    var isEditing: Bool { false }
    var accessibilityElements: [Any] { [host.view!] }

    func update(snapshot: [String: Any]) throws {
      let next = try NativeTrainSnapshot.decode(snapshot)
      guard next != state.snapshot else { return }
      let old = state.snapshot
      state.snapshot = next
      // The words can wrap onto another line, and the step bar comes and goes.
      if old?.detail != next.detail || old?.isLive != next.isLive || old?.stepsTotal != next.stepsTotal {
        onSizeChange?()
      }
    }

    func sizeThatFits(width: CGFloat) -> CGSize {
      host.sizeThatFits(in: CGSize(width: width, height: 20000))
    }
  }

  struct NativeTrainRow: View {
    @ObservedObject var state: NativeTrainState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      if let train = state.snapshot {
        Button {
          guard let target = train.openTarget else { return }
          NotificationCenter.default.post(name: .ripulTrainRowOpened, object: nil, userInfo: target)
        } label: { row(train) }
          .buttonStyle(.plain)
          .disabled(train.openTarget == nil)
          .accessibilityHint(train.openTarget == nil ? "" : "Shows the train")
      }
    }

    private func row(_ train: NativeTrainSnapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
          Image(systemName: symbol(train.state))
            .font(.ripulIcon(size: 16, weight: .semibold))
            .foregroundStyle(color(train.state))
            .symbolEffect(.pulse, isActive: train.state == .running && !reduceMotion)
            .frame(width: 22)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(train.title)
              .font(.ripul(.subheadline, weight: .semibold))
              .foregroundStyle(.ripul(.text))
              .accessibilityIdentifier("NativeTrain.title")
            // Three lines at most, as the web row has; the train's sheet has the rest.
            Text(train.detail)
              .font(.ripul(.caption))
              .foregroundStyle(.ripul(.textSecondary))
              .lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("NativeTrain.detail")
            if train.isLive, train.stepsTotal > 0 {
              HStack(spacing: 4) {
                ForEach(0..<train.stepsTotal, id: \.self) { index in
                  Capsule()
                    .fill(index < train.stepsDone ? AnyShapeStyle(color(train.state)) : AnyShapeStyle(.ripul(.textQuaternary)))
                    .frame(maxWidth: 28)
                    .frame(height: 3)
                }
              }
              .padding(.top, 3)
              .accessibilityHidden(true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          clock(train)
            .font(.ripul(.caption).monospacedDigit())
            .foregroundStyle(.ripul(.textSecondary))
            .accessibilityIdentifier("NativeTrain.elapsed")
          if train.openTarget != nil {
            Image(systemName: "chevron.right")
              .font(.ripulIcon(.caption2, weight: .semibold))
              .foregroundStyle(.ripul(.textTertiary))
              .accessibilityHidden(true)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .modifier(NativeChatRowBackground())
        // Glass draws a little outside its shape; keep that inside the slot.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: train.detail)
    }

    @ViewBuilder private func clock(_ train: NativeTrainSnapshot) -> some View {
      if let since = train.since {
        // The system counts it up; nothing here redraws each second.
        Text(since, style: .timer).ripulText().multilineTextAlignment(.trailing)
      } else if let elapsed = train.elapsed {
        Text(NativeTrainSnapshot.elapsedText(elapsed)).ripulText()
      }
    }

    private func symbol(_ state: NativeTrainSnapshot.State) -> String {
      switch state {
      case .waiting, .running: "tram.fill"
      case .done: "checkmark.circle.fill"
      case .failed: "xmark.octagon.fill"
      }
    }

    private func color(_ state: NativeTrainSnapshot.State) -> Color {
      switch state {
      case .waiting: .ripul(.warning)
      case .running: .ripul(.info)
      case .done: .ripul(.success)
      case .failed: .ripul(.danger)
      }
    }
  }

  /// The glass behind a full-width row in a chat: a train, a workflow run, a sub-agent.
  struct NativeChatRowBackground: ViewModifier {
    func body(content: Content) -> some View {
      let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
      if #available(iOS 26.0, *) {
        content.glassEffect(.clear, in: shape)
      } else {
        content.background(.ultraThinMaterial, in: shape)
      }
    }
  }
#endif

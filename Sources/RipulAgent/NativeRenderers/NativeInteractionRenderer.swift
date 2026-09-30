#if os(iOS)
import SwiftUI
import UIKit
import MarkdownUI

@MainActor private final class NativeInteractionState: ObservableObject {
  @Published var snapshot: NativeInteractionSnapshot?
  @Published var selected: Set<Int> = []
  @Published var date = Date()
  @Published var text = ""
  @Published var awaitingSubmission = false
  var editSequence = 0
  var editing = false
  var event: (([String: Any]) -> Void)?
  var sizeChanged: (() -> Void)?
  var disabled: Bool { snapshot?.disabled != false || awaitingSubmission || snapshot?.expectsResponse != true }
  func edit(_ action: String, _ values: [String: Any]) {
    guard !disabled else { return }
    editSequence += 1
    event?(values.merging(["action": action, "editSequence": editSequence]) { _, new in new })
  }
  func choose(_ index: Int) {
    guard !disabled, let snapshot, snapshot.options.indices.contains(index) else { return }
    if snapshot.multiSelect {
      if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
      edit("selection", ["indices": selected.sorted()])
    } else {
      selected = [index]
      submit("choose", ["index": index])
    }
  }
  func submit(_ action: String, _ values: [String: Any]) {
    guard !disabled else { return }
    awaitingSubmission = true
    event?(values.merging(["action": action]) { _, new in new })
  }
}

/// The same NativeSlotAttachment host used by artefacts owns scrolling, size and lifetime.
@MainActor final class NativeInteractionRenderer: NativeEmbeddedRenderer {
  private let state = NativeInteractionState()
  private lazy var host: UIHostingController<NativeInteractionPanel> = {
    let host = UIHostingController(rootView: NativeInteractionPanel(state: state))
    host.safeAreaRegions = []
    host.sizingOptions = [.preferredContentSize]
    host.view.backgroundColor = .clear
    host.view.accessibilityIdentifier = "NativeInteraction.panel"
    return host
  }()
  var viewController: UIViewController { host }
  var onEvent: (([String: Any]) -> Void)? {
    get { state.event }
    set { state.event = newValue }
  }
  var onSizeChange: (() -> Void)? {
    get { state.sizeChanged }
    set { state.sizeChanged = newValue }
  }
  var isEditing: Bool { state.editing }
  var accessibilityElements: [Any] { [host.view!] }
  func update(snapshot: [String: Any]) throws {
    let next = try NativeInteractionSnapshot.decode(snapshot)
    if next.editSequence >= state.editSequence || next.completed {
      let selected = Set(next.selectedIndices)
      if state.selected != selected { state.selected = selected }
      if state.text != next.text { state.text = next.text }
      let date = NativeInteractionSnapshot.date(next.selectedDate, includeTime: next.dateInput?.includeTime == true) ?? Date()
      let clamped = min(max(date, next.dateRange.lowerBound), next.dateRange.upperBound)
      if state.date != clamped { state.date = clamped }
      state.editSequence = next.editSequence
    }
    if next.disabled || !next.error.isEmpty { state.awaitingSubmission = false }
    state.snapshot = next
  }
  func sizeThatFits(width: CGFloat) -> CGSize {
    host.sizeThatFits(in: CGSize(width: width, height: 20000))
  }
}

private struct NativeInteractionPanel: View {
  @ObservedObject var state: NativeInteractionState
  @FocusState private var focused: Bool
  @State private var activeTab = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let snapshot = state.snapshot {
        if snapshot.severity == "warning" || snapshot.severity == "error" || snapshot.severity == "success" {
          Label(snapshot.severity.capitalized, systemImage: snapshot.severity == "success" ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption).foregroundStyle(snapshot.severity == "error" ? Color.red : Color.secondary)
        }
        Markdown(snapshot.question).textSelection(.enabled)
          .accessibilityIdentifier("NativeInteraction.question")
        tabContent(snapshot)
        tableContent(snapshot)
        if !snapshot.options.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.options, id: \.index) { option in
              Button { state.choose(option.index) } label: {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: state.selected.contains(option.index)
                    ? (snapshot.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill")
                    : (snapshot.multiSelect ? "square" : "circle"))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).fontWeight(.medium)
                    if !option.description.isEmpty { Text(option.description).font(.caption).foregroundStyle(.secondary) }
                  }
                  Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
              }
              .modifier(NativeInteractionButtonStyle(prominent: state.selected.contains(option.index)))
              .disabled(state.disabled)
              .accessibilityIdentifier("NativeInteraction.option.\(option.index)")
              .accessibilityAddTraits(state.selected.contains(option.index) ? .isSelected : [])
            }
            if snapshot.multiSelect && snapshot.expectsResponse && !snapshot.completed {
              Button("Submit selection") {
                focused = false
                state.submit("submitSelection", ["indices": state.selected.sorted()])
              }.modifier(NativeInteractionButtonStyle(prominent: true))
                .disabled(state.disabled || state.selected.isEmpty)
                .accessibilityIdentifier("NativeInteraction.submitSelection")
            }
          }
        }
        if let input = snapshot.dateInput {
          DatePicker(input.includeTime == true ? "Date and time" : "Date", selection: Binding(
            get: { state.date }, set: { value in
              state.date = value
              state.edit("date", ["value": NativeInteractionSnapshot.dateString(value, includeTime: input.includeTime == true)])
            }), in: snapshot.dateRange,
            displayedComponents: input.includeTime == true ? [.date, .hourAndMinute] : [.date])
            .datePickerStyle(.compact).disabled(state.disabled)
            .accessibilityIdentifier("NativeInteraction.date")
          if snapshot.expectsResponse && !snapshot.completed {
            Button("Submit date") {
              focused = false
              state.submit("submitDate", ["value": NativeInteractionSnapshot.dateString(state.date, includeTime: input.includeTime == true)])
            }.modifier(NativeInteractionButtonStyle(prominent: true)).disabled(state.disabled)
              .accessibilityIdentifier("NativeInteraction.submitDate")
          }
        }
        if snapshot.expectsResponse && !snapshot.completed {
          TextField(snapshot.options.isEmpty && snapshot.dateInput == nil ? "Your answer" : "Or write an answer", text: Binding(
            get: { state.text }, set: { value in state.text = value; state.edit("text", ["value": value]) }), axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(1...6).focused($focused).disabled(state.disabled)
            .accessibilityIdentifier("NativeInteraction.text")
          Button("Send answer") {
            focused = false
            state.submit("submitText", ["value": state.text])
          }.modifier(NativeInteractionButtonStyle(prominent: true))
            .disabled(state.disabled || state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("NativeInteraction.submitText")
        }
        if snapshot.busy || state.awaitingSubmission {
          ProgressView("Sending answer…").font(.caption)
        } else if snapshot.completed && snapshot.expectsResponse {
          Label("Answered", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        }
        if !snapshot.answer.isEmpty {
          Label { Text(snapshot.answer).textSelection(.enabled) } icon: { Image(systemName: "arrowshape.turn.up.left") }
            .accessibilityIdentifier("NativeInteraction.answer")
        }
        if !snapshot.error.isEmpty {
          Text(snapshot.error).foregroundStyle(.red).font(.callout)
            .accessibilityIdentifier("NativeInteraction.error")
        }
      }
    }
    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .background {
      GeometryReader { geometry in Color.clear.onChange(of: geometry.size) { _, _ in state.sizeChanged?() } }
    }
    .onChange(of: focused) { _, value in state.editing = value; state.sizeChanged?() }
    .onChange(of: state.snapshot?.disabled) { _, value in if value == true { focused = false } }
    .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
  }

  @ViewBuilder private func tabContent(_ snapshot: NativeInteractionSnapshot) -> some View {
    if snapshot.tabs.count > 1 {
      Picker("Details", selection: $activeTab) {
        ForEach(snapshot.tabs.indices, id: \.self) { index in Text(snapshot.tabs[index].title).tag(index) }
      }.pickerStyle(.menu).accessibilityIdentifier("NativeInteraction.tabs")
    }
    if !snapshot.tabs.isEmpty {
      Markdown(snapshot.tabs[min(activeTab, snapshot.tabs.count - 1)].content).textSelection(.enabled)
    }
  }

  @ViewBuilder private func tableContent(_ snapshot: NativeInteractionSnapshot) -> some View {
    if !snapshot.rows.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(snapshot.rows.indices, id: \.self) { index in
          let row = snapshot.rows[index]
          VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.headers.indices, id: \.self) { column in
              VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.headers[column]).font(.caption).foregroundStyle(.secondary)
                Markdown(row.cells[column])
              }
            }
            if row.optionIndex >= 0 {
              Button(state.selected.contains(row.optionIndex) ? "Selected" : "Select") { state.choose(row.optionIndex) }
                .modifier(NativeInteractionButtonStyle(prominent: state.selected.contains(row.optionIndex)))
                .disabled(state.disabled)
            }
            if let url = URL(string: row.link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
              Link("Open link", destination: url)
            }
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
      }
    }
  }
}

/// Use the system's interactive glass button treatment, including its disabled
/// appearance. Keep the same shape for multiline choices and their actions.
private struct NativeInteractionButtonStyle: ViewModifier {
  var prominent = false

  func body(content: Content) -> some View {
    Group {
      if #available(iOS 26.0, *) {
        if prominent {
          content.buttonStyle(.glassProminent)
        } else {
          content.buttonStyle(.glass)
        }
      } else {
        if prominent {
          content.buttonStyle(.borderedProminent)
        } else {
          content.buttonStyle(.bordered)
        }
      }
    }
    .buttonBorderShape(.roundedRectangle(radius: 12))
  }
}
#endif

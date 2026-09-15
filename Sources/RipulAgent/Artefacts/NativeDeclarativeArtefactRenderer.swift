#if os(iOS)
  import SwiftUI
  import UIKit

  private struct NativeArtefactSnapshot: Decodable {
    struct Definition: Decodable {
      struct Presentation: Decodable { let runLabel: String }
      let runtime: String
      let inputSchema: [NativeArtefactInputField]
      let presentation: Presentation
    }
    struct Result: Decodable {
      let label: String
      let value: String
    }
    let definition: Definition
    let values: [String: String]
    let outputRows: [Result]
    let busy: Bool
    let canRun: Bool
    let error: String
    let editSequence: Int
  }

  @MainActor private final class NativeArtefactFormState: ObservableObject {
    @Published var snapshot: NativeArtefactSnapshot?
    @Published var values: [String: String] = [:]
    var editSequence = 0
    var editing = false
    var event: (([String: Any]) -> Void)?
    var sizeChanged: (() -> Void)?
    func change(_ key: String, _ value: String) {
      guard let snapshot, !snapshot.busy, snapshot.canRun,
        let field = snapshot.definition.inputSchema.first(where: { $0.key == key })
      else { return }
      values[key] = value
      editSequence += 1
      let normalized =
        field.type == "number" || field.type == "integer"
        ? value.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".") : value
      event?(["action": "change", "key": key, "value": normalized, "editSequence": editSequence])
      sizeChanged?()
    }
  }

  /// Registered by format, never by artefact identity. Calculation stays in the
  /// authenticated shared artefact runtime; this renderer emits semantic events.
  @MainActor final class NativeDeclarativeArtefactRenderer: NativeEmbeddedRenderer {
    private let state = NativeArtefactFormState()
    private lazy var host: UIHostingController<NativeArtefactForm> = {
      let host = UIHostingController(rootView: NativeArtefactForm(state: state))
      host.safeAreaRegions = []
      host.sizingOptions = [.preferredContentSize]
      host.view.backgroundColor = .clear
      host.view.accessibilityIdentifier = "NativeArtefact.form"
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
      let data = try JSONSerialization.data(withJSONObject: snapshot)
      let next = try JSONDecoder().decode(NativeArtefactSnapshot.self, from: data)
      guard next.definition.runtime == "declarative/v1",
        (1...64).contains(next.definition.inputSchema.count),
        Set(next.definition.inputSchema.map(\.key)).count == next.definition.inputSchema.count,
        next.definition.inputSchema.allSatisfy({
          ["string", "number", "integer", "boolean"].contains($0.type)
        }),
        next.outputRows.count <= 64, next.editSequence >= 0
      else { throw CocoaError(.coderInvalidValue) }
      if next.editSequence >= state.editSequence {
        // While a field owns the caret, equal values must not rewrite it.
        let numericKeys = Set(
          next.definition.inputSchema.filter { $0.type == "number" || $0.type == "integer" }.map(
            \.key))
        let values = next.values.mapValues { $0 }
          .map { key, value in
            (
              key,
              numericKeys.contains(key)
                ? value.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
                : value
            )
          }
        let displayValues = Dictionary(uniqueKeysWithValues: values)
        if state.values != displayValues { state.values = displayValues }
        state.editSequence = next.editSequence
      }
      state.snapshot = next
    }
    func sizeThatFits(width: CGFloat) -> CGSize {
      host.sizeThatFits(in: CGSize(width: width, height: 20000))
    }
  }

  private struct NativeArtefactForm: View {
    @ObservedObject var state: NativeArtefactFormState
    @FocusState private var focused: String?
    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        if let snapshot = state.snapshot {
          if !snapshot.error.isEmpty { Text(snapshot.error).font(.callout).foregroundStyle(.red) }
          NativeArtefactFields(
            fields: snapshot.definition.inputSchema, values: state.values, focus: $focused,
            onChange: state.change
          )
          .disabled(snapshot.busy || !snapshot.canRun)
          Button {
            focused = nil
            state.event?(["action": "run"])
          } label: {
            HStack {
              if snapshot.busy { ProgressView() }
              Text(snapshot.definition.presentation.runLabel)
            }.frame(maxWidth: .infinity)
          }.buttonStyle(.borderedProminent)
            .disabled(snapshot.busy || !snapshot.canRun)
            .uiKitIdentifier("NativeArtefact.run")
          ForEach(Array(snapshot.outputRows.enumerated()), id: \.offset) { _, row in
            NativeArtefactResultRow(label: row.label, value: row.value)
              .uiKitIdentifier("NativeArtefact.result")
          }
        }
      }
      .padding(.vertical, 6).padding(.horizontal, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .background {
        GeometryReader { geometry in
          Color.clear.onChange(of: geometry.size) { _, _ in state.sizeChanged?() }
        }
      }
      .onChange(of: focused) { _, value in
        state.editing = value != nil
        state.sizeChanged?()
      }
      .onChange(of: state.snapshot?.outputRows.count) { _, _ in state.sizeChanged?() }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { focused = nil }
        }
      }
    }
  }
#endif

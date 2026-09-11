#if os(iOS)
import SwiftUI

@available(iOS 16.0, *)
struct InspectorWebPanel: View {
    @ObservedObject var session: InspectorSession
    let tab: InspectorHUD.InspectorTab
    let element: InspectorWebElement
    @State private var expression = "$0.textContent"
    @State private var result = ""
    @State private var evaluating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(element.label).fontWeight(.semibold).foregroundStyle(.orange)
            switch tab {
            case .properties:
                Text(element.reference).textSelection(.enabled)
                ForEach(element.attributes.keys.sorted(), id: \.self) { key in
                    Text("\(key): \(element.attributes[key] ?? "")").textSelection(.enabled)
                }
            case .edit, .layout:
                if tab == .layout { Text("Layout values are CSS pixels. Changes apply immediately.").foregroundStyle(.gray) }
                ForEach(styleKeys, id: \.self) { key in
                    InspectorWebStyleRow(session: session, property: key, value: element.styles[key] ?? "")
                        .id(element.id + key)
                }
            case .tree:
                ForEach(element.ancestors) { node in
                    Button("↑ " + node.label) { session.selectWeb(id: node.id) }
                }
                Text("● " + element.label).foregroundStyle(.pink)
                ForEach(element.children) { node in
                    Button("↳ " + node.label) { session.selectWeb(id: node.id) }
                }
                if element.children.count == 150 { Text("First 150 children shown").foregroundStyle(.gray) }
            case .eval:
                Text("JavaScript expression · $0 is the selected element").foregroundStyle(.gray)
                TextField("Expression", text: $expression, axis: .vertical)
                    .textFieldStyle(.roundedBorder).foregroundStyle(.primary)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .uiKitIdentifier("Inspector.eval.expression")
                Button(evaluating ? "Running…" : "Run") {
                    evaluating = true
                    Task { result = await session.evaluate(expression); evaluating = false }
                }.disabled(evaluating).uiKitIdentifier("Inspector.eval.run")
                Text(result).textSelection(.enabled)
                if !result.isEmpty { Button("Copy result") { UIPasteboard.general.string = result } }
            case .audit, .macro, .settings:
                EmptyView()
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var styleKeys: [String] {
        tab == .layout
            ? ["display", "position", "width", "height", "padding-top", "padding-right", "padding-bottom", "padding-left",
               "margin-top", "margin-right", "margin-bottom", "margin-left", "border-top-width", "border-right-width", "border-bottom-width", "border-left-width"]
            : ["color", "background-color", "font-size", "font-weight", "line-height", "border-radius", "opacity", "z-index"]
    }
}

@available(iOS 16.0, *)
private struct InspectorWebStyleRow: View {
    @ObservedObject var session: InspectorSession
    let property: String
    let value: String
    @State private var draft = ""
    var body: some View {
        HStack {
            Text(property).frame(width: 115, alignment: .leading)
            TextField(property, text: $draft)
                .textFieldStyle(.roundedBorder).foregroundStyle(.primary)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .onSubmit { Task { await session.editStyle(property, value: draft) } }
            Button("Apply") { Task { await session.editStyle(property, value: draft) } }
                .disabled(draft == value)
        }
        .onAppear { draft = value }
        .onChange(of: value) { draft = $0 }
    }
}
#endif

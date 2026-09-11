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
                if tab == .layout {
                    InspectorBoxModelView(session: session, element: element)
                    Text("Tap an edge to edit. Values are CSS pixels.").foregroundStyle(.gray)
                }
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
            ? ["display", "position", "box-sizing", "width", "height"]
            : ["color", "background-color", "font-size", "font-weight", "line-height", "border-radius", "opacity", "z-index"]
    }
}

/// Native rendering of the web Inspector's concentric CSS box model.
/// Each entire edge is a tap target; numeric edits default to px, while CSS
/// units and keywords are preserved. Selection identity is owned by the panel.
@available(iOS 16.0, *)
private struct InspectorBoxModelView: View {
    @ObservedObject var session: InspectorSession
    let element: InspectorWebElement
    @State private var editingProperty = ""
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        ring("margin", color: .orange) {
            ring("border", color: .yellow) {
                ring("padding", color: .green) {
                    Text("\(format(element.box.content.width)) × \(format(element.box.content.height))")
                        .fontWeight(.semibold)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(.cyan)
                        .background(Color.cyan.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(Color.cyan, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .accessibilityLabel("Content size")
                        .accessibilityValue("\(format(element.box.content.width)) by \(format(element.box.content.height)) CSS pixels")
                        .uiKitIdentifier("Inspector.boxModel.content")
                }
            }
        }
        .alert("Edit \(editingProperty)", isPresented: $editing) {
            TextField("CSS value", text: $draft)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                let property = editingProperty
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = Double(trimmed).map { $0.isFinite } == true ? trimmed + "px" : trimmed
                Task { await session.editStyle(property, value: value) }
            }
        } message: {
            Text("Enter a number in pixels or a CSS value. Clear it to remove the inline override.")
        }
    }

    private func ring<Content: View>(_ layer: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            edge(layer, "top", color: color).frame(height: 28)
            HStack(spacing: 0) {
                edge(layer, "left", color: color).frame(width: 32)
                content()
                edge(layer, "right", color: color).frame(width: 32)
            }
            edge(layer, "bottom", color: color).frame(height: 28)
        }
        .background(color.opacity(0.13))
        .overlay(Rectangle().strokeBorder(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])).allowsHitTesting(false))
        .overlay(alignment: .topLeading) {
            Text(layer).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color).padding(4).allowsHitTesting(false)
        }
    }

    private func edge(_ layer: String, _ side: String, color: Color) -> some View {
        let property = "\(layer)-\(side)" + (layer == "border" ? "-width" : "")
        let value = element.styles[property] ?? "0px"
        let display = value.hasSuffix("px") ? String(value.dropLast(2)) : value
        return Button {
            editingProperty = property
            draft = value
            editing = true
        } label: {
            Text(display).lineLimit(1).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(color)
        .accessibilityLabel("\(layer) \(side)")
        .accessibilityValue(value)
        .uiKitIdentifier("Inspector.boxModel.\(property)")
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
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

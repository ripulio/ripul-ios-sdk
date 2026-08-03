#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Conformance harness
//
// One screen carrying one of every control ARCHETYPE, each stamped with a known
// id and a declared expectation, so `explorer_conformance` can point the
// reticule at every one of them and report a coverage number.
//
// Why this exists: for a long stretch the only way to learn that an archetype
// was unreachable was for someone to point at it on a phone and report a
// symptom. Every gap found that way cost a round trip, a release, and an
// install — and several "fixes" were verified against a code path that was
// never broken, because the tools addressed elements by predicate while the
// failing path resolved them by point.
//
// The archetypes here are the ones a tap can mean something different for.
// UIKit and SwiftUI versions sit side by side deliberately: the same visual
// control resolves through entirely different machinery in each, and it is the
// SwiftUI side that has been consistently unreachable.

/// One row under test: what it is, and what the SDK should be able to do with it.
struct RipulArchetype: Identifiable {
    let id: String            // stamped identifier, "ripul.conformance.<name>"
    let title: String
    /// Should the actuation ladder be able to press it at all? A label is a
    /// legitimate NO — theme tools select those, and "nothing here responds to
    /// a tap" is a correct answer, not a failure.
    let expectActionable: Bool
    /// The `via` we expect, when we can predict it. Nil means "any success".
    let expectVia: String?
}

public enum RipulConformance {
    static let prefix = "ripul.conformance."

    /// The declared expectations, matched by id to what's on screen.
    static let archetypes: [RipulArchetype] = [
        .init(id: prefix + "uikit.button", title: "UIKit UIButton", expectActionable: true, expectVia: "uicontrol"),
        .init(id: prefix + "uikit.textfield", title: "UIKit UITextField", expectActionable: true, expectVia: nil),
        .init(id: prefix + "uikit.textview", title: "UIKit UITextView", expectActionable: true, expectVia: "focus"),
        .init(id: prefix + "uikit.switch", title: "UIKit UISwitch", expectActionable: true, expectVia: nil),
        .init(id: prefix + "swiftui.button", title: "SwiftUI Button", expectActionable: true, expectVia: nil),
        .init(id: prefix + "swiftui.textfield", title: "SwiftUI TextField", expectActionable: true, expectVia: nil),
        .init(id: prefix + "swiftui.toggle", title: "SwiftUI Toggle", expectActionable: true, expectVia: nil),
        .init(id: prefix + "swiftui.ontap", title: "SwiftUI onTapGesture view", expectActionable: true, expectVia: nil),
        .init(id: prefix + "swiftui.label", title: "SwiftUI Text (inert)", expectActionable: false, expectVia: nil),
        .init(id: prefix + "swiftui.nested", title: "SwiftUI button in a nested island", expectActionable: true, expectVia: nil),
    ]

    /// Present the harness. Deliberately a plain modal — presented content was
    /// itself invisible to the element layer until recently, so the harness
    /// exercising a modal is the point rather than an inconvenience.
    ///
    /// Presented into the APP's window, explicitly NOT via
    /// `RipulChrome.presentationRoot()`. That resolver prefers the top-most
    /// interactive chrome window so SDK sheets land above the explorer — right
    /// for a remap sheet, exactly wrong here: the harness must be app content,
    /// because the element machinery under test walks `appWindow()` and
    /// deliberately refuses to look inside chrome. Using it put the whole
    /// harness somewhere the sweep is forbidden to see, and scored 0/10 on ten
    /// controls that were never examined.
    @available(iOS 16.0, *)
    @discardableResult
    @MainActor
    public static func present() -> Bool {
        guard let appRoot = RipulChrome.appWindow()?.rootViewController else { return false }
        var top = appRoot
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        if top is UIHostingController<RipulConformanceView> { return false }   // already up
        let host = UIHostingController(rootView: RipulConformanceView())
        host.modalPresentationStyle = .pageSheet
        top.present(host, animated: true)
        return true
    }
}

@available(iOS 16.0, *)
struct RipulConformanceView: View {
    @State private var uikitText = ""
    @State private var swiftuiText = ""
    @State private var toggleOn = false
    @State private var log: [String] = []

    private func note(_ s: String) { log.append(s) }

    var body: some View {
        NavigationStack {
            List {
                Section("UIKit") {
                    RipulUIKitButtonRow(id: RipulConformance.prefix + "uikit.button") { note("uikit.button") }
                        .frame(height: 44)
                    RipulUIKitTextFieldRow(id: RipulConformance.prefix + "uikit.textfield", text: $uikitText)
                        .frame(height: 44)
                    RipulUIKitTextViewRow(id: RipulConformance.prefix + "uikit.textview")
                        .frame(height: 60)
                    RipulUIKitSwitchRow(id: RipulConformance.prefix + "uikit.switch")
                        .frame(height: 44)
                }
                Section("SwiftUI") {
                    Button("SwiftUI Button") { note("swiftui.button") }
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.button")
                    TextField("SwiftUI TextField", text: $swiftuiText)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.textfield")
                    Toggle("SwiftUI Toggle", isOn: $toggleOn)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.toggle")
                    Text("Tap gesture only")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { note("swiftui.ontap") }
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.ontap")
                    Text("Inert label — theme-selectable, never pressable")
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.label")
                    // A button inside a nested hosting island — the shape that
                    // defeated hit-testing for most of this SDK's life.
                    RipulNestedIsland {
                        Button("Nested island button") { note("swiftui.nested") }
                            .uiKitIdentifier(RipulConformance.prefix + "swiftui.nested")
                    }
                }
                if !log.isEmpty {
                    Section("Activations") {
                        ForEach(log, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
            .navigationTitle("Ripul conformance")
        }
    }
}

/// Wraps content in its own `UIHostingController`, reproducing the
/// island-inside-an-island nesting that real apps produce and that flat test
/// cases never do.
@available(iOS 16.0, *)
struct RipulNestedIsland<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: Content
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let h = UIHostingController(rootView: content)
        h.view.backgroundColor = .clear
        return h
    }
    func updateUIViewController(_ uiViewController: UIHostingController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}

// MARK: - UIKit archetypes

struct RipulUIKitButtonRow: UIViewRepresentable {
    let id: String
    let action: () -> Void
    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle("UIKit UIButton", for: .normal)
        b.contentHorizontalAlignment = .leading
        b.accessibilityIdentifier = id
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}

struct RipulUIKitTextFieldRow: UIViewRepresentable {
    let id: String
    @Binding var text: String
    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.placeholder = "UIKit UITextField"
        f.accessibilityIdentifier = id
        f.borderStyle = .roundedRect
        return f
    }
    func updateUIView(_ uiView: UITextField, context: Context) { uiView.text = text }
}

struct RipulUIKitTextViewRow: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.text = "UIKit UITextView"
        v.accessibilityIdentifier = id
        v.font = .preferredFont(forTextStyle: .body)
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.separator.cgColor
        return v
    }
    func updateUIView(_ uiView: UITextView, context: Context) {}
}

struct RipulUIKitSwitchRow: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> UISwitch {
        let s = UISwitch()
        s.accessibilityIdentifier = id
        return s
    }
    func updateUIView(_ uiView: UISwitch, context: Context) {}
}
#endif

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

/// Ground truth for "did the press actually do anything".
///
/// The engine reporting success is not evidence. `itemSelection` selected a
/// SwiftUI List row - which does nothing whatever without a selection binding -
/// and reported success for a UIButton, a UISwitch and an onTapGesture view,
/// scoring 9/10 while three of those controls were never touched. The same
/// fallback also "pressed" the inert label, and only its declared expectation
/// made that one show up as a failure.
///
/// So the app records what genuinely ran - a control action, a delegate
/// callback, a state change - and the sweep checks for THAT. A press that
/// leaves no trace in here did not happen, whatever the ladder claims.
@MainActor
final class RipulConformanceLog: ObservableObject {
    static let shared = RipulConformanceLog()
    @Published private(set) var fired: [String] = []
    func note(_ token: String) { fired.append(token) }
    func clear() { fired.removeAll() }
    func contains(_ token: String) -> Bool { fired.contains(token) }
}

/// Layout state the sweep's anchor phase toggles. Moving AND resizing the
/// split control between an anchored record and its replay is the whole test:
/// an element-relative anchor follows the element; a screen-grounded
/// coordinate keeps pointing at where it used to be.
@MainActor
final class RipulConformanceState: ObservableObject {
    static let shared = RipulConformanceState()
    @Published var splitShifted = false
}

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
    /// The token this control writes to `RipulConformanceLog` when its REAL
    /// handler runs. Nil for an archetype with no handler to run - the inert
    /// label, whose correct outcome is that nothing anywhere fires.
    let effectToken: String?
}

public enum RipulConformance {
    static let prefix = "ripul.conformance."

    /// The declared expectations, matched by id to what's on screen.
    static let archetypes: [RipulArchetype] = [
        .init(id: prefix + "uikit.button", title: "UIKit UIButton", expectActionable: true,
              expectVia: nil, effectToken: "uikit.button"),
        .init(id: prefix + "uikit.textfield", title: "UIKit UITextField", expectActionable: true,
              expectVia: nil, effectToken: "uikit.textfield"),
        .init(id: prefix + "uikit.textview", title: "UIKit UITextView", expectActionable: true,
              expectVia: "focus", effectToken: "uikit.textview"),
        .init(id: prefix + "uikit.switch", title: "UIKit UISwitch", expectActionable: true,
              expectVia: nil, effectToken: "uikit.switch"),
        .init(id: prefix + "swiftui.button", title: "SwiftUI Button", expectActionable: true,
              expectVia: nil, effectToken: "swiftui.button"),
        .init(id: prefix + "swiftui.textfield", title: "SwiftUI TextField", expectActionable: true,
              expectVia: nil, effectToken: "swiftui.textfield"),
        .init(id: prefix + "swiftui.toggle", title: "SwiftUI Toggle", expectActionable: true,
              expectVia: nil, effectToken: "swiftui.toggle"),
        .init(id: prefix + "swiftui.ontap", title: "SwiftUI onTapGesture view", expectActionable: true,
              expectVia: nil, effectToken: "swiftui.ontap"),
        .init(id: prefix + "swiftui.label", title: "SwiftUI Text (inert)", expectActionable: false,
              expectVia: nil, effectToken: nil),
        .init(id: prefix + "swiftui.nested", title: "SwiftUI button in a nested island", expectActionable: true,
              expectVia: nil, effectToken: "swiftui.nested"),
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
    @FocusState private var swiftuiFieldFocused: Bool
    @ObservedObject private var log = RipulConformanceLog.shared
    @ObservedObject private var state = RipulConformanceState.shared

    // Every archetype reports the effect the PLATFORM produced, not the effect
    // the engine believes it caused. Focus counts for a text control, a value
    // change counts for a toggle, an action counts for a button.
    private func note(_ s: String) { RipulConformanceLog.shared.note(s) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("UIKit").font(.headline)
                    RipulUIKitButtonRow(id: RipulConformance.prefix + "uikit.button") { note("uikit.button") }
                        .frame(height: 44)
                    RipulUIKitTextFieldRow(id: RipulConformance.prefix + "uikit.textfield", text: $uikitText)
                        .frame(height: 44)
                    RipulUIKitTextViewRow(id: RipulConformance.prefix + "uikit.textview")
                        .frame(height: 60)
                    RipulUIKitSwitchRow(id: RipulConformance.prefix + "uikit.switch")
                        .frame(height: 44)
                }
                Group {
                    Text("SwiftUI").font(.headline)
                    Button("SwiftUI Button") { note("swiftui.button") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.button")
                    TextField("SwiftUI TextField", text: $swiftuiText)
                        .focused($swiftuiFieldFocused)
                        .onChange(of: swiftuiFieldFocused) { if $1 { note("swiftui.textfield") } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.textfield")
                    Toggle("SwiftUI Toggle", isOn: $toggleOn)
                        .onChange(of: toggleOn) { note("swiftui.toggle") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.toggle")
                    Text("Tap gesture only")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { note("swiftui.ontap") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.ontap")
                    Text("Inert label — theme-selectable, never pressable")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.label")
                    // A button inside a nested hosting island — the shape that
                    // defeated hit-testing for most of this SDK's life.
                    RipulNestedIsland {
                        Button("Nested island button") { note("swiftui.nested") }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier(RipulConformance.prefix + "swiftui.nested")
                    }
                    // Needs an explicit height: a UIViewControllerRepresentable
                    // has no intrinsic size in a VStack, so it measured zero and
                    // the sweep reported this archetype as not-on-screen.
                    .frame(height: 44)
                }
                Group {
                    Text("Anchor").font(.headline)
                    // Two wired but deliberately ANONYMOUS controls in one
                    // stamped container — no id, no title, no accessibility
                    // element on either half, so the tap POINT is the only
                    // thing that can say which was meant. The sweep's anchor
                    // phase records an element-relative anchor against the
                    // container, flips `splitShifted` (moving AND resizing the
                    // row), and replays — the anchor must follow the element.
                    RipulSplitControlRow(id: RipulConformance.prefix + "uikit.split")
                        .padding(.leading, state.splitShifted ? 96 : 0)
                        .padding(.trailing, state.splitShifted ? 120 : 0)
                        .frame(height: 44)
                }
                if !log.fired.isEmpty {
                    Text("Activations").font(.headline)
                    ForEach(log.fired, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
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
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.placeholder = "UIKit UITextField"
        f.accessibilityIdentifier = id
        f.borderStyle = .roundedRect
        f.delegate = context.coordinator
        return f
    }
    func updateUIView(_ uiView: UITextField, context: Context) { uiView.text = text }
    final class Coordinator: NSObject, UITextFieldDelegate {
        func textFieldDidBeginEditing(_ textField: UITextField) {
            RipulConformanceLog.shared.note("uikit.textfield")
        }
    }
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
        v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ uiView: UITextView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UITextViewDelegate {
        func textViewDidBeginEditing(_ textView: UITextView) {
            RipulConformanceLog.shared.note("uikit.textview")
        }
    }
}

/// A wired control with NO identity of any kind — no accessibilityIdentifier,
/// no title, no accessibility element. The half that fires is decidable only
/// by where the tap landed, which is precisely the shape the element-relative
/// anchor exists for.
final class RipulHalfControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct RipulSplitControlRow: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.accessibilityIdentifier = id
        let left = RipulHalfControl()
        left.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.35)
        left.addAction(UIAction { _ in RipulConformanceLog.shared.note("split.left") }, for: .touchUpInside)
        let right = RipulHalfControl()
        right.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.35)
        right.addAction(UIAction { _ in RipulConformanceLog.shared.note("split.right") }, for: .touchUpInside)
        for half in [left, right] {
            half.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(half)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            left.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.5),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            right.topAnchor.constraint(equalTo: container.topAnchor),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            right.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.5),
        ])
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct RipulUIKitSwitchRow: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> UISwitch {
        let s = UISwitch()
        s.accessibilityIdentifier = id
        s.addAction(UIAction { _ in RipulConformanceLog.shared.note("uikit.switch") }, for: .valueChanged)
        return s
    }
    func updateUIView(_ uiView: UISwitch, context: Context) {}
}
#endif

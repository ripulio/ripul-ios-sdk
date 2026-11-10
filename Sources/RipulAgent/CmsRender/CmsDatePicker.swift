import SwiftUI

/// How a date or timestamp input's picker opens (`picker` on the input, else
/// `form.picker`, else a sheet; docs/plans/cms-record-form.md, item 9).
enum CmsDatePickerStyle: String {
    /// Today's: the record form's tile opens a sheet; a field row is the system's own picker.
    case sheet
    /// A popover anchored to the field or tile, kept a popover on iPhone.
    case floating
    /// The picker opens in place under the field; tapping again closes it.
    case inline

    /// The input's own, else the form's, else `sheet`. An unknown value counts as unset.
    static func resolve(_ input: CmsActionInputDef, form: CmsFormDef?) -> CmsDatePickerStyle {
        input.picker.flatMap(Self.init(rawValue:)) ?? form?.picker.flatMap(Self.init(rawValue:)) ?? .sheet
    }
}

/// The floating picker's content: a timestamp's date as the system's compact
/// pill, its time as wheels, then Done; a date's graphical calendar.
struct CmsFloatingDatePicker: View {
    let label: String
    @Binding var selection: Date
    let lower: Date?
    let dateOnly: Bool
    /// A time of day (`type: "time"`): the time wheels alone.
    var timeOnly: Bool = false
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
            if timeOnly {
                #if os(iOS)
                picker("Time", [.hourAndMinute]).datePickerStyle(.wheel).labelsHidden()
                #else
                picker("Time", [.hourAndMinute]).labelsHidden()
                #endif
            } else if dateOnly {
                picker("Date", [.date]).datePickerStyle(.graphical).labelsHidden()
            } else {
                LabeledContent("Date") {
                    picker("Date", [.date]).datePickerStyle(.compact).labelsHidden()
                }
                #if os(iOS)
                picker("Time", [.hourAndMinute]).datePickerStyle(.wheel).labelsHidden()
                #else
                picker("Time", [.hourAndMinute]).labelsHidden()
                #endif
            }
            }
            .padding(16)
            // Done as a popover's is: plain words in the accent, centred under a hairline.
            Divider()
            Button(action: done) {
                Text("Done").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .cmsInspectorID("Cms.datePicker.done")
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(label)
        .cmsInspectorID("Cms.datePicker.floating")
    }

    @ViewBuilder
    private func picker(_ title: String, _ components: DatePickerComponents) -> some View {
        if let lower {
            DatePicker(title, selection: $selection, in: lower..., displayedComponents: components)
        } else {
            DatePicker(title, selection: $selection, displayedComponents: components)
        }
    }
}

/// A form row for a `floating` or `inline` date: the label and the value
/// (with the pop-up chevrons when floating). Floating opens the popover
/// anchored to the row; inline opens the graphical picker as the next row.
struct CmsDatePickerRow: View {
    let label: String
    @Binding var selection: Date
    let lower: Date?
    let dateOnly: Bool
    let style: CmsDatePickerStyle
    var tint: Color? = nil
    /// A time of day: shown and picked as hours and minutes alone.
    var timeOnly: Bool = false

    @State private var open = false

    var body: some View {
        Button { withAnimation(.snappy) { open.toggle() } } label: {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    Text(selection, format: timeOnly
                         ? .dateTime.hour().minute()
                         : dateOnly
                         ? .dateTime.day().month(.abbreviated).year()
                         : .dateTime.day().month(.abbreviated).hour().minute())
                        .monospacedDigit()
                        .foregroundStyle(open ? Color.accentColor : Color.ripul(.text))
                    if style == .floating {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cmsAnchoredPopover(isPresented: Binding(get: { open && style == .floating }, set: { open = $0 }), tint: tint) {
            CmsFloatingDatePicker(label: label, selection: $selection, lower: lower, dateOnly: dateOnly, timeOnly: timeOnly) { open = false }
        }
        .cmsInspectorID("Cms.datePicker.row")
        if open && style == .inline {
            CmsInlineDatePicker(label: label, selection: $selection, lower: lower, dateOnly: dateOnly, timeOnly: timeOnly)
        }
    }
}

/// The inline picker: the graphical calendar, with the time under it for a timestamp.
struct CmsInlineDatePicker: View {
    let label: String
    @Binding var selection: Date
    let lower: Date?
    let dateOnly: Bool
    /// A time of day: the time wheels alone.
    var timeOnly: Bool = false

    var body: some View {
        let components: DatePickerComponents = timeOnly ? [.hourAndMinute] : dateOnly ? [.date] : [.date, .hourAndMinute]
        Group {
            if let lower {
                DatePicker(label, selection: $selection, in: lower..., displayedComponents: components)
            } else {
                DatePicker(label, selection: $selection, displayedComponents: components)
            }
        }
        .modifier(CmsInlinePickerStyle(timeOnly: timeOnly))
        .labelsHidden()
        .cmsInspectorID("Cms.datePicker.inline")
    }
}

/// The inline picker's style: the graphical calendar, or a time's wheels.
private struct CmsInlinePickerStyle: ViewModifier {
    let timeOnly: Bool
    func body(content: Content) -> some View {
        #if os(iOS)
        if timeOnly { content.datePickerStyle(.wheel) } else { content.datePickerStyle(.graphical) }
        #else
        content.datePickerStyle(.graphical)
        #endif
    }
}

extension View {
    /// A popover anchored to this view's bounds, with its arrow pointing at it
    /// from below or above and never covering it, kept a popover on iPhone.
    /// SwiftUI's `.popover` inside a sheet on iPhone fell back to a side
    /// placement over the tile, so iOS presents it through UIKit.
    func cmsAnchoredPopover<Content: View>(isPresented: Binding<Bool>, tint: Color?,
                                           @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        background(CmsPopoverAnchor(isPresented: isPresented, tint: tint, content: content))
        #else
        popover(isPresented: isPresented) { content().tint(tint) }
        #endif
    }
}

#if os(iOS)
import UIKit

/// Presents `content` in a `UIPopoverPresentationController` whose source is
/// this view (the tile or row): arrows up or down only, never adapted to a sheet.
struct CmsPopoverAnchor<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let tint: Color?
    let content: () -> Content

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var host: UIHostingController<AnyView>?
        var onDismiss: () -> Void = {}

        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

        /// Tapping outside closes it and keeps what was picked.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            host = nil
            onDismiss()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        let binding = $isPresented
        coordinator.onDismiss = { binding.wrappedValue = false }
        let root = AnyView(content().tint(tint))
        if isPresented {
            if let host = coordinator.host {
                host.rootView = root
            } else {
                DispatchQueue.main.async { present(root, from: view, coordinator: coordinator) }
            }
        } else if let host = coordinator.host {
            coordinator.host = nil
            if host.presentingViewController != nil, !host.isBeingDismissed { host.dismiss(animated: true) }
        }
    }

    private func present(_ root: AnyView, from view: UIView, coordinator: Coordinator) {
        guard coordinator.host == nil, isPresented, view.window != nil,
              var presenter = Self.viewController(of: view) else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let host = UIHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .popover
        if let popover = host.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = coordinator
        }
        coordinator.host = host
        presenter.present(host, animated: true)
    }

    private static func viewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
#endif

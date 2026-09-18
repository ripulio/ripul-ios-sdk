import SwiftUI

/// How a sheet should size itself on the Mac idiom.
///
/// Detents are a `UISheetPresentationController` feature that Mac Catalyst does
/// not implement, so `[.medium, .large]` is silently dropped there and the sheet
/// falls back to UIKit's fixed form-sheet box (~540×620pt, inherited from iPad).
/// That box is content-blind: a short form fits, a grouped `List` with a search
/// bar does not — which is why the New Chat and model pickers came out squat and
/// scrolling on a window with room to spare.
///
/// `presentationSizing` is the Mac-idiom equivalent, so this is the missing half
/// of the sizing declaration rather than a workaround.
public enum RipulSheetSize {
    /// Proportional to the window. The right default for anything list-shaped.
    case page
    /// UIKit's compact form box. Only for sheets that really are a short form.
    case form
    /// Shrink-wrapped to the content.
    case fitted
}

private struct RipulSheetPresentation: ViewModifier {
    let size: RipulSheetSize
    let detents: Set<PresentationDetent>?
    let selection: Binding<PresentationDetent>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let detents {
            if let selection {
                sized(content.presentationDetents(detents, selection: selection))
            } else {
                sized(content.presentationDetents(detents))
            }
        } else {
            sized(content)
        }
    }

    /// Catalyst only. iPhone and iPad already size themselves from the detents
    /// above, and applying `presentationSizing` there would be a second,
    /// competing declaration on surfaces the phone is the primary client of.
    @ViewBuilder
    private func sized(_ content: some View) -> some View {
        #if targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            // Switched at the call rather than through a stored `any
            // PresentationSizing`: the sizes are distinct concrete types.
            switch size {
            case .page: content.presentationSizing(.page)
            case .form: content.presentationSizing(.form)
            case .fitted: content.presentationSizing(.fitted)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

public extension View {
    /// One sizing declaration for both idioms: `detents` drive iPhone and iPad,
    /// `size` drives Catalyst. Correct on every platform without an `#if` at the
    /// call site — detents are ignored on the Mac idiom, and the Catalyst sizing
    /// is compiled out everywhere else.
    ///
    /// Use this in place of a bare `.presentationDetents(...)`. Omit `detents`
    /// to fix the Catalyst size while leaving the phone's default page sheet
    /// exactly as it is.
    ///
    /// Deliberately ONE method rather than an overload pair: every member added
    /// to `View` is extra work for the type-checker in every file that imports
    /// this module, and `iOS/ContentView.swift` sits at that budget already.
    func ripulSheet(_ size: RipulSheetSize = .page,
                    detents: Set<PresentationDetent>? = nil,
                    selection: Binding<PresentationDetent>? = nil) -> some View {
        modifier(RipulSheetPresentation(size: size, detents: detents, selection: selection))
    }
}

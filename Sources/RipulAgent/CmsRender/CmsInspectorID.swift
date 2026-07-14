import SwiftUI

/// Native twin of the web's `data-ui` traceability, for the View Explorer.
/// The CMS renderer is pure SwiftUI, so without these the inspector only sees
/// generic `_TtGC7SwiftUI…` hosting views — it can't tell a `recordCards`
/// card from a `kpiStrip` tile. `cmsInspectorID` registers a view with the
/// explorer's spatial registry (iOS) so tapping it reports a meaningful
/// `Cms.<block>.<element>` identifier; on macOS it sets the accessibility
/// identifier only.
///
/// Format mirrors `data-ui`: `Cms.<blockType>.<section>.<element>`, with the
/// block wrapper adding the instance slug so multiple blocks of one type stay
/// distinguishable. Stamp the block wrapper (automatic, bounded) and
/// LOW-COUNT interactive leaves — never per-row in a lazy list (the stamper
/// is a real `UIView`, so high counts would cost scroll performance).
extension View {
    @ViewBuilder
    func cmsInspectorID(_ id: String) -> some View {
        #if os(iOS)
        self.uiKitIdentifier(id)
        #else
        self.accessibilityIdentifier(id)
        #endif
    }
}

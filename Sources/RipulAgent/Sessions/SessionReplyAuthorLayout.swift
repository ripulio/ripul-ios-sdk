import SwiftUI

/// Cap a long author's name without reserving that width for short names.
/// A flexible frame with only maxWidth expands to the proposal, leaving blank
/// space beside the pill while the neighbouring title truncates. This layout
/// reports the child's fitted width and still yields in a narrow chat header.
@available(iOS 16.0, macOS 13.0, *)
struct SessionReplyAuthorLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        return view.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? 160, 160), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

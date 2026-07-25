#if os(iOS)
import UIKit

/// Identifiable wrapper so `.sheet(item:)` carries the URL into the sheet.
public struct InviteSheetItem: Identifiable {
    public let id = UUID()
    public let shareURL: String

    public init(shareURL: String) {
        self.shareURL = shareURL
    }
}

/// Custom UIActivity that appears in the share sheet as "Invite by Email".
/// When tapped, it triggers a callback with the share URL so the host can
/// present the email input sheet.
///
/// Ported verbatim from the native app (`iOS/InviteByEmailActivity.swift`).
public final class InviteByEmailActivity: UIActivity {
    /// Called when the user taps this action — provides the share URL string.
    public var onPerform: ((String) -> Void)?

    private var shareURL: String?

    public override var activityTitle: String? { "Invite by Email" }
    public override var activityImage: UIImage? { UIImage(systemName: "person.badge.plus") }
    public override var activityType: UIActivity.ActivityType? { .init("io.ripul.inviteByEmail") }
    public override class var activityCategory: UIActivity.Category { .action }

    public override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { $0 is URL }
    }

    public override func prepare(withActivityItems activityItems: [Any]) {
        shareURL = activityItems.compactMap { ($0 as? URL)?.absoluteString }.first
    }

    public override func perform() {
        if let url = shareURL {
            onPerform?(url)
        }
        activityDidFinish(true)
    }
}
#endif

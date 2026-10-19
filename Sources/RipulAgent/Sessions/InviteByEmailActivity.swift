#if os(iOS)
import UIKit

/// Identifiable wrapper so `.ripulSheet(item:)` carries the URL into the sheet.
public struct InviteSheetItem: Identifiable {
    public let id = UUID()
    public let shareURL: String
    /// The chat the link is for, when the sheet was opened from that chat:
    /// its People list can then say what each member may use.
    public let chatId: String?

    public init(shareURL: String, chatId: String? = nil) {
        self.shareURL = shareURL
        self.chatId = chatId
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

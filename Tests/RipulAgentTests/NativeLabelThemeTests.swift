#if os(iOS)
import XCTest
import UIKit
@testable import RipulAgent

// Deliberately unrelated app vocabularies: the SDK must discover all names,
// property paths and enum cases, never depend on the motivating host's model.
private enum OfferKind { case promotion, balance }
private struct OfferModel { var kind: OfferKind; var accountName: String = "Never capture user data" }
private final class StorefrontScreen: UIViewController {
    let welcome = UILabel()
    override func viewDidLoad() { super.viewDidLoad(); view.addSubview(welcome) }
}
private final class OfferRow: UITableViewCell {
    let subtitle = UILabel()
    let amount = UILabel()
    var model: OfferModel?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(subtitle); contentView.addSubview(amount)
    }
    required init?(coder: NSCoder) { fatalError("test fixture") }
}
private enum TileCategory { case featured, ordinary }
private struct TileContent { var category: TileCategory }
private final class CatalogueTile: UICollectionViewCell {
    let heading = UILabel()
    var content: TileContent?
    override init(frame: CGRect) { super.init(frame: frame); contentView.addSubview(heading) }
    required init?(coder: NSCoder) { fatalError("test fixture") }
}
private final class PlainRow: UITableViewCell {
    let caption = UILabel()
    var rowKey = ""
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier); contentView.addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError("test fixture") }
}

@MainActor
final class NativeLabelThemeTests: XCTestCase {
    private func start() -> (UIWindow, StorefrontScreen) {
        RipulThemeInstrumentation.install()
        RipulThemeInstrumentation.labelRowContextProvider = nil
        NativeTextRuntime.adopt(NativeTextTheme())
        let controller = StorefrontScreen()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        return (window, controller)
    }
    private func finish(_ window: UIWindow) {
        NativeTextRuntime.adopt(NativeTextTheme())
        RipulThemeInstrumentation.labelRowContextProvider = nil
        RipulThemeEngine.exportThemeDocument = nil
        window.isHidden = true
    }
    private func flushConfiguration() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testIdentifierStrategyWithoutAnOutletAndTextAssignedBeforeIdentity() throws {
        let (window, controller) = start(); defer { finish(window) }
        let label = UILabel(); label.text = "Welcome"
        controller.view.addSubview(label); label.accessibilityIdentifier = "welcome.message"
        let selector = try XCTUnwrap(NativeLabelTheme.capture(label).selector)
        XCTAssertEqual(selector.identifier, "welcome.message"); XCTAssertNil(selector.ownerType)
        NativeLabelTheme.setOverride(selector, text: "Hello")
        XCTAssertEqual(label.text, "Hello")
        label.text = "Updated by the app"
        XCTAssertEqual(label.text, "Hello")
        NativeLabelTheme.setOverride(selector, text: nil)
        XCTAssertEqual(label.text, "Updated by the app")
    }

    func testStoredPropertyStrategyNeedsNoAccessibilityIdentifier() throws {
        let (window, controller) = start(); defer { finish(window) }
        controller.welcome.text = "Greetings"
        let selection = InspectedView.inspect(controller.welcome)
        let selector = try XCTUnwrap(selection.nativeLabelCapture?.selector)
        XCTAssertEqual(selector.ownerType, "StorefrontScreen")
        XCTAssertEqual(selector.property, "welcome"); XCTAssertNil(selector.row)
        NativeLabelTheme.setOverride(selector, text: "Welcome back")
        XCTAssertEqual(controller.welcome.text, "Welcome back")
        XCTAssertTrue(selection.sourceReference().contains("themeText:"))
    }

    func testEnumContextSeparatesRowsAndFieldsAndSurvivesReuse() throws {
        let (window, controller) = start(); defer { finish(window) }
        let offer = OfferRow(), balance = OfferRow()
        offer.model = OfferModel(kind: .promotion); balance.model = OfferModel(kind: .balance)
        offer.subtitle.text = "Invite someone"; offer.amount.text = "£10"
        balance.subtitle.text = "Available balance"
        controller.view.addSubview(offer); controller.view.addSubview(balance)
        let selector = try XCTUnwrap(NativeLabelTheme.capture(offer.subtitle).selector)
        XCTAssertEqual(selector.row?.enums, [.init(path: ["model", "kind"], value: "promotion")])
        let json = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
        XCTAssertFalse(json.contains("accountName")); XCTAssertFalse(json.contains("Never capture"))
        NativeLabelTheme.setOverride(selector, text: "Share an offer")
        XCTAssertEqual(offer.subtitle.text, "Share an offer")
        XCTAssertEqual(balance.subtitle.text, "Available balance"); XCTAssertEqual(offer.amount.text, "£10")
        offer.prepareForReuse()
        XCTAssertEqual(offer.subtitle.text, "Invite someone")
        offer.model = OfferModel(kind: .balance); offer.subtitle.text = "Your money"
        XCTAssertEqual(offer.subtitle.text, "Your money")
        offer.model = OfferModel(kind: .promotion); offer.subtitle.text = "A new invitation"
        XCTAssertEqual(offer.subtitle.text, "Share an offer")
        NativeLabelTheme.setOverride(selector, text: nil)
        XCTAssertEqual(offer.subtitle.text, "A new invitation")
    }

    func testTextBeforeModelAndRecreatedCollectionCellsUseTheSameGenericStrategy() async throws {
        let (window, controller) = start(); defer { finish(window) }
        var original: CatalogueTile? = CatalogueTile()
        original?.content = TileContent(category: .featured); original?.heading.text = "Featured item"
        controller.view.addSubview(original!)
        let selector = try XCTUnwrap(NativeLabelTheme.capture(original!.heading).selector)
        XCTAssertEqual(selector.row?.enums.first?.path, ["content", "category"])
        NativeLabelTheme.setOverride(selector, text: "Staff choice")
        original?.heading.text = "Ordinary item" // configuration writes text before model
        original?.content = TileContent(category: .ordinary)
        await flushConfiguration()
        XCTAssertEqual(original?.heading.text, "Ordinary item")
        original?.removeFromSuperview(); original = nil
        let next = CatalogueTile()
        next.heading.text = "Another featured item"
        next.content = TileContent(category: .featured)
        controller.view.addSubview(next)
        XCTAssertEqual(next.heading.text, "Staff choice")
        next.prepareForReuse()
        XCTAssertEqual(next.heading.text, "Another featured item")
    }

    func testIdentifiedRowsAndOneCentralContextProviderCoverOtherModels() throws {
        let (window, controller) = start(); defer { finish(window) }
        let row = PlainRow(); row.caption.text = "A prompt"; row.rowKey = "offers"
        controller.view.addSubview(row)
        XCTAssertNil(NativeLabelTheme.capture(row.caption).selector, "Arbitrary model strings must not become inferred identities")
        row.accessibilityIdentifier = "row.offers"
        let identified = try XCTUnwrap(NativeLabelTheme.capture(row.caption).selector)
        XCTAssertEqual(identified.row?.identifier, "row.offers")
        NativeLabelTheme.setOverride(identified, text: "Offer copy")
        XCTAssertEqual(row.caption.text, "Offer copy")
        NativeLabelTheme.setOverride(identified, text: nil)
        row.accessibilityIdentifier = nil
        RipulThemeInstrumentation.labelRowContextProvider = { ($0 as? PlainRow)?.rowKey }
        let provided = try XCTUnwrap(NativeLabelTheme.capture(row.caption).selector)
        XCTAssertEqual(provided.row?.context, "offers")
        NativeLabelTheme.setOverride(provided, text: "Central hook copy")
        XCTAssertEqual(row.caption.text, "Central hook copy")
        row.rowKey = "payments"; row.caption.text = "Pay now"
        XCTAssertEqual(row.caption.text, "Pay now")
    }

    func testAmbiguousAndOverlappingTargetsDoNotSilentlyPickOne() throws {
        let (window, controller) = start(); defer { finish(window) }
        let first = UILabel(), second = UILabel()
        first.text = "First"; second.text = "Second"
        first.accessibilityIdentifier = "shared"; second.accessibilityIdentifier = "shared"
        controller.view.addSubview(first)
        let selector = try XCTUnwrap(NativeLabelTheme.capture(first).selector)
        NativeLabelTheme.setOverride(selector, text: "Override")
        controller.view.addSubview(second)
        XCTAssertEqual(first.text, "First"); XCTAssertEqual(second.text, "Second")
        XCTAssertNil(NativeLabelTheme.capture(first).selector)
        second.removeFromSuperview()
        XCTAssertEqual(first.text, "Override")
        controller.welcome.text = "Welcome"
        let outlet = try XCTUnwrap(NativeLabelTheme.capture(controller.welcome).selector)
        controller.welcome.accessibilityIdentifier = "welcome"
        let identifier = try XCTUnwrap(NativeLabelTheme.capture(controller.welcome).selector)
        NativeTextRuntime.adopt(NativeTextTheme(labels: [.init(selector: outlet, text: "One"), .init(selector: identifier, text: "Two")]))
        XCTAssertEqual(controller.welcome.text, "Welcome", "Conflicting strategies must not depend on dictionary order")
    }

    func testAttributedFormattingIsPreservedAndMixedRunsAreNotFlattened() throws {
        let (window, controller) = start(); defer { finish(window) }
        let label = controller.welcome
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 19), .foregroundColor: UIColor.red, .kern: 1.5]
        let original = NSAttributedString(string: "Styled", attributes: attributes)
        label.attributedText = original
        let selector = try XCTUnwrap(NativeLabelTheme.capture(label).selector)
        NativeLabelTheme.setOverride(selector, text: "Changed ✨")
        XCTAssertEqual(label.attributedText?.string, "Changed ✨")
        XCTAssertEqual(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? Double, 1.5)
        NativeLabelTheme.setOverride(selector, text: "")
        XCTAssertEqual(label.text, "")
        NativeLabelTheme.setOverride(selector, text: nil)
        XCTAssertEqual(label.attributedText, original)
        NativeLabelTheme.setOverride(selector, text: "Replacement")
        let mixed = NSMutableAttributedString(string: "Two styles", attributes: attributes)
        mixed.addAttribute(.foregroundColor, value: UIColor.blue, range: NSRange(location: 0, length: 3))
        label.attributedText = mixed
        XCTAssertEqual(label.attributedText, mixed)
        XCTAssertNil(NativeLabelTheme.capture(label).selector)
        XCTAssertNotNil(NativeLabelTheme.capture(label).reason)
    }

    func testManifestAndDraftRoundTripPreservesTabOverrideAndUnknownHostFields() async throws {
        let (window, controller) = start(); defer { finish(window) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        controller.welcome.text = "Welcome"
        let selector = try XCTUnwrap(NativeLabelTheme.capture(controller.welcome).selector)
        let base = Data(#"{"hostExtra":{"keep":true},"nativeTextOverrides":{"tabBarItemTitles":{"tab.existing":"Custom tab"}}}"#.utf8)
        RipulThemeEngine.exportThemeDocument = { $0 ?? base }
        let remote = RipulRemoteThemeClient(url: URL(string: "https://example.com/v1/app-themes/test")!, fallback: base,
            cacheDirectory: folder.appendingPathComponent("cache"), validateAndApply: { data in
                try RipulThemeEngine.applyRemoteDocument(data) { _ in }
            }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start(); remote.stop()
        let path = folder.appendingPathComponent("draft.json")
        try ThemeManagementModel.saveNativeTextDraft(target: .label(selector), text: "Published copy", remote: remote, draftURL: path)
        let capture = try RipulThemeEngine.themeDocumentForPublishing()
        XCTAssertEqual(try NativeTextTheme.decode(document: capture).tabBarItemTitles["tab.existing"], "Custom tab")
        try remote.preview(base)
        XCTAssertEqual(controller.welcome.text, "Welcome")
        let model = ThemeManagementModel(baseURL: URL(string: "https://example.com")!, tokenProvider: { nil }, remote: remote,
            draftURL: path, capture: { try RipulThemeEngine.themeDocumentForPublishing(over: $0) })
        model.start()
        XCTAssertEqual(controller.welcome.text, "Published copy"); XCTAssertTrue(model.canPublish)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: model.data) as? [String: Any])
        XCTAssertNotNil(json["hostExtra"])
        try remote.acceptPublication(RipulThemeManifest(data: model.data, etag: "version"))
        model.close(); remote.stop()
        NativeTextRuntime.adopt(NativeTextTheme())
        let restart = RipulRemoteThemeClient(url: remote.url, fallback: base, cacheDirectory: folder.appendingPathComponent("cache"),
            validateAndApply: { data in try RipulThemeEngine.applyRemoteDocument(data) { _ in } }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try restart.start(); restart.stop()
        XCTAssertEqual(controller.welcome.text, "Published copy")
    }

    func testMalformedSelectorsAreRejectedBeforeHostMutation() throws {
        let (window, _) = start(); defer { finish(window) }
        let invalid = [
            #"{"nativeTextOverrides":{"labels":[{"selector":{"screen":"S"},"text":"x"}]}}"#,
            #"{"nativeTextOverrides":{"labels":[{"selector":{"screen":"S","identifier":"label","row":{"ownerType":"Cell","enums":[]}},"text":"x"}]}}"#,
            #"{"nativeTextOverrides":{"labels":"not an array"}}"#
        ]
        var calls = 0
        for value in invalid {
            XCTAssertThrowsError(try RipulThemeEngine.applyRemoteDocument(Data(value.utf8)) { _ in calls += 1 })
        }
        XCTAssertEqual(calls, 0)
    }

    func testUILabelAdapterDoesNotCaptureButtonInternalsOrPlainUnidentifiedViews() {
        let (window, controller) = start(); defer { finish(window) }
        let button = UIButton(type: .system); button.setTitle("Button", for: .normal)
        controller.view.addSubview(button)
        XCTAssertNil(NativeLabelTheme.capture(button.titleLabel!).selector)
        let label = UILabel(); label.text = "Unidentified"; controller.view.addSubview(label)
        XCTAssertNil(NativeLabelTheme.capture(label).selector)
        let labelWithNil = controller.welcome
        labelWithNil.text = nil
        let selector = NativeLabelTheme.capture(labelWithNil).selector!
        NativeLabelTheme.setOverride(selector, text: "Text")
        NativeLabelTheme.setOverride(selector, text: nil)
        XCTAssertNil(labelWithNil.text)
    }
}
#endif

import XCTest
import SwiftUI
@testable import RipulAgent

/// Parity checks for the portal theme v2 twin (portalTheme.ts deriveBrand,
/// colorTokens.ts, radiusTokens.ts) and the featurePanel / stepProgress
/// prop readers.
final class CmsPortalThemeTests: XCTestCase {
    private func decode(_ json: String) throws -> CmsPortalThemeConfig {
        try JSONDecoder().decode(CmsPortalThemeConfig.self, from: Data(json.utf8))
    }

    private func assertRGBA(_ c: CmsRGBA, _ r: Double, _ g: Double, _ b: Double, _ a: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.r, r, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(c.a, a, accuracy: 0.002, file: file, line: line)
    }

    func testDerivedBrandDefaultsLight() throws {
        let theme = CmsPortalTheme(config: try decode(##"{"palette":{"primary":"#6200ea"}}"##))
        // accent = darken(primary, 0.35): channels × 0.65.
        assertRGBA(theme.accentRGBA, 0x62 / 255.0 * 0.65, 0, 0xea / 255.0 * 0.65, 1)
        // tint = alpha(primary, 0.08) light.
        assertRGBA(theme.tintRGBA, 0x62 / 255.0, 0, 0xea / 255.0, 0.08)
        // surfaceMuted = alpha(text.primary = rgba(0,0,0,.87), 0.035).
        assertRGBA(theme.surfaceMutedRGBA, 0, 0, 0, 0.035)
        XCTAssertEqual(theme.cardRadius, 8)
        XCTAssertEqual(theme.inputRadius, 4)
        XCTAssertEqual(theme.buttonRadius, 4)
        XCTAssertEqual(theme.buttonStyle, "solid")
    }

    func testDarkPaletteLayersOverPalette() throws {
        let config = try decode(##"""
        {"mode":"dark","palette":{"primary":"#112233","accent":"#000000","text":"#eeeeee"},
         "darkPalette":{"primary":"#445566"}}
        """##)
        let theme = CmsPortalTheme(config: config)
        XCTAssertTrue(theme.isDark)
        assertRGBA(theme.primaryRGBA, 0x44 / 255.0, 0x55 / 255.0, 0x66 / 255.0, 1)
        // accent kept from base palette (not overridden by darkPalette).
        assertRGBA(theme.accentRGBA, 0, 0, 0, 1)
        // dark tint/surfaceMuted alphas.
        assertRGBA(theme.tintRGBA, 0x44 / 255.0, 0x55 / 255.0, 0x66 / 255.0, 0.18)
        assertRGBA(theme.surfaceMutedRGBA, 0xee / 255.0, 0xee / 255.0, 0xee / 255.0, 0.06)

        // Light render ignores darkPalette.
        var light = config
        light.mode = "light"
        assertRGBA(CmsPortalTheme(config: light).primaryRGBA, 0x11 / 255.0, 0x22 / 255.0, 0x33 / 255.0, 1)
        // System mode follows the effective scheme.
        light.mode = "system"
        assertRGBA(CmsPortalTheme(config: light, effectiveDark: true).primaryRGBA, 0x44 / 255.0, 0x55 / 255.0, 0x66 / 255.0, 1)
    }

    func testExplicitBrandValuesWin() throws {
        let theme = CmsPortalTheme(config: try decode(##"""
        {"palette":{"primary":"#1976d2","tint":"rgba(25, 118, 210, 0.2)","surfaceMuted":"#f5f5f5"}}
        """##))
        assertRGBA(theme.tintRGBA, 25 / 255.0, 118 / 255.0, 210 / 255.0, 0.2)
        assertRGBA(theme.surfaceMutedRGBA, 0xf5 / 255.0, 0xf5 / 255.0, 0xf5 / 255.0, 1)
    }

    func testRadiusTokens() throws {
        let theme = CmsPortalTheme(config: try decode(##"{"shape":{"borderRadius":6,"buttonRadius":999,"inputRadius":10}}"##))
        XCTAssertEqual(theme.radius("radius.card"), 12)
        XCTAssertEqual(theme.radius("radius.input"), 10)
        XCTAssertEqual(theme.radius("radius.button"), 9999)
        XCTAssertEqual(theme.radius("radius.none"), 0)
        XCTAssertEqual(theme.radius("radius.sm"), 3)
        XCTAssertEqual(theme.radius("radius.md"), 6)
        XCTAssertEqual(theme.radius("radius.lg"), 12)
        XCTAssertEqual(theme.radius("radius.full"), 9999)
        XCTAssertEqual(theme.radius("14px"), 14)
        XCTAssertNil(theme.radius("radius.bogus"))
        // Unset base → MUI default 4.
        XCTAssertEqual(CmsPortalTheme(config: nil).radius("radius.card"), 8)
    }

    func testColorTokens() {
        let theme = CmsPortalTheme(config: nil)
        XCTAssertNotNil(theme.resolve("color.accent"))
        XCTAssertNotNil(theme.resolve("color.tint"))
        XCTAssertNotNil(theme.resolve("color.surfaceMuted"))
        // The gradient is a fill, not a colour.
        XCTAssertNil(theme.resolve("color.gradient"))
        XCTAssertNotNil(theme.fill("color.gradient"))
        XCTAssertNotNil(theme.fill("color.primary"))
        XCTAssertNotNil(CmsCss.color("rgba(0, 0, 0, 0.5)"))
    }

    func testGradientDirection() {
        let p135 = CmsPortalTheme.gradientPoints(angle: 135)
        XCTAssertEqual(p135.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p135.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(p135.end.x, 1, accuracy: 1e-9)
        XCTAssertEqual(p135.end.y, 1, accuracy: 1e-9)
        let p90 = CmsPortalTheme.gradientPoints(angle: 90)
        XCTAssertEqual(p90.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p90.end.x, 1, accuracy: 1e-9)
        XCTAssertEqual(p90.start.y, 0.5, accuracy: 1e-9)
        let p0 = CmsPortalTheme.gradientPoints(angle: 0)
        XCTAssertEqual(p0.start.y, 1, accuracy: 1e-9) // bottom → top
        XCTAssertEqual(p0.end.y, 0, accuracy: 1e-9)
    }

    func testLenientDecodingNeverFailsTheDefinition() throws {
        let config = try decode(##"""
        {"mode":"light","palette":{"primary":42},"typography":{"headingWeight":"800","headingFontFamily":"'Inter', sans-serif"},
         "shape":{"cardRadius":"16"},"buttons":{"style":"gradient","gradientAngle":"oops"}}
        """##)
        XCTAssertNil(config.palette?.primary)
        XCTAssertEqual(config.typography?.headingWeight, 800)
        XCTAssertEqual(config.shape?.cardRadius, 16)
        XCTAssertEqual(config.buttons?.style, "gradient")
        XCTAssertNil(config.buttons?.gradientAngle)
        let theme = CmsPortalTheme(config: config)
        XCTAssertEqual(theme.headingFontFamily, "Inter")
        XCTAssertEqual(theme.headingWeight, .heavy)
        XCTAssertEqual(theme.cardRadius, 16)
        XCTAssertEqual(theme.gradientAngle, 135)
    }

    func testContrastTextMatchesMui() {
        // #1976d2 → white; #90caf9 → rgba(0,0,0,0.87) (MUI defaults).
        XCTAssertEqual(CmsRGBA(css: "#1976d2")!.contrastText, CmsRGBA(r: 1, g: 1, b: 1))
        XCTAssertEqual(CmsRGBA(css: "#90caf9")!.contrastText, CmsRGBA(r: 0, g: 0, b: 0, a: 0.87))
    }

    // MARK: - Blocks

    @MainActor
    func testStepProgressCurrentStep() {
        typealias V = CmsStepProgressBlockView
        let steps = [
            V.Step(label: "Account", pageSlug: "signup", whenValues: ""),
            V.Step(label: "Details", pageSlug: "checkout", whenValues: "details, verify"),
            V.Step(label: "Payment", pageSlug: "checkout", whenValues: "payment"),
        ]
        XCTAssertEqual(V.resolveCurrentStep(steps, pageSlug: "checkout", sourceValue: "payment"), 2)
        XCTAssertEqual(V.resolveCurrentStep(steps, pageSlug: "checkout", sourceValue: "verify"), 1)
        // Unknown source value falls back to the page.
        XCTAssertEqual(V.resolveCurrentStep(steps, pageSlug: "checkout", sourceValue: "done"), 1)
        XCTAssertEqual(V.resolveCurrentStep(steps, pageSlug: "signup", sourceValue: nil), 0)
        XCTAssertEqual(V.resolveCurrentStep(steps, pageSlug: "elsewhere", sourceValue: ""), 0)
        // Absent steps → web defaults; explicit empty array → no steps.
        XCTAssertEqual(V.steps(from: [:]).map(\.label), ["Account", "Payment", "Setup"])
        XCTAssertEqual(V.steps(from: ["steps": .array([])]).count, 0)
    }

    @MainActor
    func testFeaturePanelItems() {
        typealias V = CmsFeaturePanelBlockView
        XCTAssertEqual(V.items(from: [:]).map(\.title), ["Everything included"])
        let items = V.items(from: ["items": .array([
            .object(["title": .string("A"), "detail": .string("")]),
            .object(["title": .string(""), "detail": .string("")]),
            .null,
            .object(["detail": .string("Only detail")]),
        ])])
        XCTAssertEqual(items.map(\.title), ["A", ""])
        XCTAssertEqual(items.last?.detail, "Only detail")
    }
}

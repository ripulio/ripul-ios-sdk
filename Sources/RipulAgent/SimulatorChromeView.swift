// theme-exempt-file: physical simulator hardware bezel and screen cutout artwork uses literal device colours
#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore

/// Builds exact continuous-corner (`kCACornerCurveContinuous`) paths with independent
/// radii for each of the four corners (`topLeft`, `topRight`, `bottomRight`, `bottomLeft`),
/// matching Xcode's `.simdevicetype` framebuffer mask PDFs.
public enum SimulatorChromePath {
    public static func continuousRoundedRect(
        _ rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomRight: CGFloat,
        bottomLeft: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }

        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let halfW = rect.width * 0.5
        let halfH = rect.height * 0.5
        let limit = min(halfW, halfH)

        // Apple's continuous corner tangent extent ratio from DeviceKit's PDF masks.
        let k: CGFloat = 1.2819425
        let lTL = min(max(topLeft, 0) * k, limit)
        let lTR = min(max(topRight, 0) * k, limit)
        let lBR = min(max(bottomRight, 0) * k, limit)
        let lBL = min(max(bottomLeft, 0) * k, limit)

        // Exact 3-segment continuous corner Bézier fractions.
        let fA: CGFloat = 0.652278
        let fB: CGFloat = 0.526186
        let fC: CGFloat = 0.036205
        let fD: CGFloat = 0.399064
        let fE: CGFloat = 0.104191
        let fF: CGFloat = 0.271942
        let fG: CGFloat = 0.172176

        path.move(to: CGPoint(x: minX + lTL, y: minY))

        // Top edge -> Top-Right corner
        path.addLine(to: CGPoint(x: maxX - lTR, y: minY))
        if lTR > 0.01 {
            let L = lTR
            path.addCurve(
                to: CGPoint(x: maxX - fD * L, y: minY + fE * L),
                control1: CGPoint(x: maxX - fA * L, y: minY),
                control2: CGPoint(x: maxX - fB * L, y: minY + fC * L)
            )
            path.addCurve(
                to: CGPoint(x: maxX - fE * L, y: minY + fD * L),
                control1: CGPoint(x: maxX - fF * L, y: minY + fG * L),
                control2: CGPoint(x: maxX - fG * L, y: minY + fF * L)
            )
            path.addCurve(
                to: CGPoint(x: maxX, y: minY + L),
                control1: CGPoint(x: maxX - fC * L, y: minY + fB * L),
                control2: CGPoint(x: maxX, y: minY + fA * L)
            )
        }

        // Right edge -> Bottom-Right corner
        path.addLine(to: CGPoint(x: maxX, y: maxY - lBR))
        if lBR > 0.01 {
            let L = lBR
            path.addCurve(
                to: CGPoint(x: maxX - fE * L, y: maxY - fD * L),
                control1: CGPoint(x: maxX, y: maxY - fA * L),
                control2: CGPoint(x: maxX - fC * L, y: maxY - fB * L)
            )
            path.addCurve(
                to: CGPoint(x: maxX - fD * L, y: maxY - fE * L),
                control1: CGPoint(x: maxX - fG * L, y: maxY - fF * L),
                control2: CGPoint(x: maxX - fF * L, y: maxY - fG * L)
            )
            path.addCurve(
                to: CGPoint(x: maxX - L, y: maxY),
                control1: CGPoint(x: maxX - fB * L, y: maxY - fC * L),
                control2: CGPoint(x: maxX - fA * L, y: maxY)
            )
        }

        // Bottom edge -> Bottom-Left corner
        path.addLine(to: CGPoint(x: minX + lBL, y: maxY))
        if lBL > 0.01 {
            let L = lBL
            path.addCurve(
                to: CGPoint(x: minX + fD * L, y: maxY - fE * L),
                control1: CGPoint(x: minX + fA * L, y: maxY),
                control2: CGPoint(x: minX + fB * L, y: maxY - fC * L)
            )
            path.addCurve(
                to: CGPoint(x: minX + fE * L, y: maxY - fD * L),
                control1: CGPoint(x: minX + fF * L, y: maxY - fG * L),
                control2: CGPoint(x: minX + fG * L, y: maxY - fF * L)
            )
            path.addCurve(
                to: CGPoint(x: minX, y: maxY - L),
                control1: CGPoint(x: minX + fC * L, y: maxY - fB * L),
                control2: CGPoint(x: minX, y: maxY - fA * L)
            )
        }

        // Left edge -> Top-Left corner
        path.addLine(to: CGPoint(x: minX, y: minY + lTL))
        if lTL > 0.01 {
            let L = lTL
            path.addCurve(
                to: CGPoint(x: minX + fE * L, y: minY + fD * L),
                control1: CGPoint(x: minX, y: minY + fA * L),
                control2: CGPoint(x: minX + fC * L, y: minY + fB * L)
            )
            path.addCurve(
                to: CGPoint(x: minX + fD * L, y: minY + fE * L),
                control1: CGPoint(x: minX + fG * L, y: minY + fF * L),
                control2: CGPoint(x: minX + fF * L, y: minY + fG * L)
            )
            path.addCurve(
                to: CGPoint(x: minX + L, y: minY),
                control1: CGPoint(x: minX + fB * L, y: minY + fC * L),
                control2: CGPoint(x: minX + fA * L, y: minY)
            )
        }

        path.closeSubpath()
        return path
    }

    public static func screenPath(_ rect: CGRect, chrome: SimulatorDisplayChrome) -> CGPath {
        continuousRoundedRect(
            rect,
            topLeft: CGFloat(chrome.topLeftRadius),
            topRight: CGFloat(chrome.topRightRadius),
            bottomRight: CGFloat(chrome.bottomRightRadius),
            bottomLeft: CGFloat(chrome.bottomLeftRadius)
        )
    }

    /// Total outsets around the screen in simulator points needed to fit the bezel and side buttons.
    public static func totalOutsets(for chrome: SimulatorDisplayChrome, includesButtonPadding: Bool = true) -> UIEdgeInsets {
        let pad: CGFloat = includesButtonPadding ? 4 : 0
        return UIEdgeInsets(
            top: CGFloat(chrome.bezelTop) + pad,
            left: CGFloat(chrome.bezelLeft) + pad,
            bottom: CGFloat(chrome.bezelBottom) + pad,
            right: CGFloat(chrome.bezelRight) + pad
        )
    }

    /// Outer chassis continuous corner radius in simulator points (screen corner
    /// radius plus the concentric bezel thickness).
    public static func outerChassisRadius(for chrome: SimulatorDisplayChrome) -> CGFloat {
        let radii = outerChassisCornerRadii(for: chrome)
        return max(12, max(radii.topLeft, radii.topRight, radii.bottomRight, radii.bottomLeft))
    }

    /// Per-corner outer chassis continuous radii in simulator points, matching
    /// `SimulatorHardwareChromeLayer`'s outer chassis path.
    public static func outerChassisCornerRadii(
        for chrome: SimulatorDisplayChrome
    ) -> (topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) {
        let hingeEdge = chrome.hingeEdge
        let spineThickness: CGFloat = (hingeEdge != nil) ? 11.0 : 0.0
        let chassisTop = CGFloat(chrome.bezelTop) - (hingeEdge == "top" ? spineThickness : 0)
        let chassisRight = CGFloat(chrome.bezelRight) - (hingeEdge == "right" ? spineThickness : 0)
        let chassisBottom = CGFloat(chrome.bezelBottom) - (hingeEdge == "bottom" ? spineThickness : 0)
        let chassisLeft = CGFloat(chrome.bezelLeft) - (hingeEdge == "left" ? spineThickness : 0)

        let rTL = CGFloat(chrome.topLeftRadius)
        let rTR = CGFloat(chrome.topRightRadius)
        let rBR = CGFloat(chrome.bottomRightRadius)
        let rBL = CGFloat(chrome.bottomLeftRadius)

        let outerTL: CGFloat = (hingeEdge == "left" || hingeEdge == "top") ? 3.0 : (rTL + (chassisTop + chassisLeft) * 0.5)
        let outerTR: CGFloat = (hingeEdge == "right" || hingeEdge == "top") ? 3.0 : (rTR + (chassisTop + chassisRight) * 0.5)
        let outerBR: CGFloat = (hingeEdge == "right" || hingeEdge == "bottom") ? 3.0 : (rBR + (chassisBottom + chassisRight) * 0.5)
        let outerBL: CGFloat = (hingeEdge == "left" || hingeEdge == "bottom") ? 3.0 : (rBL + (chassisBottom + chassisLeft) * 0.5)
        return (outerTL, outerTR, outerBR, outerBL)
    }

    /// Returns the fitted screen rectangle inside `containerSize` when the
    /// simulator's hardware bezel and side-button outsets are included.
    public static func screenRect(
        in containerSize: CGSize,
        screenSize: CGSize,
        chrome: SimulatorDisplayChrome?,
        includesButtonPadding: Bool = true
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0,
              screenSize.width > 0, screenSize.height > 0 else {
            return .zero
        }
        let outsets = chrome.map { totalOutsets(for: $0, includesButtonPadding: includesButtonPadding) } ?? .zero
        let totalW = screenSize.width + outsets.left + outsets.right
        let totalH = screenSize.height + outsets.top + outsets.bottom
        guard totalW > 0, totalH > 0 else { return .zero }
        let scale = min(containerSize.width / totalW, containerSize.height / totalH)
        let originX = (containerSize.width - totalW * scale) * 0.5 + outsets.left * scale
        let originY = (containerSize.height - totalH * scale) * 0.5 + outsets.top * scale
        return CGRect(
            x: originX,
            y: originY,
            width: screenSize.width * scale,
            height: screenSize.height * scale
        )
    }
}

/// Core Animation layer assembly that renders a simulator's physical hardware
/// frame (titanium chassis, metallic rim bevel, inner glass bezel, foldable
/// hinge spine or book crease ticks, side buttons, and Dynamic Island / Notch
/// sensor cutout) in the simulator's point coordinate space.
public final class SimulatorHardwareChromeLayer: CALayer {
    private let shadowLayer = CAShapeLayer()
    private let buttonsLayer = CAShapeLayer()
    private let hingeBodyLayer = CAShapeLayer()
    private let hingeSeamLayer = CAShapeLayer()
    private let chassisOuterLayer = CAShapeLayer()
    private let chassisRimLayer = CAShapeLayer()
    private let innerBezelLayer = CAShapeLayer()
    private let creaseTicksLayer = CAShapeLayer()
    public let overlayLayer = CALayer()
    private let screenRimLayer = CAShapeLayer()
    private let cutoutPillLayer = CAShapeLayer()
    private let cutoutLensOuterLayer = CAShapeLayer()
    private let cutoutLensInnerLayer = CAShapeLayer()

    public override init() {
        super.init()
        setupSublayers()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        setupSublayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupSublayers() {
        zPosition = -10
        overlayLayer.zPosition = 10

        shadowLayer.fillColor = UIColor.black.cgColor
        shadowLayer.shadowColor = UIColor.black.cgColor
        shadowLayer.shadowOpacity = 0.55
        shadowLayer.shadowRadius = 18
        shadowLayer.shadowOffset = CGSize(width: 0, height: 6)

        buttonsLayer.fillColor = UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1).cgColor
        buttonsLayer.strokeColor = UIColor(red: 0.48, green: 0.48, blue: 0.52, alpha: 1).cgColor
        buttonsLayer.lineWidth = 1.0

        hingeBodyLayer.fillColor = UIColor(red: 0.173, green: 0.173, blue: 0.184, alpha: 1).cgColor
        hingeBodyLayer.strokeColor = UIColor(red: 0.494, green: 0.494, blue: 0.518, alpha: 1).cgColor
        hingeBodyLayer.lineWidth = 1.4

        hingeSeamLayer.fillColor = nil
        hingeSeamLayer.strokeColor = UIColor(white: 0.04, alpha: 0.92).cgColor
        hingeSeamLayer.lineWidth = 1.6

        chassisOuterLayer.fillColor = UIColor(red: 0.173, green: 0.173, blue: 0.184, alpha: 1).cgColor
        chassisOuterLayer.strokeColor = UIColor(white: 0.04, alpha: 1).cgColor
        chassisOuterLayer.lineWidth = 1.5

        chassisRimLayer.fillColor = nil
        chassisRimLayer.strokeColor = UIColor(red: 0.494, green: 0.494, blue: 0.518, alpha: 1).cgColor
        chassisRimLayer.lineWidth = 1.4

        innerBezelLayer.fillColor = UIColor.black.cgColor
        innerBezelLayer.strokeColor = UIColor(white: 0.22, alpha: 0.65).cgColor
        innerBezelLayer.lineWidth = 0.8

        creaseTicksLayer.fillColor = UIColor(white: 0.72, alpha: 0.78).cgColor

        screenRimLayer.fillColor = nil
        screenRimLayer.strokeColor = UIColor(white: 1.0, alpha: 0.14).cgColor
        screenRimLayer.lineWidth = 1.0

        cutoutPillLayer.fillColor = UIColor.black.cgColor
        cutoutPillLayer.strokeColor = UIColor(white: 1.0, alpha: 0.08).cgColor
        cutoutPillLayer.lineWidth = 0.75

        cutoutLensOuterLayer.fillColor = UIColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1).cgColor
        cutoutLensOuterLayer.strokeColor = UIColor(red: 0.18, green: 0.21, blue: 0.30, alpha: 0.85).cgColor
        cutoutLensOuterLayer.lineWidth = 0.8

        cutoutLensInnerLayer.fillColor = UIColor(red: 0.22, green: 0.32, blue: 0.52, alpha: 0.45).cgColor

        for sub in [
            shadowLayer, buttonsLayer, hingeBodyLayer, chassisOuterLayer,
            chassisRimLayer, innerBezelLayer, hingeSeamLayer, creaseTicksLayer
        ] {
            addSublayer(sub)
        }
        for sub in [screenRimLayer, cutoutPillLayer, cutoutLensOuterLayer, cutoutLensInnerLayer] {
            overlayLayer.addSublayer(sub)
        }
    }

    public func update(screenBounds: CGRect, chrome: SimulatorDisplayChrome?, omitsDropShadow: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let chrome, screenBounds.width > 0, screenBounds.height > 0 else {
            isHidden = true
            overlayLayer.isHidden = true
            return
        }
        isHidden = false
        overlayLayer.isHidden = false
        shadowLayer.isHidden = omitsDropShadow
        buttonsLayer.isHidden = omitsDropShadow
        frame = screenBounds
        overlayLayer.frame = screenBounds

        let bTop = CGFloat(chrome.bezelTop)
        let bRight = CGFloat(chrome.bezelRight)
        let bBottom = CGFloat(chrome.bezelBottom)
        let bLeft = CGFloat(chrome.bezelLeft)

        let rTL = CGFloat(chrome.topLeftRadius)
        let rTR = CGFloat(chrome.topRightRadius)
        let rBR = CGFloat(chrome.bottomRightRadius)
        let rBL = CGFloat(chrome.bottomLeftRadius)

        // 1. Screen rim highlight along the exact 4-corner display curve
        let screenPath = SimulatorChromePath.continuousRoundedRect(
            screenBounds, topLeft: rTL, topRight: rTR, bottomRight: rBR, bottomLeft: rBL
        )
        screenRimLayer.path = screenPath

        // 2. Chassis & foldable hinge geometry (matching DeviceKit's PhoneComposite.pdf)
        let hingeEdge = chrome.hingeEdge
        let spineThickness: CGFloat = (hingeEdge != nil) ? 11.0 : 0.0

        let chassisTop = bTop - (hingeEdge == "top" ? spineThickness : 0)
        let chassisRight = bRight - (hingeEdge == "right" ? spineThickness : 0)
        let chassisBottom = bBottom - (hingeEdge == "bottom" ? spineThickness : 0)
        let chassisLeft = bLeft - (hingeEdge == "left" ? spineThickness : 0)

        let chassisRect = CGRect(
            x: screenBounds.minX - chassisLeft,
            y: screenBounds.minY - chassisTop,
            width: screenBounds.width + chassisLeft + chassisRight,
            height: screenBounds.height + chassisTop + chassisBottom
        )

        let outerTL: CGFloat = (hingeEdge == "left" || hingeEdge == "top") ? 3.0 : (rTL + (chassisTop + chassisLeft) * 0.5)
        let outerTR: CGFloat = (hingeEdge == "right" || hingeEdge == "top") ? 3.0 : (rTR + (chassisTop + chassisRight) * 0.5)
        let outerBR: CGFloat = (hingeEdge == "right" || hingeEdge == "bottom") ? 3.0 : (rBR + (chassisBottom + chassisRight) * 0.5)
        let outerBL: CGFloat = (hingeEdge == "left" || hingeEdge == "bottom") ? 3.0 : (rBL + (chassisBottom + chassisLeft) * 0.5)

        let outerPath = SimulatorChromePath.continuousRoundedRect(
            chassisRect, topLeft: outerTL, topRight: outerTR, bottomRight: outerBR, bottomLeft: outerBL
        )
        chassisOuterLayer.path = outerPath
        shadowLayer.path = outerPath
        shadowLayer.shadowPath = outerPath

        let rimRect = chassisRect.insetBy(dx: 1.2, dy: 1.2)
        chassisRimLayer.path = SimulatorChromePath.continuousRoundedRect(
            rimRect,
            topLeft: max(2, outerTL - 1.2),
            topRight: max(2, outerTR - 1.2),
            bottomRight: max(2, outerBR - 1.2),
            bottomLeft: max(2, outerBL - 1.2)
        )

        let bandWidth: CGFloat = 4.2
        let innerRect = CGRect(
            x: chassisRect.minX + (hingeEdge == "left" ? 2.0 : bandWidth),
            y: chassisRect.minY + (hingeEdge == "top" ? 2.0 : bandWidth),
            width: chassisRect.width - (hingeEdge == "left" ? 2.0 : bandWidth) - (hingeEdge == "right" ? 2.0 : bandWidth),
            height: chassisRect.height - (hingeEdge == "top" ? 2.0 : bandWidth) - (hingeEdge == "bottom" ? 2.0 : bandWidth)
        )
        innerBezelLayer.path = SimulatorChromePath.continuousRoundedRect(
            innerRect,
            topLeft: (hingeEdge == "left" || hingeEdge == "top") ? 2.5 : max(rTL, outerTL - bandWidth),
            topRight: (hingeEdge == "right" || hingeEdge == "top") ? 2.5 : max(rTR, outerTR - bandWidth),
            bottomRight: (hingeEdge == "right" || hingeEdge == "bottom") ? 2.5 : max(rBR, outerBR - bandWidth),
            bottomLeft: (hingeEdge == "left" || hingeEdge == "bottom") ? 2.5 : max(rBL, outerBL - bandWidth)
        )

        // 3. Foldable hinge spine on the closed iPhone Duo
        if let hingeEdge {
            let spineCapInset: CGFloat = 7.0
            let spineCorner: CGFloat = 6.5
            let seamPath = CGMutablePath()
            let spineRect: CGRect
            let sTL: CGFloat, sTR: CGFloat, sBR: CGFloat, sBL: CGFloat

            switch hingeEdge {
            case "left":
                spineRect = CGRect(
                    x: chassisRect.minX - spineThickness,
                    y: chassisRect.minY + spineCapInset,
                    width: spineThickness + 2,
                    height: chassisRect.height - spineCapInset * 2
                )
                sTL = spineCorner; sBL = spineCorner; sTR = 1; sBR = 1
                seamPath.move(to: CGPoint(x: chassisRect.minX, y: spineRect.minY))
                seamPath.addLine(to: CGPoint(x: chassisRect.minX, y: spineRect.maxY))
            case "right":
                spineRect = CGRect(
                    x: chassisRect.maxX - 2,
                    y: chassisRect.minY + spineCapInset,
                    width: spineThickness + 2,
                    height: chassisRect.height - spineCapInset * 2
                )
                sTL = 1; sBL = 1; sTR = spineCorner; sBR = spineCorner
                seamPath.move(to: CGPoint(x: chassisRect.maxX, y: spineRect.minY))
                seamPath.addLine(to: CGPoint(x: chassisRect.maxX, y: spineRect.maxY))
            case "top":
                spineRect = CGRect(
                    x: chassisRect.minX + spineCapInset,
                    y: chassisRect.minY - spineThickness,
                    width: chassisRect.width - spineCapInset * 2,
                    height: spineThickness + 2
                )
                sTL = spineCorner; sTR = spineCorner; sBL = 1; sBR = 1
                seamPath.move(to: CGPoint(x: spineRect.minX, y: chassisRect.minY))
                seamPath.addLine(to: CGPoint(x: spineRect.maxX, y: chassisRect.minY))
            default: // "bottom"
                spineRect = CGRect(
                    x: chassisRect.minX + spineCapInset,
                    y: chassisRect.maxY - 2,
                    width: chassisRect.width - spineCapInset * 2,
                    height: spineThickness + 2
                )
                sTL = 1; sTR = 1; sBL = spineCorner; sBR = spineCorner
                seamPath.move(to: CGPoint(x: spineRect.minX, y: chassisRect.maxY))
                seamPath.addLine(to: CGPoint(x: spineRect.maxX, y: chassisRect.maxY))
            }
            hingeBodyLayer.path = SimulatorChromePath.continuousRoundedRect(
                spineRect, topLeft: sTL, topRight: sTR, bottomRight: sBR, bottomLeft: sBL
            )
            hingeSeamLayer.path = seamPath
            hingeBodyLayer.isHidden = false
            hingeSeamLayer.isHidden = false
        } else {
            hingeBodyLayer.path = nil
            hingeSeamLayer.path = nil
            hingeBodyLayer.isHidden = true
            hingeSeamLayer.isHidden = true
        }

        // 4. Open foldable book crease ticks (on iPhone Duo open inner display)
        if chrome.foldCreaseAxis != nil {
            let ticks = CGMutablePath()
            if screenBounds.width >= screenBounds.height {
                let midX = screenBounds.midX
                ticks.addRect(CGRect(x: midX - 0.75, y: chassisRect.minY + 1, width: 1.5, height: bTop - 2))
                ticks.addRect(CGRect(x: midX - 0.75, y: screenBounds.maxY + 1, width: 1.5, height: bBottom - 2))
            } else {
                let midY = screenBounds.midY
                ticks.addRect(CGRect(x: chassisRect.minX + 1, y: midY - 0.75, width: bLeft - 2, height: 1.5))
                ticks.addRect(CGRect(x: screenBounds.maxX + 1, y: midY - 0.75, width: bRight - 2, height: 1.5))
            }
            creaseTicksLayer.path = ticks
            creaseTicksLayer.isHidden = false
        } else {
            creaseTicksLayer.path = nil
            creaseTicksLayer.isHidden = true
        }

        // 5. Hardware side buttons rotated by quarterTurnsCCW
        buttonsLayer.path = Self.buttonsPath(chassisRect: chassisRect, chrome: chrome)

        // 6. Sensor cutout (Dynamic Island or Notch) on the active sensor edge
        updateCutout(screenBounds: screenBounds, chrome: chrome)
    }

    private func updateCutout(screenBounds: CGRect, chrome: SimulatorDisplayChrome) {
        guard let kind = chrome.cutoutKind, let edge = chrome.cutoutEdge else {
            cutoutPillLayer.isHidden = true
            cutoutLensOuterLayer.isHidden = true
            cutoutLensInnerLayer.isHidden = true
            return
        }

        if kind == "island" {
            let longSide = min(max(screenBounds.width, screenBounds.height) * 0.13, 122)
            let shortSide: CGFloat = 35
            let edgeInset: CGFloat = 11
            let pillRect: CGRect
            let lensCenter: CGPoint

            switch edge {
            case "top":
                pillRect = CGRect(x: screenBounds.midX - longSide * 0.5, y: screenBounds.minY + edgeInset, width: longSide, height: shortSide)
                lensCenter = CGPoint(x: pillRect.maxX - 18, y: pillRect.midY)
            case "bottom":
                pillRect = CGRect(x: screenBounds.midX - longSide * 0.5, y: screenBounds.maxY - edgeInset - shortSide, width: longSide, height: shortSide)
                lensCenter = CGPoint(x: pillRect.minX + 18, y: pillRect.midY)
            case "left":
                pillRect = CGRect(x: screenBounds.minX + edgeInset, y: screenBounds.midY - longSide * 0.5, width: shortSide, height: longSide)
                lensCenter = CGPoint(x: pillRect.midX, y: pillRect.minY + 18)
            default: // "right"
                pillRect = CGRect(x: screenBounds.maxX - edgeInset - shortSide, y: screenBounds.midY - longSide * 0.5, width: shortSide, height: longSide)
                lensCenter = CGPoint(x: pillRect.midX, y: pillRect.maxY - 18)
            }

            let radius = shortSide * 0.5
            cutoutPillLayer.path = UIBezierPath(roundedRect: pillRect, cornerRadius: radius).cgPath
            cutoutPillLayer.isHidden = false

            let lensR: CGFloat = 5.5
            let lensRect = CGRect(x: lensCenter.x - lensR, y: lensCenter.y - lensR, width: lensR * 2, height: lensR * 2)
            cutoutLensOuterLayer.path = UIBezierPath(ovalIn: lensRect).cgPath
            cutoutLensOuterLayer.isHidden = false

            let glintR: CGFloat = 2.0
            let glintRect = CGRect(x: lensCenter.x - glintR - 1, y: lensCenter.y - glintR - 1, width: glintR * 2, height: glintR * 2)
            cutoutLensInnerLayer.path = UIBezierPath(ovalIn: glintRect).cgPath
            cutoutLensInnerLayer.isHidden = false
        } else if kind == "cornerHole" {
            // Closed iPhone Duo (phone15) circular hole-punch camera (37pt diameter,
            // centered 48pt from the adjacent screen edges).
            let diameter: CGFloat = 37
            let radius = diameter * 0.5
            let centerOffset: CGFloat = 48
            let holeCenter: CGPoint
            switch edge {
            case "topLeft":
                holeCenter = CGPoint(x: screenBounds.minX + centerOffset, y: screenBounds.minY + centerOffset)
            case "bottomLeft":
                holeCenter = CGPoint(x: screenBounds.minX + centerOffset, y: screenBounds.maxY - centerOffset)
            case "bottomRight":
                holeCenter = CGPoint(x: screenBounds.maxX - centerOffset, y: screenBounds.maxY - centerOffset)
            default: // "topRight"
                holeCenter = CGPoint(x: screenBounds.maxX - centerOffset, y: screenBounds.minY + centerOffset)
            }
            let holeRect = CGRect(
                x: holeCenter.x - radius,
                y: holeCenter.y - radius,
                width: diameter,
                height: diameter
            )
            cutoutPillLayer.path = UIBezierPath(ovalIn: holeRect).cgPath
            cutoutPillLayer.isHidden = false

            let lensR: CGFloat = 6.0
            let lensRect = CGRect(x: holeCenter.x - lensR, y: holeCenter.y - lensR, width: lensR * 2, height: lensR * 2)
            cutoutLensOuterLayer.path = UIBezierPath(ovalIn: lensRect).cgPath
            cutoutLensOuterLayer.isHidden = false

            let glintR: CGFloat = 2.2
            let glintRect = CGRect(x: holeCenter.x - glintR - 1.2, y: holeCenter.y - glintR - 1.2, width: glintR * 2, height: glintR * 2)
            cutoutLensInnerLayer.path = UIBezierPath(ovalIn: glintRect).cgPath
            cutoutLensInnerLayer.isHidden = false
        } else if kind == "notch" {
            let notchLong: CGFloat = 164
            let notchShort: CGFloat = 31
            let notchRect: CGRect
            switch edge {
            case "top":
                notchRect = CGRect(x: screenBounds.midX - notchLong * 0.5, y: screenBounds.minY - 2, width: notchLong, height: notchShort + 2)
            case "bottom":
                notchRect = CGRect(x: screenBounds.midX - notchLong * 0.5, y: screenBounds.maxY - notchShort, width: notchLong, height: notchShort + 2)
            case "left":
                notchRect = CGRect(x: screenBounds.minX - 2, y: screenBounds.midY - notchLong * 0.5, width: notchShort + 2, height: notchLong)
            default:
                notchRect = CGRect(x: screenBounds.maxX - notchShort, y: screenBounds.midY - notchLong * 0.5, width: notchShort + 2, height: notchLong)
            }
            cutoutPillLayer.path = UIBezierPath(roundedRect: notchRect, cornerRadius: 14).cgPath
            cutoutPillLayer.isHidden = false
            cutoutLensOuterLayer.isHidden = true
            cutoutLensInnerLayer.isHidden = true
        } else {
            cutoutPillLayer.isHidden = true
            cutoutLensOuterLayer.isHidden = true
            cutoutLensInnerLayer.isHidden = true
        }
    }

    private struct ButtonSpec {
        var edge: String
        var start: CGFloat
        var end: CGFloat
    }

    private static func buttonsPath(chassisRect: CGRect, chrome: SimulatorDisplayChrome) -> CGPath {
        var specs: [ButtonSpec]
        if chrome.hingeEdge != nil {
            // Closed iPhone Duo (phone15): Volume buttons on top, Power on right
            specs = [
                ButtonSpec(edge: "top", start: 0.49, end: 0.59),
                ButtonSpec(edge: "top", start: 0.64, end: 0.74),
                ButtonSpec(edge: "right", start: 0.28, end: 0.39),
            ]
        } else if chrome.foldCreaseAxis != nil {
            // Open iPhone Duo (phone14)
            specs = [
                ButtonSpec(edge: "left", start: 0.14, end: 0.21),
                ButtonSpec(edge: "left", start: 0.23, end: 0.30),
                ButtonSpec(edge: "top", start: 0.28, end: 0.36),
            ]
        } else {
            // Standard iPhone / iPad (phone12)
            specs = [
                ButtonSpec(edge: "left", start: 0.18, end: 0.215),
                ButtonSpec(edge: "left", start: 0.25, end: 0.315),
                ButtonSpec(edge: "left", start: 0.335, end: 0.40),
                ButtonSpec(edge: "right", start: 0.27, end: 0.365),
            ]
        }

        let steps = ((chrome.quarterTurnsCCW % 4) + 4) % 4
        if steps > 0 {
            for _ in 0..<steps {
                specs = specs.map { spec in
                    switch spec.edge {
                    case "top":
                        return ButtonSpec(edge: "left", start: 1 - spec.end, end: 1 - spec.start)
                    case "left":
                        return ButtonSpec(edge: "bottom", start: spec.start, end: spec.end)
                    case "bottom":
                        return ButtonSpec(edge: "right", start: 1 - spec.end, end: 1 - spec.start)
                    default: // "right"
                        return ButtonSpec(edge: "top", start: spec.start, end: spec.end)
                    }
                }
            }
        }

        let path = CGMutablePath()
        let protrude: CGFloat = 3.2
        for spec in specs where spec.edge != chrome.hingeEdge {
            let rect: CGRect
            switch spec.edge {
            case "left":
                let y0 = chassisRect.minY + chassisRect.height * spec.start
                let y1 = chassisRect.minY + chassisRect.height * spec.end
                rect = CGRect(x: chassisRect.minX - protrude, y: y0, width: protrude + 1.5, height: max(8, y1 - y0))
            case "right":
                let y0 = chassisRect.minY + chassisRect.height * spec.start
                let y1 = chassisRect.minY + chassisRect.height * spec.end
                rect = CGRect(x: chassisRect.maxX - 1.5, y: y0, width: protrude + 1.5, height: max(8, y1 - y0))
            case "top":
                let x0 = chassisRect.minX + chassisRect.width * spec.start
                let x1 = chassisRect.minX + chassisRect.width * spec.end
                rect = CGRect(x: x0, y: chassisRect.minY - protrude, width: max(8, x1 - x0), height: protrude + 1.5)
            default: // "bottom"
                let x0 = chassisRect.minX + chassisRect.width * spec.start
                let x1 = chassisRect.minX + chassisRect.width * spec.end
                rect = CGRect(x: x0, y: chassisRect.maxY - 1.5, width: max(8, x1 - x0), height: protrude + 1.5)
            }
            path.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 2.0).cgPath)
        }
        return path
    }
}

/// SwiftUI Shape that clips a view to a `SimulatorDisplayChrome`'s proportional
/// 4-corner continuous radii, scaled from `viewportSize` to the shape's rect.
public struct SimulatorDisplayClipShape: Shape {
    public let chrome: SimulatorDisplayChrome?
    public let viewportSize: CGSize

    public init(chrome: SimulatorDisplayChrome?, viewportSize: CGSize) {
        self.chrome = chrome
        self.viewportSize = viewportSize
    }

    public func path(in rect: CGRect) -> Path {
        guard let chrome else {
            return Path(rect)
        }
        let shortSide = min(rect.width, rect.height)
        let refShort = min(viewportSize.width, viewportSize.height)
        let scale = refShort > 0 ? (shortSide / refShort) : (shortSide / 440.0)
        return Path(
            SimulatorChromePath.continuousRoundedRect(
                rect,
                topLeft: CGFloat(chrome.topLeftRadius) * scale,
                topRight: CGFloat(chrome.topRightRadius) * scale,
                bottomRight: CGFloat(chrome.bottomRightRadius) * scale,
                bottomLeft: CGFloat(chrome.bottomLeftRadius) * scale
            )
        )
    }
}

/// Renders a simulator snapshot `UIImage` inside its full `SimulatorHardwareChromeLayer`
/// (titanium chassis, metallic rim bevel, inner glass bezel, foldable hinge spine or
/// open book crease ticks, side buttons, Dynamic Island / Notch / cornerHole cutout,
/// and chassis drop shadow), scaled from simulator logical points (`viewportSize`)
/// to fit the available SwiftUI frame.
public struct SimulatorChromePreviewSurface: UIViewRepresentable {
    public var image: UIImage?
    public var chrome: SimulatorDisplayChrome
    public var viewportSize: CGSize
    public var omitsDropShadow: Bool

    public init(
        image: UIImage?,
        chrome: SimulatorDisplayChrome,
        viewportSize: CGSize,
        omitsDropShadow: Bool = false
    ) {
        self.image = image
        self.chrome = chrome
        self.viewportSize = viewportSize
        self.omitsDropShadow = omitsDropShadow
    }

    public func makeUIView(context: Context) -> SimulatorChromePreviewUIView {
        SimulatorChromePreviewUIView()
    }

    public func updateUIView(_ uiView: SimulatorChromePreviewUIView, context: Context) {
        uiView.apply(
            image: image,
            chrome: chrome,
            viewportSize: viewportSize,
            omitsDropShadow: omitsDropShadow
        )
    }
}

public final class SimulatorChromePreviewUIView: UIView {
    private let canvasView = UIView()
    private let hardwareChromeLayer = SimulatorHardwareChromeLayer()
    private let screenClipLayer = CALayer()
    private let screenMaskLayer = CAShapeLayer()
    private let imageLayer = CALayer()

    private var currentChrome: SimulatorDisplayChrome = .defaultPhone
    private var currentViewportSize: CGSize = CGSize(width: 393, height: 852)
    private var currentOmitsDropShadow = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = false

        canvasView.backgroundColor = .clear
        canvasView.clipsToBounds = false
        canvasView.isUserInteractionEnabled = false
        addSubview(canvasView)

        screenClipLayer.backgroundColor = UIColor.black.cgColor
        screenClipLayer.zPosition = 0
        imageLayer.contentsGravity = .resize
        screenClipLayer.addSublayer(imageLayer)

        canvasView.layer.addSublayer(hardwareChromeLayer)
        canvasView.layer.addSublayer(screenClipLayer)
        canvasView.layer.addSublayer(hardwareChromeLayer.overlayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(
        image: UIImage?,
        chrome: SimulatorDisplayChrome,
        viewportSize: CGSize,
        omitsDropShadow: Bool
    ) {
        let resolvedSize = (viewportSize.width > 0 && viewportSize.height > 0)
            ? viewportSize
            : CGSize(width: 393, height: 852)
        let geometryChanged =
            currentChrome != chrome ||
            currentViewportSize != resolvedSize ||
            currentOmitsDropShadow != omitsDropShadow

        currentChrome = chrome
        currentViewportSize = resolvedSize
        currentOmitsDropShadow = omitsDropShadow

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image?.cgImage
        CATransaction.commit()

        if geometryChanged {
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              currentViewportSize.width > 0, currentViewportSize.height > 0 else { return }

        let screenBounds = CGRect(origin: .zero, size: currentViewportSize)
        let outsets = SimulatorChromePath.totalOutsets(
            for: currentChrome,
            includesButtonPadding: !currentOmitsDropShadow
        )
        let totalW = screenBounds.width + outsets.left + outsets.right
        let totalH = screenBounds.height + outsets.top + outsets.bottom
        guard totalW > 0, totalH > 0 else { return }

        let scale = min(bounds.width / totalW, bounds.height / totalH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasView.transform = .identity
        canvasView.bounds = screenBounds
        canvasView.center = CGPoint(
            x: bounds.midX + (outsets.left - outsets.right) * 0.5 * scale,
            y: bounds.midY + (outsets.top - outsets.bottom) * 0.5 * scale
        )
        canvasView.transform = CGAffineTransform(scaleX: scale, y: scale)

        screenClipLayer.frame = screenBounds
        imageLayer.frame = screenBounds
        screenMaskLayer.frame = screenBounds
        screenMaskLayer.path = SimulatorChromePath.screenPath(screenBounds, chrome: currentChrome)
        screenClipLayer.mask = screenMaskLayer

        hardwareChromeLayer.update(
            screenBounds: screenBounds,
            chrome: currentChrome,
            omitsDropShadow: currentOmitsDropShadow
        )
        CATransaction.commit()
    }
}
#endif

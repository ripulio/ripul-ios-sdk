import Foundation
import SwiftUI
import RipulThemeKit
import MarkdownUI
import SwiftMath
#if os(iOS)
import UIKit
typealias NativeMathImage = UIImage
typealias NativeMathColor = UIColor
#else
import AppKit
typealias NativeMathImage = NSImage
typealias NativeMathColor = NSColor
#endif

struct NativeMarkdownMathExpression: Codable, Equatable {
    let latex: String
    let display: Bool
    let source: String

    var url: URL {
        let data = try! JSONEncoder().encode(self)
        let token = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "ripul-math://expression/" + token)!
    }

    init(latex: String, display: Bool, source: String) {
        self.latex = latex; self.display = display; self.source = source
    }

    init?(url: URL?) {
        guard let url, url.scheme == "ripul-math", url.host == "expression",
              url.lastPathComponent.utf8.count <= 24_000 else { return nil }
        var token = url.lastPathComponent.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        token += String(repeating: "=", count: (4 - token.count % 4) % 4)
        guard let data = Data(base64Encoded: token), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.latex.utf8.count <= 4_096 else { return nil }
        self = value
    }
}

/// Protect TeX from CommonMark's underscore/backslash rules while parsing the
/// whole document once. Code, image labels, link destinations and escapes stay
/// literal. Unclosed delimiters during streaming remain ordinary source text.
enum NativeMarkdownMath {
    static func prepare(_ source: String) -> String {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else { return source }
        let bytes = Array(source.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var fence: (byte: UInt8, count: Int)?
        func append(to end: Int) { output += bytes[index..<end]; index = end }
        func run(_ at: Int, _ byte: UInt8) -> Int {
            var end = at
            while end < bytes.count, bytes[end] == byte { end += 1 }
            return end - at
        }
        func balancedEnd(_ at: Int, open: UInt8, close: UInt8) -> Int? {
            var depth = 1, cursor = at + 1
            while cursor < bytes.count {
                if bytes[cursor] == 92 { cursor += 2; continue }
                if bytes[cursor] == open { depth += 1 }
                if bytes[cursor] == close { depth -= 1; if depth == 0 { return cursor + 1 } }
                cursor += 1
            }
            return nil
        }
        while index < bytes.count {
            if index == 0 || bytes[index - 1] == 10 {
                let lineEnd = bytes[index...].firstIndex(of: 10) ?? bytes.count
                var start = index
                while start < lineEnd, bytes[start] == 32 || bytes[start] == 9 || bytes[start] == 62 { start += 1 }
                // A fence can also begin immediately inside a list item.
                var markerEnd = start
                while markerEnd < lineEnd, (48...57).contains(bytes[markerEnd]) { markerEnd += 1 }
                if markerEnd < lineEnd, [45, 43, 42, 46, 41].contains(bytes[markerEnd]),
                   markerEnd + 1 < lineEnd, bytes[markerEnd + 1] == 32 {
                    start = markerEnd + 2
                    while start < lineEnd, bytes[start] == 32 { start += 1 }
                }
                if let active = fence {
                    if start < lineEnd, bytes[start] == active.byte, run(start, active.byte) >= active.count {
                        let rest = start + run(start, active.byte)
                        if bytes[rest..<lineEnd].allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { fence = nil }
                    }
                    append(to: min(lineEnd + 1, bytes.count)); continue
                }
                if start < lineEnd, [96, 126].contains(bytes[start]), run(start, bytes[start]) >= 3 {
                    fence = (bytes[start], run(start, bytes[start]))
                    append(to: min(lineEnd + 1, bytes.count)); continue
                }
                let line = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                if line.hasPrefix("    ") || line.hasPrefix("\t") || line.range(of: #"^\s{0,3}\[[^\]]+\]:"#, options: .regularExpression) != nil {
                    append(to: min(lineEnd + 1, bytes.count)); continue
                }
            }
            if bytes[index] == 96 {
                let count = run(index, 96)
                var cursor = index + count, found: Int?
                while cursor < bytes.count {
                    if bytes[cursor] == 96 {
                        let closing = run(cursor, 96)
                        if closing == count { found = cursor + count; break }
                        cursor += closing
                    } else { cursor += 1 }
                }
                append(to: found ?? index + count); continue
            }
            if bytes[index] == 33, index + 1 < bytes.count, bytes[index + 1] == 91,
               let end = balancedEnd(index + 1, open: 91, close: 93) {
                append(to: end); continue
            }
            // Skip link destinations, including balanced parentheses in URLs.
            if bytes[index] == 40, index > 0, bytes[index - 1] == 93,
               let end = balancedEnd(index, open: 40, close: 41) { append(to: end); continue }
            if bytes[index] == 60, let end = bytes[index...].firstIndex(of: 62) { append(to: end + 1); continue }

            let opening: Int
            let closing: [UInt8]
            let display: Bool
            if bytes[index] == 36 {
                opening = index + 1 < bytes.count && bytes[index + 1] == 36 ? 2 : 1
                closing = Array(repeating: 36, count: opening)
                display = opening == 2
            } else if bytes[index] == 92, index + 1 < bytes.count, [40, 91].contains(bytes[index + 1]) {
                opening = 2
                display = bytes[index + 1] == 91
                closing = [92, display ? 93 : 41]
            } else {
                append(to: min(index + (bytes[index] == 92 ? 2 : 1), bytes.count)); continue
            }
            let contentStart = index + opening
            var cursor = contentStart, closingIndex: Int?
            while cursor + closing.count <= bytes.count, cursor - contentStart <= 4_096 {
                if !display, bytes[cursor] == 10 { break }
                if Array(bytes[cursor..<(cursor + closing.count)]) == closing {
                    let end = cursor + closing.count
                    let currency = opening == 1 && end < bytes.count && (48...57).contains(bytes[end])
                    let whitespace = cursor == contentStart || (!display && (isSpace(bytes[contentStart]) || isSpace(bytes[cursor - 1])))
                    if !currency && !whitespace { closingIndex = cursor; break }
                }
                cursor += bytes[cursor] == 92 ? 2 : 1
            }
            guard let end = closingIndex else { append(to: contentStart); continue }
            let latex = String(decoding: bytes[contentStart..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = String(decoding: bytes[index..<(end + closing.count)], as: UTF8.self)
            let expression = NativeMarkdownMathExpression(latex: latex, display: display, source: raw)
            // Entities decode to literal alt text without interpreting TeX's
            // brackets, underscores or backslashes as further Markdown.
            let alt = raw.unicodeScalars.map { "&#\($0.value);" }.joined()
            output += Array("![\(alt)](\(expression.url.absoluteString))".utf8)
            index = end + closing.count
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isSpace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
}

@MainActor
enum NativeMarkdownMathRaster {
    private final class Box: NSObject {
        let image: NativeMathImage
        init(_ image: NativeMathImage) { self.image = image }
    }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func image(_ expression: NativeMarkdownMathExpression, fontSize: CGFloat, color: NativeMathColor) -> NativeMathImage? {
        // Keep malformed or deeply nested streamed expressions readable.
        var depth = 0
        for character in expression.latex {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth < 0 || depth > 64 { return nil }
        }
        guard depth == 0, expression.latex.utf8.count <= 4_096,
              fontSize.isFinite, fontSize > 0, fontSize <= 256 else { return nil }
        let key = "\(expression.display)|\(fontSize)|\(color)|\(expression.latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let renderer = MTMathImage(latex: expression.latex, fontSize: fontSize, textColor: color,
                                   labelMode: expression.display ? .display : .text, textAlignment: .left)
        let sizingLabel = MTMathUILabel(frame: .zero)
        sizingLabel.displayErrorInline = false
        sizingLabel.fontSize = fontSize
        sizingLabel.labelMode = renderer.labelMode
        sizingLabel.latex = expression.latex
        guard sizingLabel.error == nil else { return nil }
        #if os(iOS)
        let size = sizingLabel.intrinsicContentSize
        #else
        let size = sizingLabel.fittingSize
        #endif
        // Bound bitmap allocation before the renderer creates its graphics
        // context. Very large expressions remain readable as their source.
        guard size.width > 0, size.height > 0, size.width <= 8_192, size.height <= 2_048,
              size.width * size.height <= 500_000 else { return nil }
        let (error, image) = renderer.asImage()
        guard error == nil, let image, image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { return nil }
        cache.setObject(Box(image), forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

struct NativeMarkdownMathView: View {
    let expression: NativeMarkdownMathExpression
    let fontSize: CGFloat
    let color: Color
    @Environment(\.self) private var environment

    var body: some View {
        let resolved = color.resolve(in: environment)
        let nativeColor = NativeMathColor(red: CGFloat(resolved.red), green: CGFloat(resolved.green),
                                         blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
        if let raster = NativeMarkdownMathRaster.image(expression, fontSize: fontSize, color: nativeColor) {
            ViewThatFits(in: .horizontal) {
                image(raster).fixedSize()
                ScrollView(.horizontal) { image(raster).fixedSize() }
                    .frame(height: raster.size.height)
            }
        } else {
            Text(expression.source).font(.ripul(size: fontSize, family: .code)).textSelection(.enabled)
        }
    }

    private func image(_ value: NativeMathImage) -> some View {
        Group {
            #if os(iOS)
            Image(uiImage: value)
            #else
            Image(nsImage: value)
            #endif
        }
        // MarkdownUI's image wrapper owns the source/alt accessibility label.
        .accessibilityHidden(true)
    }
}

struct NativeMarkdownMathImageProvider: ImageProvider {
    let fontSize: CGFloat
    let color: Color
    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let expression = NativeMarkdownMathExpression(url: url) {
            NativeMarkdownMathView(expression: expression, fontSize: fontSize, color: color)
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}

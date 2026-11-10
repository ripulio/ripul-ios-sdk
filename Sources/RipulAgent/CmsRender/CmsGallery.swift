import Foundation

// MARK: - The `gallery` block: model and rules
//
// Twin of the web's GalleryBlock.tsx: images and videos as a carousel, a grid,
// a row or masonry. The rules here are the web's (which items show, the grid's
// shapes for one, two and three items, its cap of three rows with "+n" on the
// last tile, the row's cap of three, what counts as a video). Drawing is in
// CmsGalleryBlock.swift, with the system's own controls.

struct CmsGallery: Equatable {
    struct Item: Equatable {
        var src: String
        var alt: String?
        /// A video's still before it plays.
        var poster: String?
        /// Muted inline playback.
        var autoPlay: Bool
        var loop: Bool
        /// The player's controls (default on).
        var controls: Bool

        var isVideo: Bool { CmsGallery.isVideo(src) }
    }

    enum Layout: String { case carousel, grid, row, masonry }

    var items: [Item]
    var layout: Layout
    /// `cover` fills each tile, cropping; `contain` fits the whole picture.
    var fill: Bool
    var gap: Double
    /// Points, or a `radius.*` token for the theme to read.
    var radius: CmsJSON?
    /// 0 = the layout's own height.
    var maxHeight: Double
    var columns: Int

    /// The web's defaults (GalleryBlock.tsx `defaults`). Items without a
    /// `src` are left out, as the web's `validItems`.
    init(_ props: [String: CmsJSON]) {
        items = (props["items"]?.arrayValue ?? []).compactMap { raw -> Item? in
            guard let o = raw.objectValue, let src = o.string("src")?.trimmingCharacters(in: .whitespaces), !src.isEmpty else { return nil }
            return Item(src: src, alt: o.string("alt").flatMap { $0.isEmpty ? nil : $0 },
                        poster: o.string("poster").flatMap { $0.isEmpty ? nil : $0 },
                        autoPlay: o.bool("autoPlay") == true, loop: o.bool("loop") == true,
                        controls: o.bool("controls") ?? true)
        }
        layout = props.string("layoutMode").flatMap(Layout.init(rawValue:)) ?? .grid
        fill = props.string("objectFit") != "contain"
        gap = max(0, props.double("gap") ?? 8)
        radius = props["itemRadius"] ?? .number(4)
        maxHeight = max(0, props.double("maxHeight") ?? 0)
        columns = min(6, max(1, Int(props.double("columns") ?? 3)))
    }

    private static let videoPattern = try! NSRegularExpression(pattern: #"\.(mp4|webm|mov|ogg|m4v)(\?|#|$)"#, options: [.caseInsensitive])

    /// The web's test: the address ends in a video file's extension.
    static func isVideo(_ src: String) -> Bool {
        videoPattern.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) != nil
    }

    /// The grid's shape for its number of items: one wide 16:9 picture, two
    /// squares side by side, three as one tall beside two, else a grid of
    /// `columns` square tiles up to three rows, the last showing "+n" for the rest.
    enum GridShape: Equatable {
        case single
        case pair
        case trio
        case tiles(shown: Int, more: Int)
    }

    var gridShape: GridShape {
        switch items.count {
        case 1: return .single
        case 2: return .pair
        case 3: return .trio
        default:
            let shown = min(items.count, columns * 3)
            return .tiles(shown: shown, more: items.count - shown)
        }
    }

    /// The row shows at most three, side by side.
    var rowItems: [Item] { Array(items.prefix(3)) }

    /// Masonry's columns, filled top to bottom in order as CSS columns fill.
    var masonryColumns: [[Int]] {
        let count = min(columns, max(1, items.count))
        let perColumn = Int((Double(items.count) / Double(count)).rounded(.up))
        return (0..<count).map { c in
            Array(items.indices.dropFirst(c * perColumn).prefix(perColumn))
        }.filter { !$0.isEmpty }
    }

    /// The carousel's height: the web's box takes the shown picture's own shape
    /// at the block's width (`aspect` is its height over width; 4:3 until it has
    /// loaded), at least 200 and at most `maxHeight`, else 500. As Android's.
    func carouselHeight(width: Double, aspect: Double = 0.75) -> Double {
        let most = maxHeight > 0 ? maxHeight : 500
        return min(most, max(200, width * aspect))
    }

    /// The row's height: at most `maxHeight`, else 300 (the web's).
    var rowHeight: Double { maxHeight > 0 ? maxHeight : 300 }

    /// The trio's height: `maxHeight`, else 400 (the web's).
    var trioHeight: Double { maxHeight > 0 ? maxHeight : 400 }
}

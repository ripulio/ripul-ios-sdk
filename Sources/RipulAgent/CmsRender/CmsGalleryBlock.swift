#if os(iOS)
import AVKit
import SwiftUI
import UIKit

/// The `gallery` block, natively: the web's carousel, grid, row and masonry
/// (CmsGallery holds their rules) drawn with the system's own pieces: a paging
/// TabView with its page dots, LazyVGrid, AVPlayer. A tap opens the media full
/// screen, as Photos does: swipe between items, pinch or double-tap to zoom a
/// picture, a video with the system's player controls, swipe down or Done to close.
struct CmsGalleryBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var viewing: CmsGalleryViewing?

    var body: some View {
        let gallery = CmsGallery(runtime.resolvedProps(for: block))
        Group {
            if gallery.items.isEmpty {
                Text("No media items.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(.ripul(.separator)))
            } else {
                layout(gallery)
            }
        }
        .fullScreenCover(item: $viewing) { viewing in
            CmsGalleryViewer(items: gallery.items, start: viewing.index)
        }
        .cmsInspectorID("Cms.gallery")
    }

    private func radius(_ gallery: CmsGallery) -> CGFloat {
        switch gallery.radius {
        case .number(let n)?: return CGFloat(max(0, n))
        case .string(let s)?: return min(runtime.radius(s) ?? 0, 9999)
        default: return 4
        }
    }

    @ViewBuilder
    private func layout(_ gallery: CmsGallery) -> some View {
        let r = radius(gallery)
        let gap = CGFloat(gallery.gap)
        switch gallery.layout {
        case .carousel:
            CmsGalleryCarousel(gallery: gallery, radius: r) { viewing = CmsGalleryViewing(index: $0) }
        case .row:
            HStack(spacing: gap) {
                ForEach(gallery.rowItems.indices, id: \.self) { i in
                    tile(gallery, i, radius: r)
                }
            }
            .frame(height: CGFloat(gallery.rowHeight))
        case .masonry:
            HStack(alignment: .top, spacing: gap) {
                ForEach(gallery.masonryColumns, id: \.self) { column in
                    VStack(spacing: gap) {
                        ForEach(column, id: \.self) { i in
                            tile(gallery, i, radius: r, natural: true)
                        }
                    }
                }
            }
        case .grid:
            grid(gallery, radius: r, gap: gap)
        }
    }

    @ViewBuilder
    private func grid(_ gallery: CmsGallery, radius r: CGFloat, gap: CGFloat) -> some View {
        switch gallery.gridShape {
        case .single:
            tile(gallery, 0, radius: r, aspect: 16.0 / 9.0)
                .frame(maxHeight: gallery.maxHeight > 0 ? CGFloat(gallery.maxHeight) : nil)
        case .pair:
            HStack(spacing: gap) {
                tile(gallery, 0, radius: r, aspect: 1)
                tile(gallery, 1, radius: r, aspect: 1)
            }
        case .trio:
            // Two parts to one: the first tall on the left, two stacked on the right.
            GeometryReader { geo in
                let wide = (geo.size.width - gap) * 2 / 3
                HStack(spacing: gap) {
                    tile(gallery, 0, radius: r).frame(width: wide)
                    VStack(spacing: gap) {
                        tile(gallery, 1, radius: r)
                        tile(gallery, 2, radius: r)
                    }
                }
            }
            .frame(height: CGFloat(gallery.trioHeight))
        case .tiles(let shown, let more):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: gallery.columns), spacing: gap) {
                ForEach(0..<shown, id: \.self) { i in
                    tile(gallery, i, radius: r, aspect: 1)
                        .overlay {
                            if i == shown - 1 && more > 0 {
                                ZStack {
                                    RoundedRectangle(cornerRadius: r, style: .continuous).fill(.black.opacity(0.5)) // theme-exempt: a scrim over a photo
                                    Text("+\(more)")
                                        .font(.ripul(.title2).weight(.bold))
                                        .foregroundStyle(.white) // theme-exempt: on the photo's scrim
                                }
                                .allowsHitTesting(false)
                                .accessibilityLabel("\(more) more")
                            }
                        }
                }
            }
            .frame(maxHeight: gallery.maxHeight > 0 ? CGFloat(gallery.maxHeight) : nil, alignment: .top)
            .clipped()
        }
    }

    /// One item as a tile: tap opens it full screen. The tile's box is laid out
    /// first (a shape at `aspect`, or all the room offered) and the picture is
    /// drawn over it and clipped, so a filling picture never sizes the tile.
    private func tile(_ gallery: CmsGallery, _ index: Int, radius r: CGFloat, natural: Bool = false, aspect: CGFloat? = nil) -> some View {
        let item = gallery.items[index]
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return Button { viewing = CmsGalleryViewing(index: index) } label: {
            Group {
                if natural {
                    CmsGalleryMedia(item: item, fill: false, natural: true)
                } else {
                    Color.ripul(system: .secondarySystemFill)
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: aspect == nil ? .infinity : nil)
                        .overlay { CmsGalleryMedia(item: item, fill: gallery.fill, natural: false) }
                }
            }
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.alt ?? (item.isVideo ? "Video" : "Photo"))
        .accessibilityHint("Opens full screen")
    }
}

struct CmsGalleryViewing: Identifiable {
    let index: Int
    var id: Int { index }
}

/// The carousel: one item at a time in a paging TabView, as the web's: round
/// previous and next arrows over the picture and the page dots below it.
private struct CmsGalleryCarousel: View {
    let gallery: CmsGallery
    let radius: CGFloat
    let open: (Int) -> Void
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var current = 0
    @State private var width: CGFloat = 0
    /// Each picture's height over width, once loaded: the box follows the one shown.
    @State private var aspects: [Int: Double] = [:]

    var body: some View {
        let count = gallery.items.count
        let shown = gallery.items[min(current, count - 1)]
        let aspect = shown.isVideo ? 9.0 / 16.0 : aspects[current] ?? 0.75
        VStack(spacing: 8) {
            TabView(selection: $current) {
                ForEach(gallery.items.indices, id: \.self) { i in
                    Button { open(i) } label: {
                        Color.ripul(system: .secondarySystemFill)
                            .overlay { CmsGalleryMedia(item: gallery.items[i], fill: gallery.fill, natural: false, size: 1200) }
                            .clipped()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(gallery.items[i].alt ?? (gallery.items[i].isVideo ? "Video" : "Photo"))
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: CGFloat(gallery.carouselHeight(width: Double(width), aspect: aspect)))
            .animation(.easeInOut(duration: 0.2), value: aspect)
            .task(id: current) { await measure(current) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if count > 1 {
                    HStack {
                        arrow("chevron.left", label: "Previous photo", enabled: current > 0) { current -= 1 }
                        Spacer()
                        arrow("chevron.right", label: "Next photo", enabled: current < count - 1) { current += 1 }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if count > 1 {
                // The web's MobileStepper dots: 8 pt, 4 apart, the shown one in primary.
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { i in
                        Circle()
                            .fill(i == current ? runtime.theme.primary : Color.black.opacity(0.26)) // theme-exempt: MUI's disabled action colour, the stepper's dot
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(height: 20)
                .accessibilityElement()
                .accessibilityLabel("Photo \(current + 1) of \(count)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if current < count - 1 { withAnimation { current += 1 } }
                    case .decrement: if current > 0 { withAnimation { current -= 1 } }
                    @unknown default: break
                    }
                }
            }
        }
    }

    /// The shown picture's shape, from the picture itself (URLSession's cache keeps it).
    private func measure(_ index: Int) async {
        guard aspects[index] == nil, gallery.items.indices.contains(index), !gallery.items[index].isVideo,
              let image = await CmsGalleryImageLoader.load(gallery.items[index].src), image.size.width > 0 else { return }
        aspects[index] = Double(image.size.height / image.size.width)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, go: @escaping () -> Void) -> some View {
        // The web's small MUI IconButton: a 30 pt circle on a 40% scrim with a 20 pt
        // chevron; at either end disabled as MUI draws it, the scrim gone and the chevron faint.
        Button { withAnimation { go() } } label: {
            Image(systemName: symbol)
                .resizable().scaledToFit()
                .fontWeight(.semibold)
                .frame(width: 12, height: 12)
                .frame(width: 20, height: 20)
                .foregroundStyle(enabled ? Color.white : Color.black.opacity(0.26)) // theme-exempt: over a photo; MUI's disabled action colour
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled ? Color.black.opacity(0.4) : Color.clear)) // theme-exempt: a scrim over a photo
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// One picture or video in a tile. A video plays inline (muted, looping when
/// asked) only with `autoPlay`; otherwise it shows its poster with a play mark.
private struct CmsGalleryMedia: View {
    let item: CmsGallery.Item
    let fill: Bool
    /// Masonry: the picture's own shape at the column's width.
    let natural: Bool
    /// Pixels asked of the image pipeline: a tile's worth, more for the carousel.
    var size = 600

    var body: some View {
        if item.isVideo {
            ZStack {
                if item.autoPlay, let url = URL(string: item.src) {
                    CmsLoopingVideo(url: url, loop: item.loop, fill: fill)
                } else if let poster = item.poster {
                    CmsChainImage(candidates: [.url(poster)], fit: fill ? "cover" : "contain", requestSize: size)
                } else {
                    Color.black // theme-exempt: a video's frame before it has a picture
                }
                if !item.autoPlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35)) // theme-exempt: over a video's picture
                        .accessibilityHidden(true)
                }
            }
            .aspectRatio(natural ? 16.0 / 9.0 : nil, contentMode: .fit)
        } else if natural {
            CmsGalleryNaturalImage(url: item.src)
        } else {
            CmsChainImage(candidates: [.url(item.src)], fit: fill ? "cover" : "contain", requestSize: size)
        }
    }
}

/// A picture at its own shape (masonry): placeholder at 4:3 until it loads.
private struct CmsGalleryNaturalImage: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.ripul(system: .secondarySystemFill).aspectRatio(4.0 / 3.0, contentMode: .fit)
            }
        }
        .task(id: url) { image = await CmsGalleryImageLoader.load(url) }
    }
}

/// A muted inline video, looping when asked, with no controls (the web's
/// product demonstrations).
private struct CmsLoopingVideo: UIViewRepresentable {
    let url: URL
    let loop: Bool
    let fill: Bool

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        if loop { view.looper = AVPlayerLooper(player: player, templateItem: item) }
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
    }
}

// MARK: - Full screen

/// Every item full screen, as Photos shows them: swipe between, pinch or
/// double-tap a picture to zoom, a video in the system's player, Done or a
/// swipe down to close.
struct CmsGalleryViewer: View {
    let items: [CmsGallery.Item]
    @State private var current: Int
    @State private var zoomed = false
    @State private var drag: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(items: [CmsGallery.Item], start: Int) {
        self.items = items
        _current = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(1 - min(0.6, abs(drag) / 600)).ignoresSafeArea() // theme-exempt: full-screen media, as Photos
            TabView(selection: $current) {
                ForEach(items.indices, id: \.self) { i in
                    page(items[i], showing: i == current).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .ignoresSafeArea()
            .offset(y: drag)
            .simultaneousGesture(zoomed ? nil : DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) { drag = value.translation.height }
                }
                .onEnded { value in
                    if abs(value.translation.height) > 120 { dismiss() } else { withAnimation(.spring) { drag = 0 } }
                })
            HStack {
                Button("Done") { dismiss() }
                    .font(.ripul(.body).weight(.semibold))
                    .foregroundStyle(.white) // theme-exempt: over full-screen media
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                if items.count > 1 {
                    Text("\(current + 1) of \(items.count)")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.white) // theme-exempt: over full-screen media
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .opacity(drag == 0 ? 1 : 0)
        }
        .statusBarHidden()
        .accessibilityAction(.escape) { dismiss() }
        .cmsInspectorID("Cms.gallery.viewer")
    }

    @ViewBuilder
    private func page(_ item: CmsGallery.Item, showing: Bool) -> some View {
        if item.isVideo, let url = URL(string: item.src) {
            CmsGalleryVideoPage(url: url, playing: showing)
                .accessibilityLabel(item.alt ?? "Video")
        } else {
            CmsZoomableImage(url: item.src, zoomed: showing ? $zoomed : .constant(false))
                .accessibilityLabel(item.alt ?? "Photo")
                .accessibilityAddTraits(.isImage)
        }
    }
}

/// A video page: the system's player and its controls, playing while shown.
private struct CmsGalleryVideoPage: View {
    let url: URL
    let playing: Bool
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onChange(of: playing, initial: true) { _, now in
                if now { player?.play() } else { player?.pause() }
            }
            .onDisappear { player?.pause() }
    }
}

/// A picture in a UIScrollView: pinch and double-tap zoom, panning when zoomed.
private struct CmsZoomableImage: UIViewRepresentable {
    let url: String
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(zoomed: $zoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 4
        scroll.minimumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
        ])
        spinner.startAnimating()
        Task { @MainActor in
            imageView.image = await CmsGalleryImageLoader.load(url)
            spinner.removeFromSuperview()
        }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        let zoomed: Binding<Bool>
        init(zoomed: Binding<Bool>) { self.zoomed = zoomed }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > 1.01
            if zoomed.wrappedValue != isZoomed { zoomed.wrappedValue = isZoomed }
        }

        @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
            }
        }
    }
}

/// Full-size pictures for the viewer and masonry, through URLSession's cache.
enum CmsGalleryImageLoader {
    static func load(_ address: String) async -> UIImage? {
        guard let url = URL(string: address) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
#endif

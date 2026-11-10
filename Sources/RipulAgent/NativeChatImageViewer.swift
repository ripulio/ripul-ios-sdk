import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The sheet a tapped chat image opens. The image starts fitted inside the
/// sheet with its shape kept, centred. On iPhone, iPad and Catalyst it pinches
/// to zoom, pans once zoomed, and a double tap zooms in on that point or back
/// out to the fit. While it is zoomed a downward drag pans the picture rather
/// than closing the sheet. The Mac host shows the fitted image only.
@available(iOS 16.0, macOS 14.0, *)
struct NativeChatImageZoomSheet: View {
    let attachment: NativeChatImageAttachment
    let onClose: () -> Void
    /// Held once read: the chat redraws the sheet as it streams, and a copy
    /// decoded again after the cache let the first go would fit it again.
    @State private var image: NativeChatImagePreloader.PlatformImage?

    init(attachment: NativeChatImageAttachment, onClose: @escaping () -> Void) {
        self.attachment = attachment
        self.onClose = onClose
        _image = State(initialValue: NativeChatImagePreloader.shared.cachedImage(for: attachment))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.ripul(system: .secondarySystemBackground))
                .navigationTitle(attachment.name ?? "Image")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                            .accessibilityIdentifier("NativeChat.imageViewer.done")
                    }
                }
        }
        .onReceive(NativeChatImagePreloader.shared.keyLoaded) { key in
            // An image fetched by its URL can land after the sheet opened.
            let preloader = NativeChatImagePreloader.shared
            guard image == nil, key == preloader.cacheKey(for: attachment) else { return }
            image = preloader.cachedImage(for: attachment)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            #if os(iOS)
            NativeChatZoomableImage(image: image, label: attachment.name ?? "Attached image")
                // Down to the sheet's edge, as Photos goes; the top stays below the bar.
                .ignoresSafeArea(edges: .bottom)
            #elseif os(macOS)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding()
            #endif
        } else {
            ProgressView()
        }
    }
}

#if os(iOS)
@available(iOS 16.0, *)
struct NativeChatZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String

    func makeUIView(context: Context) -> NativeChatZoomingImageView {
        NativeChatZoomingImageView()
    }

    func updateUIView(_ view: NativeChatZoomingImageView, context: Context) {
        view.show(image, label: label)
    }
}

/// UIKit's zooming scroll view, the one Photos is built on. The image is fitted
/// inside the bounds and centred; it zooms in to eight times that, or to a point
/// per pixel where that is further, and pans only along a dimension larger than
/// the bounds, so no edge of the picture leaves blank space. A fitted image stays
/// fitted through a rotation or a window resize.
final class NativeChatZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    /// The bounds the zoom limits were last worked out for.
    private var limitsSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        accessibilityIdentifier = "NativeChat.imageViewer"
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityIdentifier = "NativeChat.imageViewer.image"
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isZoomed: Bool { zoomScale > minimumZoomScale * 1.001 }

    func show(_ image: UIImage, label: String) {
        imageView.accessibilityLabel = label
        guard imageView.image !== image else { return }
        // Unzoomed before the image view takes the new picture's size.
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        limitsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != limitsSize {
            let wasFitted = limitsSize == .zero || !isZoomed
            limitsSize = bounds.size
            // A small image is enlarged to fit too.
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            maximumZoomScale = max(fit * 8, 1)
            minimumZoomScale = fit
            if wasFitted || zoomScale < fit {
                zoomScale = fit
                contentOffset = .zero
            } else {
                contentOffset = CGPoint(
                    x: min(max(contentOffset.x, 0), max(0, contentSize.width - bounds.width)),
                    y: min(max(contentOffset.y, 0), max(0, contentSize.height - bounds.height))
                )
            }
        }
        centreImage()
    }

    /// A dimension smaller than the bounds is centred; a larger one starts at
    /// the content's edge, so panning reaches both of its edges.
    private func centreImage() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        imageView.center = CGPoint(x: contentSize.width / 2 + x, y: contentSize.height / 2 + y)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centreImage()
        // Zoomed, a drag in any direction is the picture's, as in Photos. Without
        // this, a downward drag along a dimension that still fits went to the
        // sheet and closed it. Fitted, the picture cannot scroll, so a swipe
        // down closes the sheet as before.
        alwaysBounceVertical = isZoomed
        alwaysBounceHorizontal = isZoomed
    }

    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // In far enough to fill the bounds, and at least twice the fit.
        let fill = max(bounds.width / size.width, bounds.height / size.height)
        let scale = min(maximumZoomScale, max(fill, minimumZoomScale * 2))
        let point = tap.location(in: imageView)
        let centre = CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
        let width = bounds.width / scale
        let height = bounds.height / scale
        zoom(to: CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height), animated: true)
    }
}
#endif

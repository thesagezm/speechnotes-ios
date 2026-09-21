import SwiftUI
import SpeechLogic

/// Full-screen image viewer for the reader's tapped images.
///
/// Why this is a `UIScrollView` and not SwiftUI gestures: the previous
/// implementation applied `scaleEffect` + `offset` driven by a
/// `MagnificationGesture` and a `DragGesture`, and it felt wrong in every
/// way the user reported. A SwiftUI magnification gesture has no inertia —
/// it jumps to the gesture's ratio and stops dead when the fingers do — and
/// `scaleEffect` scales around the view's CENTER, so the point under the
/// fingers walked away as you pinched. `UIScrollView` has both: a
/// decelerating zoom with a real anchor point, and a pan that keeps the
/// content under the finger.
///
/// The bridge is deliberately thin — the scroll view owns zoom, pan, double
/// tap and the zoom clamping; SwiftUI only hands it an image and reports
/// taps so the sheet can dismiss.
struct ZoomableImageView: View {
    let url: URL
    let alt: String

    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ImageZoomScrollView(image: image, alt: alt) {
                    dismiss()
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .task {
            // Read through the shared image cache (decode off main) instead of
            // AsyncImage, which used to re-read the file from disk each time.
            if let warmed = ImageCache.shared.peek(url) {
                self.image = warmed
                return
            }
            self.image = await Task.detached(priority: .userInitiated) {
                ImageCache.shared.image(for: url)
            }.value
        }
        .accessibilityLabel(alt)
        .accessibilityAddTraits(image == nil ? [] : .isImage)
    }
}

/// The UIKit half: one `UIScrollView` with the image as its content, zoom
/// clamped to 1…5, double-tap-to-zoom at the tap point, and a single-tap
/// callback for dismissal. All the behaviour that makes pinch-zoom feel
/// physical lives here, where it already exists.
private struct ImageZoomScrollView: UIViewRepresentable {
    let image: UIImage
    let alt: String
    var onTap: () -> Void

    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 5.0

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        // A photo viewer should never bounce past the image's own edges —
        // the rubber-band effect is what made the old one feel cheap.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        // The image view is the content; the scroll view frames it.
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityLabel = alt
        imageView.accessibilityTraits = .image
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        // Double tap zooms toward the tapped point (1 -> 2.5 -> 1), which is
        // the convention every photo app on the platform uses.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        // The single tap must wait for the double tap to fail, or the sheet
        // would dismiss on the first tap of every double tap.
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        // The scroll view has already laid its content out once by now, so
        // the zoom limits and centering can be set against real bounds.
        context.coordinator.layoutContent(in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onTap: () -> Void
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
        }

        /// Recomputes the zoom limits for the current bounds and keeps the
        /// image centred whenever it is smaller than the viewport.
        func layoutContent(in scrollView: UIScrollView) {
            guard let imageView, imageView.image != nil else { return }
            scrollView.minimumZoomScale = Self.minZoom
            scrollView.maximumZoomScale = Self.maxZoom
            scrollView.zoomScale = Self.minZoom
            centerContent(in: scrollView)
        }

        /// Centres the image in the viewport. Without this a zoomed-out
        /// image sits in the top-left corner, which is the other half of why
        /// the old viewer felt unfinished.
        private func centerContent(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let insetHorizontal = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
            let insetVertical = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: insetVertical,
                left: insetHorizontal,
                bottom: insetVertical,
                right: insetHorizontal
            )
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let next: CGFloat = scrollView.zoomScale > Self.minZoom + 0.01 ? Self.minZoom : 2.5
            if next == Self.minZoom {
                scrollView.setZoomScale(Self.minZoom, animated: true)
                return
            }
            // Zoom toward the tapped point so the detail the user pointed at
            // is the detail they get.
            let point = recognizer.location(in: imageView)
            let rect = zoomRect(for: scrollView, scale: next, center: point)
            scrollView.zoom(to: rect, animated: true)
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            // A tap while zoomed in zooms back out; a tap at rest dismisses.
            if scrollView.zoomScale > Self.minZoom + 0.01 {
                scrollView.setZoomScale(Self.minZoom, animated: true)
            } else {
                onTap()
            }
        }

        /// The rectangle a zoom-to-scale should show so that `center` stays
        /// put on screen — the arithmetic the old scaleEffect never did.
        private func zoomRect(for scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2
            )
            return CGRect(origin: origin, size: size)
        }
    }
}

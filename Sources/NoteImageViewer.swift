import SwiftUI

/// What a tapped preview image hands to the full-screen viewer. A resolved file (plus the
/// already-decoded inline image for an instant start) when the inline preview loaded it;
/// otherwise just the reference and the vault context for the wiki-style fallback search.
struct NoteImageTarget: Identifiable {
    let id = UUID()
    /// The original Markdown source — displayed while loading, and the fallback key for
    /// whole-vault resolution.
    let source: String
    /// Remote image (http/https).
    var remoteURL: URL? = nil
    /// Resolved local file, when already known synchronously.
    var localURL: URL? = nil
    var documentURL: URL? = nil
    var vaultRootURL: URL? = nil
    /// The inline preview's downsampled image — shown immediately, then replaced by the
    /// full-size decode.
    var placeholder: PlatformImage? = nil
}

/// Full-screen zoomable viewer for an image tapped in a note's preview.
/// Pinch to zoom, drag to pan, double-tap (double-click) to toggle 1×/zoomed.
struct NoteImageViewer: View {
    let target: NoteImageTarget

    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40))
                    Text("Cannot load image")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.85))
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(.trailing, 20)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("Close Image Viewer")
        }
        .onAppear {
            // The inline preview's downsampled image keeps the viewer from flashing empty.
            if image == nil {
                image = target.placeholder
            }
        }
        .task { await load() }
        .accessibilityLabel("Image preview: \(target.source)")
    }

    private func load() async {
        if let remote = target.remoteURL {
            await loadRemote(remote)
            return
        }
        var resolved = target.localURL
        if resolved == nil, let documentURL = target.documentURL, let rootURL = target.vaultRootURL {
            let source = target.source
            resolved = await Task.detached(priority: .utility) {
                VaultStore.resolveImageURL(source, relativeTo: documentURL, rootURL: rootURL)
            }.value
        }
        guard let resolved else {
            failed = image == nil
            return
        }
        let loaded = await VaultImageLoader.image(for: resolved,
                                                  maxPixelSize: VaultImageLoader.fullSizeMaxPixelSize)
        if let loaded {
            image = loaded
        } else if image == nil {
            failed = true
        }
    }

    private func loadRemote(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = PlatformImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

#if os(iOS)
/// UIScrollView-backed zooming: native pinch, pan and bounce, with a double-tap toggle.
private struct ZoomableImage: UIViewRepresentable {
    let image: PlatformImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.layout(in: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView, imageView.image !== image else { return }
        imageView.image = image
        context.coordinator.layout(in: scrollView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        /// Aspect-fits the image into the scroll view's bounds and resets the zoom.
        func layout(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            let size = image.size
            guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return }
            let fitScale = min(bounds.width / size.width, bounds.height / size.height)
            let fitSize = CGSize(width: size.width * fitScale, height: size.height * fitScale)
            imageView.frame = CGRect(origin: CGPoint(x: (bounds.width - fitSize.width) / 2,
                                                     y: (bounds.height - fitSize.height) / 2),
                                     size: fitSize)
            scrollView.zoomScale = 1
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView else { return }
            let bounds = scrollView.bounds.size
            // Keep the image centered along any axis where it is smaller than the viewport.
            imageView.frame.origin.x = imageView.frame.width < bounds.width
                ? (bounds.width - imageView.frame.width) / 2 : 0
            imageView.frame.origin.y = imageView.frame.height < bounds.height
                ? (bounds.height - imageView.frame.height) / 2 : 0
        }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let location = gesture.location(in: imageView)
            let zoomSize = CGSize(width: scrollView.bounds.width / 2.5,
                                  height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(origin: CGPoint(x: location.x - zoomSize.width / 2,
                                                       y: location.y - zoomSize.height / 2),
                                       size: zoomSize), animated: true)
        }
    }
}
#else
/// macOS zooming: trackpad/scroll pinch via MagnificationGesture, drag to pan when zoomed,
/// double-click to reset.
private struct ZoomableImage: View {
    let image: PlatformImage

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let magnification = MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                scale = min(max(scale * value, 1), 8)
                if scale == 1 { offset = .zero }
            }
        let pan = DragGesture()
            .updating($drag) { value, state, _ in
                // Panning only means something once the image is larger than the viewport.
                state = scale > 1 ? value.translation : .zero
            }
            .onEnded { value in
                guard scale > 1 else { return }
                offset = CGSize(width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height)
            }

        Image(platformImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale * pinch)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(magnification.simultaneously(with: pan))
            .onTapGesture(count: 2) {
                scale = 1
                offset = .zero
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

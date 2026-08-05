import SwiftUI

/// Renders a small thumbnail for a captured image file.
///
/// Decoding happens off the main thread via `CaptureImageProcessor` (ImageIO
/// downsampling), so a list of large captures never blocks scrolling or holds
/// full-resolution bitmaps in memory. `.task(id:)` re-loads if the URL changes
/// and cancels automatically when the row scrolls away.
struct ThumbnailView: View {
    let url: URL
    var maxPixelSize: CGFloat = 300

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .clipped()
        .task(id: url) {
            // Decode off the main actor; `thumbnail` is a pure function.
            let size = maxPixelSize
            let decoded = await Task.detached(priority: .utility) {
                CaptureImageProcessor.thumbnail(fromFileAt: url, maxPixelSize: size)
            }.value
            image = decoded
        }
    }
}

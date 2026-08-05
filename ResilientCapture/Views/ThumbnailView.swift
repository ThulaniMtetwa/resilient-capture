import SwiftUI

/// Renders a small thumbnail for a captured image.
///
/// The image is provided by an async loader (which decrypts and downsamples off
/// the main actor), so a list of large captures never blocks scrolling, and
/// plaintext bytes live only in memory. `.task(id:)` reloads if the identity
/// changes and cancels when the row scrolls away. Shows a placeholder when the
/// image is absent (for example after it has been minimised away post-upload).
struct ThumbnailView: View {
    let reloadKey: AnyHashable
    let load: () async -> UIImage?

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
        .task(id: reloadKey) {
            image = await load()
        }
    }
}

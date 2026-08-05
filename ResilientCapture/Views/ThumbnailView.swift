import SwiftUI

/// A squircle thumbnail for a captured image.
///
/// Decoding happens off the main actor (the loader decrypts + downsamples), so a
/// list of large captures never blocks scrolling and plaintext lives only in
/// memory. `.task(id:)` reloads on identity change and cancels when scrolled away.
/// Uses continuous corners and a hairline stroke for a crisp, native feel; shows a
/// neutral placeholder when the image is absent (e.g. minimised after upload).
struct ThumbnailView: View {
    let reloadKey: AnyHashable
    let load: () async -> UIImage?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 13

    @State private var image: UIImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: size * 0.36))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.separator, lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .task(id: reloadKey) {
                image = await load()
            }
    }
}

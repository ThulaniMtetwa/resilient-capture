import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Memory-efficient image handling for the capture pipeline.
///
/// Modern phone cameras produce 12-48 MP images; decoding one full-resolution
/// `UIImage` just to shrink it can spike memory by tens of MB per capture. Every
/// operation here uses **ImageIO thumbnailing**, which decodes straight to the
/// target size without ever materialising the full bitmap - the "sound
/// memory-management around image processing" the brief asks for.
///
/// This is pure, side-effect-free logic, so it is a plain namespace with no
/// protocol: there is nothing to substitute in a test.
enum CaptureImageProcessor {
    /// Downsample arbitrary image bytes (HEIC/PNG/JPEG) to a bounded-size JPEG
    /// suitable for upload. Caps the largest dimension and re-encodes so the
    /// backend always receives a predictable format and size.
    ///
    /// Returns `nil` only if the bytes aren't a decodable image; callers fall
    /// back to the original data so a capture is never dropped over a resize.
    static func downsampledJPEGData(
        from data: Data,
        maxPixelSize: CGFloat = 2048,
        compressionQuality: CGFloat = 0.85
    ) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        guard let cgImage = Self.thumbnail(from: source, maxPixelSize: maxPixelSize) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Load a small thumbnail from in-memory (decrypted) image bytes without
    /// decoding at full size. Used to render list rows cheaply; the bytes are the
    /// decrypted capture, so plaintext never touches disk for a thumbnail.
    static func thumbnail(from data: Data, maxPixelSize: CGFloat = 300) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        guard let cgImage = Self.thumbnail(from: source, maxPixelSize: maxPixelSize) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Private

    private static func thumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bake in EXIF orientation so downstream consumers see an upright image.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Process-wide cache for decoded vault images.
///
/// Keyed by absolute path + modification date + target pixel size, so an edited or replaced
/// attachment is never served from a stale entry. `NSCache` evicts under memory pressure,
/// which matters on iPhone where a note can embed many photos.
final class VaultImageCache: @unchecked Sendable {
    static let shared = VaultImageCache()

    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(forKey key: NSString) -> PlatformImage? {
        cache.object(forKey: key)
    }

    func store(_ image: PlatformImage, forKey key: NSString) {
        cache.setObject(image, forKey: key, cost: image.approximateCostInBytes)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Loads local attachment images for the preview / attachment viewer.
///
/// Two things make this more than a `Data(contentsOf:)`:
/// * it reads through `VaultFileAccess`, so an iCloud placeholder image is downloaded instead
///   of showing up as permanently blank; and
/// * it downsamples to the size actually needed with ImageIO, so a 12 MP photo in a note does
///   not become a full-size decode on every appearance.
enum VaultImageLoader {
    /// Longest edge, in pixels, kept for an inline note image. Notes render at most ~720pt
    /// wide; 2048px keeps a 2× display crisp without decoding a full-resolution photo.
    static let inlineMaxPixelSize: CGFloat = 2048
    /// Full-screen attachment viewer.
    static let fullSizeMaxPixelSize: CGFloat = 4096

    static func image(for url: URL, maxPixelSize: CGFloat) async -> PlatformImage? {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = VaultImageCache.shared.image(forKey: key) { return cached }

        guard let data = try? await VaultFileAccess.shared.readData(at: url) else { return nil }
        let target = maxPixelSize
        let decoded = await Task.detached(priority: .utility) {
            downsample(data, maxPixelSize: target)
        }.value
        guard let decoded else { return nil }
        VaultImageCache.shared.store(decoded, forKey: key)
        return decoded
    }

    static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(url.standardizedFileURL.path)|\(modificationDate)|\(Int(maxPixelSize))" as NSString
    }

    /// Decodes a thumbnail at `maxPixelSize` without ever materialising the full-size bitmap.
    private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Not an image ImageIO understands (e.g. some SVG/PDF attachments): fall back to
            // the platform decoder so behaviour stays no worse than before.
            return PlatformImage(data: data)
        }
        return PlatformImage.from(cgImage: thumbnail)
    }
}

extension PlatformImage {
    var approximateCostInBytes: Int {
        #if canImport(UIKit)
        guard let cgImage = cgImage else { return 0 }
        #else
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        #endif
        return cgImage.bytesPerRow * cgImage.height
    }
}

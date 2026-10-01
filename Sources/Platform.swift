import CoreGraphics
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Build a SwiftUI `Image` from raw image data on any Apple platform.
    init?(platformData data: Data) {
        guard let image = PlatformImage(data: data) else { return nil }
        self.init(platformImage: image)
    }

    /// Build a SwiftUI `Image` from an already-decoded platform image.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self = Image(uiImage: platformImage)
        #elseif canImport(AppKit)
        self = Image(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Wrap a `CGImage` produced by ImageIO (e.g. a downsampled thumbnail).
    static func from(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// JPEG encoding for the vision-capable image endpoint, on either platform.
    func jpegDataForUpload(compressionQuality: Double) -> Data? {
        #if canImport(UIKit)
        return jpegData(compressionQuality: compressionQuality)
        #elseif canImport(AppKit)
        guard let cgImage = ocrCGImage else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .jpeg,
                                             properties: [.compressionFactor: compressionQuality])
        #else
        return nil
        #endif
    }

    /// JPEG encoding for what lands in the vault. The picture is drawn through the platform
    /// image first — a raw `cgImage` carries sensor pixels without the EXIF orientation, so
    /// encoding from it stored camera photos sideways. Drawing bakes the orientation in, and
    /// the white backing flattens alpha (which JPEG cannot carry) instead of the encoders'
    /// black. Encoding happens at the image's oriented pixel size.
    func jpegDataForStorage(compressionQuality: Double) -> Data? {
        #if canImport(UIKit)
        let orientedSize = size
        guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: orientedSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: orientedSize))
            draw(in: CGRect(origin: .zero, size: orientedSize))
        }
        return rendered.jpegData(compressionQuality: compressionQuality)
        #elseif canImport(AppKit)
        let orientedSize = size
        guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }
        // Target pixels: the raw bitmap's resolution, swapped when the image is rotated
        // (`size` is orientation-aware, the raw `cgImage` is not).
        let rawSize = ocrCGImage.map { CGSize(width: $0.width, height: $0.height) } ?? orientedSize
        let sameAspect = (orientedSize.width > orientedSize.height) == (rawSize.width > rawSize.height)
        let pixelSize = sameAspect ? rawSize : CGSize(width: rawSize.height, height: rawSize.width)
        let canvas = CGRect(origin: .zero, size: pixelSize)
        guard let context = CGContext(data: nil,
                                      width: max(1, Int(pixelSize.width)),
                                      height: max(1, Int(pixelSize.height)),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                          ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        // Draw the NSImage itself (not its raw cgImage) so the EXIF orientation is baked
        // into the pixels, over a white backing for the alpha JPEG cannot carry.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(canvas)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: NSRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        guard let flattened = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: flattened)
        return representation.representation(using: .jpeg,
                                             properties: [.compressionFactor: compressionQuality])
        #else
        return nil
        #endif
    }
}

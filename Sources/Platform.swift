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

    /// JPEG encoding for what lands in the vault. JPEG cannot carry alpha, and the platform
    /// encoders composite transparent regions onto black — a transparent-window screenshot
    /// would be stored with a black background. The picture is therefore drawn over white
    /// first, at its own pixel dimensions, and only then encoded.
    func jpegDataForStorage(compressionQuality: Double) -> Data? {
        guard let cgImage = ocrCGImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let context = CGContext(data: nil,
                                      width: cgImage.width,
                                      height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                          ?? cgImage.colorSpace
                                          ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(canvas)
        context.draw(cgImage, in: canvas)
        guard let flattened = context.makeImage() else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: flattened).jpegData(compressionQuality: compressionQuality)
        #elseif canImport(AppKit)
        let representation = NSBitmapImageRep(cgImage: flattened)
        return representation.representation(using: .jpeg,
                                             properties: [.compressionFactor: compressionQuality])
        #else
        return nil
        #endif
    }
}

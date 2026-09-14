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
}

import CoreGraphics
import XCTest
@testable import ClipNest

/// The vault's attachment storage format: every capture image is encoded once, on capture,
/// into JPEG at the storage quality — so a vault of screenshots and photos stays small. The
/// encoding flattens transparency onto white first, because JPEG cannot carry alpha and the
/// platform encoders would otherwise composite it onto black.
final class ImageStorageTests: XCTestCase {
    func testStorageEncodingProducesJPEGBytes() throws {
        let image = TestImageFactory.make()
        let data = try XCTUnwrap(image.jpegDataForStorage(compressionQuality: 0.5))
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF],
                       "the storage encoding is JPEG, whatever the source was")
    }

    func testStorageEncodingFlattensTransparencyOntoWhite() throws {
        // A fully transparent canvas — the case a transparent-window screenshot hits.
        let context = CGContext(data: nil,
                                width: 2,
                                height: 2,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let transparent = PlatformImage.from(cgImage: context.makeImage()!)

        let data = try XCTUnwrap(transparent.jpegDataForStorage(compressionQuality: 0.5))
        let pixel = try XCTUnwrap(samplePixel(of: data))
        XCTAssertGreaterThanOrEqual(pixel.r, 240)
        XCTAssertGreaterThanOrEqual(pixel.g, 240)
        XCTAssertGreaterThanOrEqual(pixel.b, 240)
    }

    func testStorageQualityShrinksALargeOriginal() throws {
        let image = Self.makeNoiseImage()
        let full = try XCTUnwrap(image.jpegDataForStorage(compressionQuality: 1.0))
        let stored = try XCTUnwrap(image.jpegDataForStorage(compressionQuality: 0.5))
        XCTAssertLessThan(Double(stored.count), Double(full.count) * 0.9,
                          "half-quality storage encoding must actually save space")
    }

    /// Deterministic noise: the worst case for JPEG, so the quality saving it shows here is
    /// a floor for real screenshots and photos.
    private static func makeNoiseImage(width: Int = 256, height: Int = 256) -> PlatformImage {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
            bytes[index + 1] = UInt8(truncatingIfNeeded: seed >> 41)
            bytes[index + 2] = UInt8(truncatingIfNeeded: seed >> 49)
            bytes[index + 3] = 255
        }
        let context = CGContext(data: &bytes,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return PlatformImage.from(cgImage: context.makeImage()!)
    }

    /// Decodes the bytes and averages the picture into a single RGBA pixel.
    private func samplePixel(of data: Data) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let image = PlatformImage(data: data),
              let cgImage = image.ocrCGImage,
              let context = CGContext(data: &pixel,
                                      width: 1,
                                      height: 1,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}

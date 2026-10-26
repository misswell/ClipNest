#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO

func fail(_ message: String) -> Never {
    fputs("\(message)\nUsage: prepare-macos-runtime-icons.swift INPUT.png OUTPUT.png\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count == 3 else { fail("Expected input and output paths") }
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
guard let source = CGImageSourceCreateWithURL(inputURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Unable to read source image") }
guard image.width == image.height else { fail("Source image must be square") }

let side = image.width
let canvas = CGRect(x: 0, y: 0, width: side, height: side)
let tileSide = CGFloat(side) * 0.825
let tile = CGRect(x: (CGFloat(side) - tileSide) / 2, y: (CGFloat(side) - tileSide) / 2, width: tileSide, height: tileSide)
let radius = tileSide * 0.22
guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("Unable to create context") }
context.clear(canvas)
context.interpolationQuality = .high
context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.clip()
context.draw(image, in: tile)
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL, "public.png" as CFString, 1, nil) else { fail("Unable to create output") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fail("Unable to write output") }
print("Wrote \(side)x\(side) tile at 0.825 scale with alpha rounded corners: \(outputURL as URL)")

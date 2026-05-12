import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconDirectory = URL(fileURLWithPath: "Zelmux/Sources/Assets.xcassets/AppIcon.appiconset")
let sourceURL = iconDirectory.appendingPathComponent("AppIcon-ios-marketing-1024x1024@1x.png")
let legacySourceURL = iconDirectory.appendingPathComponent("AppIcon-1024.png")

struct IconSlot {
    let idiom: String
    let size: String
    let scale: String

    var pixelSize: Int {
        let pointSize = Double(size.split(separator: "x")[0]) ?? 1024
        let multiplier = Double(scale.dropLast()) ?? 1
        return Int((pointSize * multiplier).rounded())
    }

    var filename: String {
        let normalizedSize = size.replacingOccurrences(of: ".", with: "_")
        return "AppIcon-\(idiom)-\(normalizedSize)@\(scale).png"
    }

    var contentsEntry: [String: String] {
        [
            "filename": filename,
            "idiom": idiom,
            "scale": scale,
            "size": size,
        ]
    }
}

let slots = [
    IconSlot(idiom: "iphone", size: "20x20", scale: "2x"),
    IconSlot(idiom: "iphone", size: "20x20", scale: "3x"),
    IconSlot(idiom: "iphone", size: "29x29", scale: "2x"),
    IconSlot(idiom: "iphone", size: "29x29", scale: "3x"),
    IconSlot(idiom: "iphone", size: "40x40", scale: "2x"),
    IconSlot(idiom: "iphone", size: "40x40", scale: "3x"),
    IconSlot(idiom: "iphone", size: "60x60", scale: "2x"),
    IconSlot(idiom: "iphone", size: "60x60", scale: "3x"),
    IconSlot(idiom: "ipad", size: "20x20", scale: "1x"),
    IconSlot(idiom: "ipad", size: "20x20", scale: "2x"),
    IconSlot(idiom: "ipad", size: "29x29", scale: "1x"),
    IconSlot(idiom: "ipad", size: "29x29", scale: "2x"),
    IconSlot(idiom: "ipad", size: "40x40", scale: "1x"),
    IconSlot(idiom: "ipad", size: "40x40", scale: "2x"),
    IconSlot(idiom: "ipad", size: "76x76", scale: "1x"),
    IconSlot(idiom: "ipad", size: "76x76", scale: "2x"),
    IconSlot(idiom: "ipad", size: "83.5x83.5", scale: "2x"),
    IconSlot(idiom: "ios-marketing", size: "1024x1024", scale: "1x"),
]

func loadSourceImage() throws -> CGImage {
    let url = FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : legacySourceURL
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "ZelmuxIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not read \(url.path)",
        ])
    }
    return image
}

func resizedOpaquePNG(from image: CGImage, pixelSize: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "ZelmuxIcon", code: 2)
    }

    context.interpolationQuality = .high
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

    guard let resized = context.makeImage() else {
        throw NSError(domain: "ZelmuxIcon", code: 3)
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "ZelmuxIcon", code: 4)
    }
    CGImageDestinationAddImage(destination, resized, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ZelmuxIcon", code: 5)
    }
    return data as Data
}

let sourceImage = try loadSourceImage()
try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)

for slot in slots {
    let data = try resizedOpaquePNG(from: sourceImage, pixelSize: slot.pixelSize)
    try data.write(to: iconDirectory.appendingPathComponent(slot.filename), options: [.atomic])
}

let contents: [String: Any] = [
    "images": slots.map(\.contentsEntry),
    "info": [
        "author": "xcode",
        "version": 1,
    ],
]
let contentsData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try contentsData.write(to: iconDirectory.appendingPathComponent("Contents.json"), options: [.atomic])

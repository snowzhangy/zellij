import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: "ZellijAgent/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func polygon(_ points: [(Double, Double)], fill: NSColor) {
    let path = NSBezierPath()
    guard let first = points.first else { return }
    path.move(to: NSPoint(x: first.0, y: size - first.1))
    for point in points.dropFirst() {
        path.line(to: NSPoint(x: point.0, y: size - point.1))
    }
    path.close()
    fill.setFill()
    path.fill()
}

func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
}

image.lockFocus()

color(0, 0, 0).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let dark = color(12, 5, 28)
let blue = color(130, 165, 194)
let green = color(169, 194, 150)
let red = color(196, 95, 105)
let yellow = color(241, 211, 139)

polygon([(512, 0), (1024, 293), (1024, 884), (512, 1024), (0, 884), (0, 293)], fill: dark)

polygon([(87, 316), (273, 214), (302, 217), (321, 284), (291, 332), (174, 397), (160, 429), (160, 748), (145, 802), (96, 826), (80, 842), (67, 824), (65, 802), (65, 355)], fill: red)
polygon([(96, 840), (180, 803), (267, 853), (276, 883), (277, 950), (260, 953), (95, 858)], fill: green)
polygon([(329, 881), (489, 976), (519, 982), (610, 938), (584, 987), (502, 1024), (317, 923), (309, 890)], fill: green)
polygon([(571, 1024), (681, 894), (813, 815), (857, 782), (860, 760), (878, 765), (945, 836), (932, 860), (760, 960), (581, 1024)], fill: green)

polygon([(330, 172), (480, 80), (489, 84), (496, 162), (476, 202), (368, 268), (359, 270), (343, 264), (325, 193)], fill: green)
polygon([(520, 81), (542, 78), (784, 216), (789, 239), (709, 281), (657, 261), (542, 191), (520, 150)], fill: green)

polygon([(754, 299), (823, 260), (861, 271), (950, 324), (958, 343), (947, 389), (868, 436), (858, 386), (744, 314)], fill: yellow)
polygon([(891, 452), (947, 428), (960, 439), (959, 515), (947, 538), (873, 558), (861, 548), (858, 500), (869, 473)], fill: yellow)
polygon([(879, 586), (937, 574), (956, 586), (957, 795), (943, 799), (866, 710), (862, 619)], fill: yellow)

polygon([(492, 218), (532, 218), (796, 399), (813, 430), (813, 747), (796, 773), (532, 929), (492, 929), (217, 773), (203, 745), (203, 430), (218, 399)], fill: blue)

let glyph = dark
let chevron = NSBezierPath()
chevron.lineWidth = 52
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: 350, y: size - 454))
chevron.line(to: NSPoint(x: 472, y: size - 574))
chevron.line(to: NSPoint(x: 350, y: size - 687))
glyph.setStroke()
chevron.stroke()
roundedRect(NSRect(x: 505, y: size - 658, width: 203, height: 52), radius: 12, fill: glyph)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render icon")
}

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL)

// generate-appicon.swift
//
// Draws the Manuscript Editor app icon with CoreGraphics and fills the
// AppIcon.appiconset with every macOS size.  Design: a white manuscript page
// on an indigo→blue gradient squircle, with a lineage fork (Source → two
// cuts) branching from the page — the app's signature concept.
//
// Run from the repo root:  swift scripts/generate-appicon.swift

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let iconsetURL = URL(fileURLWithPath: "ManuscriptEditor/ManuscriptEditor/Assets.xcassets/AppIcon.appiconset")

// MARK: - Drawing (1024 pt master)

func drawMaster() -> CGImage {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Apple's macOS icon grid: a 824 pt rounded rect centered in 1024,
    // corner radius ~185, with the rest transparent margin.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Plate shadow for lift on light backgrounds.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.17, blue: 0.38, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Indigo → blue vertical gradient.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.32, green: 0.51, blue: 0.98, alpha: 1),   // #528BFA top
        CGColor(red: 0.13, green: 0.22, blue: 0.55, alpha: 1),   // #21388C bottom
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])

    // Subtle top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 620),
                           options: [])

    // ── The manuscript page (left of center) ────────────────────────────────
    let page = CGRect(x: 236, y: 268, width: 340, height: 470)
    let pagePath = CGPath(roundedRect: page, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(pagePath)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Text lines on the page (blue-gray, rounded caps).
    ctx.setFillColor(CGColor(red: 0.42, green: 0.52, blue: 0.72, alpha: 1))
    let lineX = page.minX + 44
    let lineW = page.width - 88
    var lineY = page.maxY - 78
    // Title line: thicker, darker, shorter.
    ctx.setFillColor(CGColor(red: 0.16, green: 0.25, blue: 0.5, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: lineX, y: lineY, width: lineW * 0.62, height: 30),
                       cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.fillPath()
    lineY -= 64
    ctx.setFillColor(CGColor(red: 0.55, green: 0.64, blue: 0.8, alpha: 1))
    for i in 0..<5 {
        let w = i == 4 ? lineW * 0.45 : lineW
        ctx.addPath(CGPath(roundedRect: CGRect(x: lineX, y: lineY, width: w, height: 22),
                           cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.fillPath()
        lineY -= 56
    }

    // ── The lineage fork (right side): page → source node → two cuts ────────
    let stroke = CGColor(gray: 1, alpha: 0.95)
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)

    let start = CGPoint(x: page.maxX + 8, y: 503)     // off the page edge
    let hub = CGPoint(x: 692, y: 503)
    let top = CGPoint(x: 800, y: 640)
    let bottom = CGPoint(x: 800, y: 366)

    ctx.beginPath()
    ctx.move(to: start)
    ctx.addLine(to: hub)
    ctx.strokePath()

    for end in [top, bottom] {
        ctx.beginPath()
        ctx.move(to: hub)
        ctx.addCurve(to: end,
                     control1: CGPoint(x: hub.x + 60, y: hub.y),
                     control2: CGPoint(x: end.x - 60, y: end.y))
        ctx.strokePath()
    }

    // Nodes: hub filled, cuts as rings (they're derived, not the source).
    ctx.setFillColor(stroke)
    ctx.fillEllipse(in: CGRect(x: hub.x - 34, y: hub.y - 34, width: 68, height: 68))
    for end in [top, bottom] {
        ctx.setFillColor(CGColor(red: 0.13, green: 0.22, blue: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: end.x - 34, y: end.y - 34, width: 68, height: 68))
        ctx.setLineWidth(22)
        ctx.strokeEllipse(in: CGRect(x: end.x - 30, y: end.y - 30, width: 60, height: 60))
    }

    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Scale + write

func writePNG(_ image: CGImage, side: Int, name: String) {
    let ctx = CGContext(data: nil, width: side, height: side,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let out = ctx.makeImage()!
    let url = iconsetURL.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name) (\(side)px)")
}

let master = drawMaster()
let slots: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for slot in slots {
    writePNG(master, side: slot.pt * slot.scale, name: "icon_\(slot.pt)x\(slot.pt)\(slot.scale == 2 ? "@2x" : "").png")
}

// Contents.json — macOS slots only, pointing at the generated files.
let entries = slots.map { slot in
    """
        {
          "filename" : "icon_\(slot.pt)x\(slot.pt)\(slot.scale == 2 ? "@2x" : "").png",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.pt)x\(slot.pt)"
        }
    """
}.joined(separator: ",\n")
let contents = """
{
  "images" : [
\(entries)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try contents.write(to: iconsetURL.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
print("wrote Contents.json")

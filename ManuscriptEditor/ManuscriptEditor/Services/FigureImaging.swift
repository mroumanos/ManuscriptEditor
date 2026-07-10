// FigureImaging.swift
//
// Applies a figure's crop + scale to its source image.  Shared by the figure
// thumbnails/editor previews and by ExportService when rendering the final
// image files into a submission package — so what you see is what exports.

import AppKit

enum FigureImaging {

    /// Applies a normalized crop (origin top-left, 0–1), a percent resize, and
    /// an optional grayscale conversion.
    /// Returns the original image when nothing applies or processing fails.
    static func processed(_ image: NSImage, crop: CGRect?, scalePercent: Double?,
                          monochrome: Bool? = nil) -> NSImage {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }

        if let crop, crop.width > 0.01, crop.height > 0.01 {
            let pixelRect = CGRect(x: crop.minX * CGFloat(cg.width),
                                   y: crop.minY * CGFloat(cg.height),
                                   width: crop.width * CGFloat(cg.width),
                                   height: crop.height * CGFloat(cg.height))
            if let cropped = cg.cropping(to: pixelRect.integral) { cg = cropped }
        }

        if monochrome == true, let gray = grayscale(cg) { cg = gray }

        var out = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))

        if let scalePercent, scalePercent < 99.5 {
            let factor = max(scalePercent, 5) / 100
            let size = NSSize(width: CGFloat(cg.width) * factor,
                              height: CGFloat(cg.height) * factor)
            let scaled = NSImage(size: size)
            scaled.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            out.draw(in: NSRect(origin: .zero, size: size))
            scaled.unlockFocus()
            out = scaled
        }
        return out
    }

    /// Redraws into a grayscale context — journals often require B&W figures;
    /// converting at render time keeps the Data-library original untouched.
    private static func grayscale(_ cg: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// True when the figure needs re-rendering on export (vs a plain file copy).
    static func needsRendering(_ figure: Figure) -> Bool {
        figure.crop != nil || (figure.scalePercent ?? 100) < 99.5 || figure.monochrome == true
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

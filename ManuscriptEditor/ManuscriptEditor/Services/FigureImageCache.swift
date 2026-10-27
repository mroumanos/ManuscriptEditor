// FigureImageCache.swift
//
// Figure files, decoded once.
//
// The Figures pane loaded every figure from disk and ran it through
// `FigureImaging.processed` (crop, grayscale) inside `body` — on every
// render of every card, and in the crop editor on every change.  For a
// vector SVG that is ~18 ms a card; for an SVG wrapping a raster (what a
// plot exported from a design tool usually is) ~130 ms, and ~150 ms per
// crop commit.  So: the file is decoded once per (path, modification date,
// size) — an SVG rasterized once at a size no pane needs more of — and each
// processed result is kept by its crop and monochrome setting.  Thumbnails
// then cost nothing to render, and the crop editor draws a bitmap.
//
// A PNG copy on disk would buy only the first decode after a relaunch, at
// the price of a derived file to keep in step with its source (and in the
// remote); the original file stays the export's source either way.

import AppKit

enum FigureImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    /// The longest side a decoded figure is kept at: enough for any pane,
    /// a fraction of a 300 dpi print file's pixels.
    static let maxDimension: CGFloat = 2400

    /// The figure as a bitmap — decoded, and rasterized when it is a vector.
    static func bitmap(for url: URL) -> NSImage? {
        guard let key = fileKey(url) else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let loaded = NSImage(contentsOf: url),
              loaded.size.width > 0, loaded.size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(loaded.size.width, loaded.size.height))
        let size = NSSize(width: max(1, (loaded.size.width * scale).rounded()),
                          height: max(1, (loaded.size.height * scale).rounded()))
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        loaded.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        // CGImage-backed: `cgImage(forProposedRect:)` is then a lookup, not
        // a rasterization — which is what `FigureImaging.processed` starts
        // with.
        guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return canvas }
        let bitmap = NSImage(cgImage: cg, size: size)
        cache.setObject(bitmap, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        return bitmap
    }

    /// The figure as it prints — cropped, in grayscale when asked — from
    /// the bitmap, kept per setting.
    static func processed(for url: URL, crop: CGRect?, monochrome: Bool?) -> NSImage? {
        guard let fileKey = fileKey(url) else { return nil }
        let key = "\(fileKey)|\(crop.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "full")|\(monochrome == true)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let bitmap = bitmap(for: url) else { return nil }
        let made = FigureImaging.processed(bitmap, crop: crop, scalePercent: nil, monochrome: monochrome)
        cache.setObject(made, forKey: key, cost: Int(made.size.width * made.size.height * 4))
        return made
    }

    /// Path, modification date and size: a re-import under the same name
    /// is a different key.
    private static func fileKey(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        return "\(url.path)|\(modified)|\(size)"
    }
}

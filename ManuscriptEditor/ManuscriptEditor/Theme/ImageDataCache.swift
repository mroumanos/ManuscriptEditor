// ImageDataCache.swift
//
// Decoded images, by the bytes they came from.
//
// A view that decodes its image data in `body` decodes it on every render —
// and the letter pane renders on every keystroke.  A letterhead SVG with a
// raster inside it (a logo exported from a design tool is usually that)
// took ~100 ms to decode and draw each time; the same image as a cached
// bitmap takes ~1.5 ms.  So: decoded once here, and when the bytes are a
// vector, rasterized once at a size no slot will exceed — an SVG-backed
// NSImage re-rasterizes on every draw otherwise.

import AppKit

enum ImageDataCache {
    private static let cache: NSCache<NSData, NSImage> = {
        let c = NSCache<NSData, NSImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// The image for these bytes — the cached one when it has been seen.
    static func image(for data: Data, maxDimension: CGFloat = 1200) -> NSImage? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let decoded = NSImage(data: data),
              decoded.size.width > 0, decoded.size.height > 0 else { return nil }
        let image = isVector(data) ? rasterized(decoded, maxDimension: maxDimension) : decoded
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    /// SVG bytes: an XML document whose root is `<svg`.
    static func isVector(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }

    private static func rasterized(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let bitmap = NSImage(size: size)
        bitmap.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        bitmap.unlockFocus()
        return bitmap
    }
}

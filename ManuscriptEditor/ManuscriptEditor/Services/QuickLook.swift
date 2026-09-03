// QuickLook.swift
//
// Previewing an uploaded export document.
//
// An attachment is whatever the author handed us — a PDF, a Word file, a
// spreadsheet, an image — so previewing it is the system's job, not ours.
// Quick Look renders every type Finder can and shows its own "no preview
// available" for the rest, which means there is no list of supported types
// here to drift out of date.

import AppKit
import QuickLookUI

@MainActor
enum QuickLook {

    /// Opens the shared Quick Look panel on one file.
    static func preview(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        source.url = url as NSURL
        guard let panel = QLPreviewPanel.shared() else {
            // No panel (headless, or Quick Look unavailable): opening the
            // file is a worse preview but better than nothing happening.
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = source
        panel.reloadData()
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// One long-lived data source: the panel is shared and keeps an
    /// unowned reference, so this must outlive any single preview.
    private static let source = Source()

    private final class Source: NSObject, QLPreviewPanelDataSource {
        var url: NSURL?

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            url == nil ? 0 : 1
        }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            url
        }
    }
}

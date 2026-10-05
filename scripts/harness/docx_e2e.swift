import Foundation
import AppKit
@testable import ManuscriptEditor

// End to end: a manuscript with a table, a letter with a logo, and line
// numbering, exported to Word through the real export path.
@MainActor func run() {
    var m = Manuscript.new()
    m.title = "Docx Probe"
    if let i = m.sections.firstIndex(where: { $0.title == "Introduction" }) {
        m.sections[i].content = RichText(plain: "First paragraph of the introduction.\nSecond paragraph.")
    }
    m.abstract = RichText(plain: "An abstract of a few words.")
    let table = try! JSONDecoder().decode(ManuscriptTable.self, from: Data(#"""
    {"id":"0B4D9B6C-0000-4000-8000-0000000000A1","number":1,"title":"Counts by group","caption":"A caption.",
     "content":"| Group | N | Share |\n|---|---|---|\n| Alpha | 10 | 40% |\n| Beta | 15 | 60% |","footnotes":"",
     "tableAlign":"center","tableWidthPercent":80}
    """#.utf8))
    m.tables = [table]

    // A letter with a logo on the left and an address on the right.
    let logo = NSImage(size: NSSize(width: 120, height: 40), flipped: false) { r in
        NSColor.systemRed.setFill(); r.fill(); return true
    }
    let png = NSBitmapImageRep(data: logo.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    var details = LetterDetails()
    details.headerLeft = LetterHeaderSlot(imageData: png)
    details.headerRight = LetterHeaderSlot(text: "Shuo Jim Huang\nPhD MPH")
    m.sections.append(ManuscriptSection(id: UUID(), type: .custom, title: "Letter to the Editor",
                                        content: RichText(plain: "Dear Editor,\n\nPlease consider this."),
                                        order: m.sections.count, active: true, kind: .letter, letter: details))

    var config = ExportConfig.standard(content: m, journal: nil)
    for d in config.documents.indices {
        config.documents[d].fileType = .docx
        config.documents[d].format.fontFamily = .times
        config.documents[d].format.fontSize = 12
        config.documents[d].format.lineSpacing = 2
        config.documents[d].format.lineNumbers = true
        config.documents[d].format.pageNumbers = true
    }
    let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("out")
    try? FileManager.default.removeItem(at: out)
    try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let folder = try! ExportService().exportPackage(config: config, content: m, packageName: "Probe",
                                                    figureURL: { _ in nil }, into: out)
    print("exported:", folder.path)
    for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] { print("  ", f) }
}
MainActor.assumeIsolated { run() }

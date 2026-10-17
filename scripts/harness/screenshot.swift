import Foundation
@testable import ManuscriptEditor

// Builds a scratch project for screenshot.sh — a manuscript with one
// journal cut from the bundled JAMA Research Letter, a little text, and a
// section the template doesn't name — in the folder given as the first
// argument.  Nobody's manuscript is touched: the folder is a temporary one
// and the library is the scratch one (MANUSCRIPT_EDITOR_LIBRARY_ROOT).
@MainActor func run() {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = JournalProfileLibrary.shared
    library.load()
    guard let source = library.profile(name: "JAMA", articleType: "Research Letter") else {
        print("no bundled JAMA Research Letter"); exit(1)
    }
    let store = ManuscriptStore()
    store.createNew(in: root)
    store.updateTitle("A Harness Manuscript on Sleep and Shift Work")
    var template = Journal.empty()
    template.id = UUID()
    template.name = source.name; template.articleType = source.articleType
    template.templateName = source.name; template.templateChecksum = source.checksum
    template.profileID = source.id
    template.publisher = source.publisher ?? ""
    template.sourceRequirements = source.requirements
    template.checkRules = source.checks
    template.structure = source.structure
    template.configOrigin = source.origin
    guard let journal = store.addJournalCut(template: template, fromJournalID: nil, viewConfigID: nil),
          let head = store.latestVersion(forJournal: journal.id) else { print("no cut"); exit(1) }
    if var intro = store.manuscript(for: .version(head.id))?.sections.first(where: { $0.title == "Introduction" }) {
        intro.content = RichText(plain: "Shift work disrupts circadian rhythm, and the consequences for sleep are well documented. This cut introduces the question for a research letter.")
        store.updateSection(intro, ref: .version(head.id))
    }
    _ = store.addSection(type: .custom, title: "Extra Notes", kind: .text)
    store.trySave()
    print(store.manuscript!.id.uuidString)
}
MainActor.assumeIsolated { run() }

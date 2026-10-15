import Foundation
@testable import ManuscriptEditor

// A journal's parts are editable inside a manuscript; the edits travel in
// the manuscript's own copy of the template; and the copy reads as diverged
// — from the template it came from, and from the shared repository's copy.
// Also: a library refuses a second template under one name and type.
//
// The library is pointed at a scratch folder (MANUSCRIPT_EDITOR_LIBRARY_ROOT)
// so saving and cloning here touch nobody's templates.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "PASS  \(label)" : "FAIL  \(label)  \(detail)"); if !ok { failures += 1 }
}

@MainActor func run() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("me-divergence-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = JournalProfileLibrary.shared
    library.load()
    check("the library is the scratch one", library.root.path.hasPrefix(ProcessInfo.processInfo.environment["MANUSCRIPT_EDITOR_LIBRARY_ROOT"] ?? "/nowhere"), library.root.path)
    guard let source = library.profile(name: "JAMA", articleType: "Research Letter") else {
        check("the bundled JAMA Research Letter seeded the library", false); return
    }

    // A manuscript with a journal cut from that template, the way Add Journal does it.
    let store = ManuscriptStore()
    store.createNew(in: root)
    var template = Journal.empty()
    template.id = UUID()
    template.name = source.name; template.articleType = source.articleType
    template.templateName = source.name; template.templateChecksum = source.checksum
    template.profileID = source.id
    template.sourceRequirements = source.requirements
    template.checkRules = source.checks
    template.structure = source.structure
    template.configOrigin = source.origin
    guard let journal = store.addJournalCut(template: template, fromJournalID: nil, viewConfigID: nil) else {
        check("a journal was cut from the template", false); return
    }
    for part in ProfilePart.allCases {
        check("fresh cut: \(part.label) matches the template", !store.partDiffersFromTemplate(part, journal: journal))
    }
    check("the manuscript carries the template whole", store.libraryStatus(for: journal) == .matches)

    // Edit every part inside the manuscript.
    var requirements = journal.sourceRequirements ?? SourceRequirements()
    requirements.bullets.append("limits: body up to 700 words (this cut's own rule)")
    store.updateSourceRequirements(requirements, journalID: journal.id)
    var structure = journal.structure ?? JournalStructure()
    structure.sections.append(StructureSection(title: "Policy Implications"))
    store.updateStructure(structure, journalID: journal.id)
    var rules = journal.checkRules ?? []
    rules.append(CheckRule(name: "A rule of this cut's own", conditions: [], manual: true))
    store.updateCheckRules(rules, journalID: journal.id)
    guard let edited = store.manuscript?.journals.first(where: { $0.id == journal.id }) else {
        check("the journal is still there", false); return
    }
    check("the summary edit took", edited.sourceRequirements?.bullets.contains { $0.contains("700 words") } == true)
    check("the structure edit took", edited.structure?.sections.contains { $0.title == "Policy Implications" } == true)
    check("the tests edit took", edited.checkRules?.contains { $0.name == "A rule of this cut's own" } == true)
    for part in [ProfilePart.requirements, .structure, .checks] {
        check("edited cut: \(part.label) reads as diverged from its template", store.partDiffersFromTemplate(part, journal: edited))
    }
    check("the export outline, untouched, does not", !store.partDiffersFromTemplate(.export, journal: edited))
    if case .differs(let parts) = store.libraryStatus(for: edited) {
        check("the library sees the same three parts differ", parts == [.requirements, .structure, .checks], "\(parts)")
    } else {
        check("the library sees the copy as a modified version", false, "\(store.libraryStatus(for: edited))")
    }

    // The edits are in the manuscript folder — what travels, locally and in the remote.
    let folder = root.appendingPathComponent("journals").appendingPathComponent(edited.profileSlug)
    let carried = JournalProfile.read(from: folder, origin: .manuscript)
    check("the manuscript folder holds the journal's copy", carried != nil, folder.path)
    check("… under the template's GUID", carried?.id == source.id)
    check("… with the edits in it", carried?.requirements.bullets.contains { $0.contains("700 words") } == true
          && carried?.structure.sections.contains { $0.title == "Policy Implications" } == true
          && carried?.checks.contains { $0.name == "A rule of this cut's own" } == true)
    check("… and it is what the remote would get", (try? store.gatherRemoteFiles().contains { $0.path == "journals/\(edited.profileSlug)/checks.json" }) == true)

    // Against the shared repository — the comparison itself, without the network.
    typealias S = TemplatePublishing.Status
    check("nothing published → absent", TemplatePublishing.compare(edited.profile, published: nil) == .absent)
    check("published under another GUID → different identity",
          TemplatePublishing.compare(edited.profile, published: library.profile(name: "JAMA", articleType: "Viewpoint")) == .differentIdentity)
    check("the untouched template matches its published self", TemplatePublishing.compare(source, published: source) == .matches)
    if case .differs(let parts) = TemplatePublishing.compare(edited.profile, published: source) {
        check("the edited copy differs in exactly the edited parts", parts == [.requirements, .structure, .checks], "\(parts)")
    } else {
        check("the edited copy differs from the published one", false)
    }
    check("the warning names the parts", S.differs([.checks]).warning?.contains("Tests") == true)
    check("matching is silent", S.matches.warning == nil && S.unknown.warning == nil)

    // One name and type, one template.
    let made = library.createEmpty(named: "Harness Journal", articleType: "Letter")
    check("a template is created", made != nil)
    check("a second under the same name and type is refused", library.createEmpty(named: "Harness Journal", articleType: "Letter") == nil)
    check("the same name under another type is fine", library.createEmpty(named: "Harness Journal", articleType: "Research") != nil)
    check("the holder of a name is named", library.holder(ofName: "harness journal", articleType: "Letter")?.id == made?.id)
    check("a copy is named “- copy”", made.map { library.copyName(for: $0) } == "Harness Journal - copy")
    let copy = made.flatMap { library.clone($0, named: library.copyName(for: $0)) }
    check("a copy is a new template", copy != nil && copy?.id != made?.id)
    check("the next copy is “- copy 2”", made.map { library.copyName(for: $0) } == "Harness Journal - copy 2")
    check("a clone onto a taken name is refused", made.flatMap { library.clone($0, named: "Harness Journal - copy") } == nil)
    var renamed = copy!; renamed.name = "Harness Journal"
    check("saving a copy under the original's name is refused", !library.save(renamed))

    // Checksums saved under the old spelling (kind, sample, full formats)
    // are recognised and replaced, so a rename never reads as an edit.
    var old = source
    var legacy: [String: String] = [:]
    for part in ProfilePart.allCases { legacy[part.rawValue] = old.legacyFingerprint(part) }
    check("the old spelling hashes differently where a scope or entry type is written",
          legacy["checks"] != old.fingerprint(.checks))
    old.partChecksums = legacy
    old.migrateChecksums()
    check("old checksums migrate to the current fingerprint",
          ProfilePart.allCases.allSatisfy { old.partChecksums?[$0.rawValue] == old.fingerprint($0) })
    var changed = source
    changed.checks.append(CheckRule(name: "Another rule", conditions: [], manual: true))
    changed.partChecksums = legacy
    changed.migrateChecksums()
    check("a real change is not mistaken for a rename", changed.partChecksums?["checks"] == legacy["checks"])

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }

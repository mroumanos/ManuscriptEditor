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
    store.flushPendingSave()   // edits save on a debounce; a reader flushes first
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
    if case .differs(let parts) = TemplatePublishing.compare(edited.profile, published: source,
                                                              exportDiffers: { store.exportDiffers(from: $0, journal: edited) }) {
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

    // A cut's active sections are its structure.  A section added from
    // Source is active there (the union) and deactivated in the cut — not
    // part of the journal; activating it in the cut makes it one, and gives
    // the structure an entry for it.
    guard let head = store.latestVersion(forJournal: journal.id) else { check("the cut has a version", false); return }
    func journalNow() -> Journal { store.manuscript!.journals.first { $0.id == journal.id }! }
    func cutSection(_ id: UUID) -> ManuscriptSection { store.manuscript(for: .version(head.id))!.sections.first { $0.id == id }! }
    // The standard outline: a stored outline is the author's and keeps its
    // own list (export ⊆ structure — an active section may be left out).
    func exported(_ id: UUID) -> Bool {
        ExportConfig.standard(content: store.manuscript(for: .version(head.id))!, journal: journalNow())
            .documents.flatMap(\.items).contains { $0.sectionID == id }
    }
    guard let extraID = store.addSection(type: .custom, title: "Extra Notes", kind: .text) else {
        check("a section was added from Source", false); return
    }
    let introID = store.manuscript!.sections.first { $0.title == "Introduction" }!.id
    check("a section added from Source is active in Source", store.manuscript!.sections.first { $0.id == extraID }?.active == true)
    check("… and deactivated in the cut — not part of the journal",
          !cutSection(extraID).active && !store.sectionBelongs(cutSection(extraID), to: journalNow()))
    check("one the template names is active there, and part of it",
          cutSection(introID).active && store.sectionBelongs(cutSection(introID), to: journalNow()))
    check("the export prints only the cut's active sections", !exported(extraID) && exported(introID))
    check("the model is not sent a deactivated one", !FastForwardIntent.payloads(for: store.manuscript(for: .version(head.id))!, target: journalNow())
          .contains { $0.section.id == extraID })
    check("… and is told what a submission contains",
          (try? FastForwardIntent.task(content: store.manuscript(for: .version(head.id))!, target: journalNow()))?
              .contains("The sections sent below are the ones a submission here contains") == true)
    store.setSectionActive(true, id: extraID, ref: .version(head.id))
    check("activating it in the cut makes it part of the journal", store.sectionBelongs(cutSection(extraID), to: journalNow()))
    check("… gives the structure an entry for it", journalNow().structure?.sections.contains { $0.key == "extra notes" } == true)
    check("… and the export prints it", exported(extraID))
    store.setSectionActive(false, id: extraID, ref: .version(head.id))
    check("deactivating takes it out of the export again", !exported(extraID))
    check("… the entry stays — the text and the fields are kept", journalNow().structure?.sections.contains { $0.key == "extra notes" } == true)
    guard let ownID = store.addSection(type: .custom, title: "Policy Notes", kind: .text, ref: .version(head.id)) else {
        check("a section was added from the cut", false); return
    }
    check("a section added from the cut is active there", cutSection(ownID).active)
    check("… with a structure entry", journalNow().structure?.sections.contains { $0.key == "policy notes" } == true)
    check("… and active in Source, the union", store.manuscript!.sections.first { $0.id == ownID }?.active == true)

    // A fresh cut from a template deactivates the sections it doesn't name.
    var second = template; second.id = UUID(); second.name = "JAMA again"
    if let other = store.addJournalCut(template: second, fromJournalID: nil, viewConfigID: nil),
       let otherHead = store.latestVersion(forJournal: other.id) {
        let cut = store.manuscript(for: .version(otherHead.id))!
        check("a new cut deactivates a section its template doesn't name", cut.sections.first { $0.id == extraID }?.active == false
              && cut.sections.first { $0.id == ownID }?.active == false)
        check("… and keeps the ones it names", cut.sections.first { $0.id == introID }?.active == true)
        check("… without touching the first journal's structure", journalNow().structure?.sections.contains { $0.key == "policy notes" } == true)
    } else { check("a second journal was cut", false) }

    // Delete, or clear: deleting from a cut deletes everywhere only while
    // nobody else holds content in the section.
    var written = cutSection(extraID); written.content = RichText(plain: "Something this cut says.")
    store.updateSection(written, ref: .version(head.id))
    check("writing into a deactivated section does not activate it", !cutSection(extraID).active)
    check("nobody else holds content in it → a delete would delete", store.sectionUsers(extraID, excluding: .version(head.id)).isEmpty)
    // Clear is always there; Delete only while no other journal has the
    // section in its structure (active).
    check("no other journal has it active → a delete is offered", store.journalsWithSection(extraID, excluding: .source).isEmpty)
    store.setSectionActive(true, id: extraID, ref: .version(head.id))
    check("active in a journal → that journal blocks a delete elsewhere", store.journalsWithSection(extraID, excluding: .source) == [journal.name])
    check("… but not from its own tab", store.journalsWithSection(extraID, excluding: .version(head.id)).isEmpty)
    store.setSectionActive(false, id: extraID, ref: .version(head.id))
    var inSource = store.manuscript!.sections.first { $0.id == extraID }!; inSource.content = RichText(plain: "Source's own words.")
    store.updateSection(inSource, ref: .source)
    check("Source holds content now → the cut's delete is a clear", store.sectionUsers(extraID, excluding: .version(head.id)) == ["Source"])
    check("… and Source's delete is a clear, naming the journal", store.sectionUsers(extraID, excluding: .source) == [journal.name])
    store.clearSection(id: extraID, ref: .version(head.id))
    check("clearing empties this cut's copy", cutSection(extraID).isEmptyContent)
    check("… and leaves Source's", !store.manuscript!.sections.first { $0.id == extraID }!.isEmptyContent)
    check("the section still exists everywhere", store.manuscript!.sections.contains { $0.id == extraID })

    // A fast-forward fills a submission: the upstream's text reaches only
    // the cut's active sections, and a deactivated one stays deactivated.
    var intro = store.manuscript!.sections.first { $0.title == "Introduction" }!; intro.content = RichText(plain: "An introduction from Source.")
    store.updateSection(intro, ref: .source)
    _ = store.stampSource()     // a sync reads the upstream as last stamped
    _ = store.syncJournal(journal.id)
    let synced = store.manuscript(for: .version(store.latestVersion(forJournal: journal.id)!.id))!
    check("a sync migrates Source's text into an active section",
          synced.sections.first { $0.title == "Introduction" }?.content.plain == "An introduction from Source.")
    check("… and not into a deactivated one", synced.sections.first { $0.id == extraID }?.isEmptyContent == true)
    check("… which stays deactivated", synced.sections.first { $0.id == extraID }?.active == false)

    // Adding a journal takes the published copy when it has moved on and the
    // library's copy is untouched; an edited copy stays the user's.
    var fromBundle = source; fromBundle.publishedChecksum = fromBundle.checksum
    var newer = source; newer.checks.append(CheckRule(name: "A newer published rule", conditions: [], manual: true))
    check("an untouched copy adopts a newer published one", TemplatePublishing.shouldAdopt(local: fromBundle, published: newer))
    check("… but not an identical one", !TemplatePublishing.shouldAdopt(local: fromBundle, published: fromBundle))
    var mine = fromBundle; mine.requirements.bullets.append("limits: my own rule"); mine.version = 2
    check("an edited copy is kept", !TemplatePublishing.shouldAdopt(local: mine, published: newer))
    var other = newer; other.id = UUID()
    check("a different template under the name is never adopted", !TemplatePublishing.shouldAdopt(local: fromBundle, published: other))
    var unrecorded = source; unrecorded.publishedChecksum = nil; unrecorded.version = 1; unrecorded.partChecksums = nil
    check("a copy from before the checksum was recorded counts as untouched while never saved", TemplatePublishing.shouldAdopt(local: unrecorded, published: newer))
    check("the library seeds a copy as its own published checksum", library.profile(id: source.id)?.publishedChecksum == source.checksum)
    check("a library write leaves checksum.txt beside the files",
          (try? String(contentsOf: library.root.appendingPathComponent(source.slug).appendingPathComponent(JournalProfile.checksumFileName), encoding: .utf8))?
              .trimmingCharacters(in: .whitespacesAndNewlines) == source.checksum)

    // A structure entry is its own: made as "New Section", renamed, and the
    // next "New Section" is another entry — not the same one twice.
    var retitled = StructureSection(title: "New Section"); retitled.title = "Data and Methods"
    let another = StructureSection(title: "New Section")
    check("two entries made under one title are two entries", retitled.uid != another.uid)
    let twins = Data("""
    {"sections": [{"title": "Data and Methods"}, {"title": "New Section"}, {"title": "Data and Methods"}]}
    """.utf8)
    if let doc = try? JSONDecoder().decode(StructureDoc.self, from: twins) {
        check("a file with two entries of one title and no ids yields two entries", Set(doc.sections.map(\.uid)).count == 3)
        check("… the first keeping the id a manuscript matches it by", doc.sections[0].uid == StructureSection.derivedID(title: "Data and Methods"))
    } else { check("a structure file decodes", false) }

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

    // A sync keeps THIS cut's activation, whatever the upstream's: a cut
    // downstream of a journal whose sections don't align is filled only in
    // the sections it has active, and an adaptation can write only those.
    var downstream = template; downstream.id = UUID(); downstream.name = "JAMA downstream"
    if let down = store.addJournalCut(template: downstream, fromJournalID: journal.id, viewConfigID: nil),
       let downHead = store.latestVersion(forJournal: down.id) {
        func downSection(_ id: UUID) -> ManuscriptSection? {
            store.latestVersion(forJournal: down.id).flatMap { store.manuscript(for: .version($0.id)) }?.sections.first { $0.id == id }
        }
        // The upstream's head moved with the sync above.
        let upHead = store.latestVersion(forJournal: journal.id)!
        func upSection(_ id: UUID) -> ManuscriptSection { store.manuscript(for: .version(upHead.id))!.sections.first { $0.id == id }! }
        // Upstream (the first journal): Extra Notes on and written, Introduction off.
        store.setSectionActive(true, id: extraID, ref: .version(upHead.id))
        var upExtra = upSection(extraID); upExtra.content = RichText(plain: "The upstream's extra notes.")
        store.updateSection(upExtra, ref: .version(upHead.id))
        store.setSectionActive(false, id: introID, ref: .version(upHead.id))
        // Downstream: the opposite.
        store.setSectionActive(false, id: extraID, ref: .version(downHead.id))
        store.setSectionActive(true, id: introID, ref: .version(downHead.id))
        let merged = store.syncBaseContent(head: store.manuscript(for: .version(downHead.id))!,
                                           upstream: store.manuscript(for: .version(upHead.id))!)
        check("the sync base keeps the downstream's activation", merged.sections.first { $0.id == extraID }?.active == false
              && merged.sections.first { $0.id == introID }?.active == true)
        check("… fills an active section from the upstream even where the upstream has it off",
              merged.sections.first { $0.id == introID }?.content.plain == "An introduction from Source.")
        check("… and leaves a deactivated one empty whatever the upstream wrote", merged.sections.first { $0.id == extraID }?.isEmptyContent == true)
        check("the model is sent the downstream's active sections and no other",
              FastForwardIntent.payloads(for: merged, target: down).map(\.section.id).contains(introID)
              && !FastForwardIntent.payloads(for: merged, target: down).map(\.section.id).contains(extraID))
        check("… and is told a section not sent is deactivated here",
              (try? FastForwardIntent.task(content: merged, target: down))?.contains("deactivated for this journal") == true)
        var adaptation = FastForwardIntent.Adaptation()
        adaptation.sections[introID] = RichText(plain: "An adapted introduction.")
        adaptation.sections[extraID] = RichText(plain: "The model wrote this anyway.")
        _ = store.syncJournal(down.id, adaptation: adaptation, assistedBy: "harness")
        check("an adapted sync keeps the downstream's activation", downSection(extraID)?.active == false && downSection(introID)?.active == true)
        check("… takes the adaptation into an active section", downSection(introID)?.content.plain == "An adapted introduction.")
        check("… and never into a deactivated one", downSection(extraID)?.isEmptyContent == true)
        check("the upstream is untouched", upSection(extraID).active && !upSection(introID).active)
        // The pane's smart refresh: one section, under the instruction shown.
        let refreshed = store.manuscript(for: .version(store.latestVersion(forJournal: down.id)!.id))!
        let instruction = FastForwardIntent.refreshInstruction(section: downSection(introID)!, journal: down)
        if let task = try? FastForwardIntent.task(content: refreshed, target: down, only: introID, instruction: instruction) {
            check("a smart refresh opens with the instruction shown", task.hasPrefix(instruction))
            check("… sends that one section and no other", task.components(separatedBy: "\"kind\":\"prose\"").count == 2
                  && task.contains("\"title\":\"Introduction\"") && task.contains("Only one section is sent"))
            check("… and the template's layout outranks the format note", task.contains("the template wins"))
        } else { check("a smart refresh task is built", false) }
        check("a fast-forward still opens as before", (try? FastForwardIntent.task(content: refreshed, target: down))?.hasPrefix("Adapt this manuscript") == true)
    } else { check("a downstream journal was cut", false) }

    // Dragging a row moves that row: the offsets are into the sidebar's list
    // (journal sections past the rule), with the letter above it untouched,
    // and every cut takes the order.
    _ = store.ensureLetterSection()
    let listedBefore = store.manuscript!.journalSections.sorted { $0.order < $1.order }.map(\.title)
    if let from = listedBefore.firstIndex(of: "Extra Notes") {
        store.moveSections(from: IndexSet(integer: from), to: 0)
        let listedAfter = store.manuscript!.journalSections.sorted { $0.order < $1.order }.map(\.title)
        check("the dragged row is the one that moved", listedAfter.first == "Extra Notes"
              && listedAfter.dropFirst().elementsEqual(listedBefore.filter { $0 != "Extra Notes" }))
        check("the letter keeps its slot", store.manuscript!.letterSection.map { l in
            store.manuscript!.sections.sorted { $0.order < $1.order }.firstIndex { $0.id == l.id }
        } == store.manuscript!.sections.sorted { $0.order < $1.order }.firstIndex { $0.isCore })
        let cutOrder = store.manuscript(for: .version(store.latestVersion(forJournal: journal.id)!.id))!
            .journalSections.sorted { $0.order < $1.order }.map(\.title)
        check("every journal's cut takes the order", cutOrder == listedAfter)
    } else { check("the moved section is listed", false) }

    // Save from a manuscript: the template editor opens on the journal's
    // copy; saving under a changed name makes a new template, and the
    // journal follows it.
    let workspace = TemplateWorkspace()
    let carrier = journalNow()
    check("the draft is seeded from the journal", workspace.open(source.id, seedFrom: carrier, export: store.templateExport(for: carrier)))
    check("… and holds the journal's edits", workspace.template(source.id)?.requirements.bullets.contains { $0.contains("700 words") } == true
          && workspace.template(source.id)?.checks.contains { $0.name == "A rule of this cut's own" } == true)
    check("… reading as edited in those parts", workspace.editedParts(source.id).isSuperset(of: [.requirements, .checks]))
    check("… remembering the journal", workspace.seededJournal[source.id] == journal.id)
    check("under the same name it saves in place", !workspace.savesAsNew(source.id))
    workspace.edit(source.id) { $0.name = "Harness Research Letter" }
    check("under a changed name it saves as new", workspace.savesAsNew(source.id))
    guard let newID = workspace.saveAsNew(source.id) else { check("saved as a new template", false); return }
    let made2 = library.profile(id: newID)
    check("the new template has its own identity at version 1, branched from the original",
          newID != source.id && made2?.version == 1 && made2?.lineage.first == source.id)
    check("… carrying the journal's edits", made2?.requirements.bullets.contains { $0.contains("700 words") } == true)
    check("the original is as the library held it", library.profile(id: source.id)?.checksum == source.checksum)
    check("the tab is the new template's", workspace.openIDs == [newID] && !workspace.isOpen(source.id))
    check("… still remembering the journal", workspace.seededJournal[newID] == journal.id)
    check("the journal is re-pointed", store.linkToTemplate(newID, journalID: journal.id) && journalNow().profileID == newID)
    check("… and matches its new template", store.libraryStatus(for: journalNow()) == .matches, "\(store.libraryStatus(for: journalNow()))")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }

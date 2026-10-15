import Foundation
@testable import ManuscriptEditor

// Every bundled journal profile decodes whole, under the GUID its slug
// derives, with every rule and section the file holds — a rule the decoder
// drops fails nobody's check, silently.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if !ok { print("FAIL  \(label)  \(detail)"); failures += 1 }
}

let bundled = JournalProfile.bundled()
let root = Bundle.containingCode.url(forResource: JournalProfile.bundledFolder, withExtension: nil)!
let folders = try! FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
print("\(folders.count) folders, \(bundled.count) profiles decoded")
check("every folder decodes to a profile", folders.count == bundled.count)

var jamaCount = 0, keyPointsCount = 0
for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let slug = folder.lastPathComponent
    let id = JournalProfile.bundledID(slug: slug)
    guard let p = bundled[id] else { check("\(slug): id is bundledID(slug)", false); continue }
    check("\(slug): slug round-trips", p.slug == slug, p.slug)
    let rawChecks = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("checks.json")))) as? [String: Any]
    let rawRules = (rawChecks?["checks"] as? [Any])?.count ?? -1
    check("\(slug): every rule decoded", p.checks.count == rawRules, "\(p.checks.count) of \(rawRules)")
    let rawStructure = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("structure.json")))) as? [String: Any]
    let rawSections = (rawStructure?["sections"] as? [Any])?.count ?? -1
    check("\(slug): every section decoded", p.structure.sections.count == rawSections)
    check("\(slug): has a summary", !p.requirements.bullets.isEmpty && !p.requirements.url.isEmpty)
    for rule in p.checks where !rule.isManual {
        check("\(slug): rule '\(rule.name)' has conditions", !rule.conditions.isEmpty)
    }
    guard p.name.hasPrefix("JAMA") || p.name == "Health Affairs Scholar" else { continue }
    jamaCount += 1
    check("\(slug): carries publisher and country", p.publisher?.isEmpty == false && p.country?.isEmpty == false)
    check("\(slug): names its article type", p.articleType?.isEmpty == false)
    check("\(slug): the venue has its say about the abstract", p.structure.abstractEntry != nil)
    if let kp = p.structure.sections.first(where: { $0.title == "Key Points" || $0.title == "Key Takeaways" }) {
        keyPointsCount += 1
        check("\(slug): the key-points box carries boilerplate", kp.boilerplate?.isEmpty == false)
        check("\(slug): the key-points box is checked", p.checks.contains { $0.name.hasPrefix(kp.title) || $0.name.contains("key-takeaway") })
    }
    if p.structure.abstractEntry?.required == false {
        check("\(slug): no-abstract type is checked", p.checks.contains { $0.name == "No abstract" })
    }
    if p.requirements.bullets.contains(where: { $0.hasPrefix("limits: body") || $0.hasPrefix("limits: recommended") }) {
        check("\(slug): a body limit", p.checks.contains { $0.name.hasPrefix("Body") })
    }
}
// The hand-written AJPH profiles carry the venue's content in the fields
// made for it: a question series with a boilerplate per question, and an
// export outline with its page breaks.
for slug in ["american-journal-of-public-health-research-article", "american-journal-of-public-health-research-brief"] {
    guard let p = bundled[JournalProfile.bundledID(slug: slug)] else { check("\(slug) present", false); continue }
    let questions = p.structure.sections.first { $0.type == .questions }
    check("\(slug): a question series decoded as one", questions != nil)
    check("\(slug): every question carries a boilerplate",
          (questions?.questions ?? []).count == 24 && (questions?.questions ?? []).allSatisfy { $0.boilerplate?.isEmpty == false })
    check("\(slug): the abstract entry carries its layout", p.structure.abstractEntry?.boilerplate?.contains("Objectives") == true)
    check("\(slug): an export outline with a blinded manuscript", p.export?.documents.map(\.name) == ["Title Page", "Manuscript (blinded)", "Cover Letter"])
    check("\(slug): the outline's page breaks decoded", (p.export?.documents[1].items.filter { $0.type == .pageBreak }.count ?? 0) == 4)
    if let export = p.export {
        let again = TemplateOutline.from(export, structure: p.structure).exportConfig(structure: p.structure, profileID: p.id)
        check("\(slug): the outline round-trips through the file's words", ProfileFingerprint.of(again) == ProfileFingerprint.of(export))
    }
    check("\(slug): the outline names the structure's sections",
          Set(p.export?.documents[1].items.compactMap(\.sectionID) ?? []) == Set(p.structure.sectionEntries.filter { $0.type == .text }.map(\.uid)))
}
print("\(jamaCount) generated profiles, \(keyPointsCount) with Key Points")
check("generated profiles present", jamaCount >= 16)
check("Health Affairs Scholar ships per article type",
      bundled.values.filter { $0.name == "Health Affairs Scholar" }.count >= 8)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

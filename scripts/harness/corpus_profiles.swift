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
    guard p.name.hasPrefix("JAMA") else { continue }
    jamaCount += 1
    check("\(slug): carries publisher and country", p.publisher == "American Medical Association" && p.country == "United States")
    check("\(slug): names its article type", p.articleType?.isEmpty == false)
    check("\(slug): the venue has its say about the abstract", p.structure.abstractEntry != nil)
    if let kp = p.structure.sections.first(where: { $0.title == "Key Points" }) {
        keyPointsCount += 1
        check("\(slug): Key Points carry boilerplate", kp.boilerplate?.contains("Question") == true)
        check("\(slug): Key Points are checked", p.checks.contains { $0.name.hasPrefix("Key Points") })
    }
    if p.structure.abstractEntry?.required == false {
        check("\(slug): no-abstract type is checked", p.checks.contains { $0.name == "No abstract" })
    }
    check("\(slug): a body limit", p.checks.contains { $0.name.hasPrefix("Body") })
}
print("\(jamaCount) JAMA Network profiles, \(keyPointsCount) with Key Points")
check("JAMA Network profiles present", jamaCount >= 16)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

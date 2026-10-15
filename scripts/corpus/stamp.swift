import Foundation
@testable import ManuscriptEditor

// Writes, for every bundled profile folder in the REPOSITORY (not the app
// bundle): `export.json` where there is none — the standard outline over the
// profile's structure, in the file's words — and `checksum.txt`, the
// profile's checksum as the app computes it, so one small fetch tells an
// install whether the published copy has moved on.  Run after
// build_corpus.py and after editing a hand-written profile.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
var stamped = 0, outlined = 0
MainActor.assumeIsolated {
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
    for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard var profile = JournalProfile.read(from: folder, origin: .bundled) else {
            print("SKIP  \(folder.lastPathComponent): not a profile"); continue
        }
        let exportURL = folder.appendingPathComponent(ProfilePart.export.fileName)
        if profile.export == nil {
            let outline = TemplateOutline.from(TemplateWorkspace.standardOutline(for: profile), structure: profile.structure)
            var data = try! encoder.encode(outline)
            data.append(0x0A)
            try! data.write(to: exportURL)
            profile = JournalProfile.read(from: folder, origin: .bundled)!
            outlined += 1
        }
        let checksumURL = folder.appendingPathComponent(JournalProfile.checksumFileName)
        let line = profile.checksum + "\n"
        if (try? String(contentsOf: checksumURL, encoding: .utf8)) != line {
            try! Data(line.utf8).write(to: checksumURL)
            stamped += 1
        }
    }
    print("\(folders.count) profiles: \(outlined) outline(s) written, \(stamped) checksum(s) updated")
}

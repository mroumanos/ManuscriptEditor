import Foundation
@testable import ManuscriptEditor

// What a save sends must be what a load takes.  They were two lists, and a
// collaborator who loaded a manuscript got "File missing" for an uploaded
// export file that was on the remote all along.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "PASS  \(label)" : "FAIL  \(label)  \(detail)"); if !ok { failures += 1 }
}

@MainActor func run() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("me-remote-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ManuscriptStore()
    store.createNew(in: root)
    store.trySave()

    let owned = ["attachments/cover-form.pdf", "context/reviewer-notes.txt", "ai/log.json",
                 "ai/prompts/one.txt", "ai/responses/one.txt", "journals/ajph/structure.json",
                 "figures/figure-1.png", "data/counts.csv"]
    let notOwned = ["attachments/.DS_Store", "scratch/ignored.txt"]
    for path in owned + notOwned {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: url)
    }

    let sent = (try? store.gatherRemoteFiles().map(\.path)) ?? []
    check("a save sends the manuscript itself", sent.contains("manuscript.json"))
    for path in owned {
        check("a save sends \(path)", sent.contains(path), "\(sent)")
    }
    check("and nothing hidden or outside the managed folders",
          !sent.contains { $0.hasSuffix(".DS_Store") || $0.hasPrefix("scratch/") }, "\(sent)")

    // The load's own filter — the one `pull` applies to the branch's tree.
    let taken = GitHubBackendService.isManaged
    check("everything a save sends, a load takes", sent.allSatisfy(taken), "\(sent.filter { !taken($0) })")
    check("an uploaded export file is among them — the one that read 'File missing'",
          taken("attachments/cover-form.pdf"))
    check("a load leaves the repository's own files alone",
          !taken("README.md") && !taken("LICENSE") && !taken("figures.md"))
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }

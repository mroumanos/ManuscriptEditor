// SandboxMigration.swift
//
// One-time migration after the app dropped the App Sandbox: sandboxed builds
// stored everything in the container (~/Library/Containers/knktech.…/Data),
// unsandboxed builds use the real ~/Library locations.  Without this, the
// user's manuscripts, accounts, and preferences appear to vanish.
//
// Strategy (safe to re-run; marker-guarded):
//   • manuscripts/    — copy any container manuscript the real location lacks
//   • app.json        — UNION-merge by id (accounts re-created post-switch
//                       must survive alongside the container's originals)
//   • UserDefaults    — merge container plist keys that are absent
//   • Keychain items from the sandboxed era stay unreadable (different
//     partition) — KeychainService recovers those slots on the next write.

import Foundation

enum SandboxMigration {

    static func runIfNeeded() {
        let fm = FileManager.default
        let container = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/knktech.ManuscriptEditor/Data")
        let containerSupport = container
            .appendingPathComponent("Library/Application Support/ManuscriptEditor")
        let realSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ManuscriptEditor")

        // Only meaningful when running unsandboxed with container data present.
        guard realSupport.path != containerSupport.path,
              fm.fileExists(atPath: containerSupport.path) else { return }
        let marker = realSupport.appendingPathComponent(".migrated-from-container")
        guard !fm.fileExists(atPath: marker.path) else { return }
        try? fm.createDirectory(at: realSupport, withIntermediateDirectories: true)

        migrateManuscripts(from: containerSupport, to: realSupport)
        mergeAppJSON(container: containerSupport.appendingPathComponent("app.json"),
                     real: realSupport.appendingPathComponent("app.json"))
        mergeDefaults(containerPlist: container
            .appendingPathComponent("Library/Preferences/knktech.ManuscriptEditor.plist"))

        try? Data().write(to: marker)
    }

    private static func migrateManuscripts(from src: URL, to dst: URL) {
        let fm = FileManager.default
        let srcManuscripts = src.appendingPathComponent("manuscripts")
        let dstManuscripts = dst.appendingPathComponent("manuscripts")
        try? fm.createDirectory(at: dstManuscripts, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(atPath: srcManuscripts.path) else { return }
        for name in items where !name.hasPrefix(".") {
            let destination = dstManuscripts.appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: srcManuscripts.appendingPathComponent(name), to: destination)
            }
        }
    }

    /// Union-merges the container's app.json into the real one by id, so
    /// accounts/library entries from both eras survive.
    private static func mergeAppJSON(container: URL, real: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: container.path) else { return }
        guard fm.fileExists(atPath: real.path) else {
            try? fm.copyItem(at: container, to: real)
            return
        }
        guard var realDict = json(real), let containerDict = json(container) else { return }
        for key in ["backends", "aiServices", "views", "journalLibrary"] {
            let realList = realDict[key] as? [[String: Any]] ?? []
            let containerList = containerDict[key] as? [[String: Any]] ?? []
            var seen = Set(realList.compactMap { $0["id"] as? String })
            // Avoid cosmetic duplicates too (same provider+name re-created).
            var labels = Set(realList.map {
                "\($0["provider"] ?? $0["name"] ?? "")|\($0["displayName"] ?? "")"
            })
            var merged = realList
            for item in containerList {
                let id = item["id"] as? String ?? ""
                let label = "\(item["provider"] ?? item["name"] ?? "")|\(item["displayName"] ?? "")"
                guard !seen.contains(id), !labels.contains(label) else { continue }
                seen.insert(id)
                labels.insert(label)
                merged.append(item)
            }
            realDict[key] = merged
        }
        if let data = try? JSONSerialization.data(withJSONObject: realDict) {
            try? data.write(to: real, options: .atomic)
        }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Brings over container defaults (known manuscript ids, folder mappings,
    /// identity, editor prefs) wherever the real domain has no value yet.
    private static func mergeDefaults(containerPlist: URL) {
        guard let dict = NSDictionary(contentsOf: containerPlist) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        for (key, value) in dict {
            if key == "allManuscriptIDs" {
                // Union the id lists rather than keeping just one era's.
                let real = defaults.array(forKey: key) as? [String] ?? []
                let container = value as? [String] ?? []
                defaults.set(Array(Set(real + container)), forKey: key)
            } else if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}

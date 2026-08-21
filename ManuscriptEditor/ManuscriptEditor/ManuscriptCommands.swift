// ManuscriptCommands.swift
//
// Custom menu items added to the macOS menu bar.
//
// HOW SWIFTUI MENUS WORK
// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI's `Commands` protocol lets you inject items into the system menu bar.
// `CommandGroup(replacing:)` replaces a built-in group (like the default New/Open
// items in the File menu) with your own items.
//
// Because `Commands` are declared outside the view hierarchy, they can't access
// `@Environment` directly.  Instead, actions are dispatched via `NotificationCenter`
// and `ContentView` subscribes to those notifications to drive the store.
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
//   File → New Manuscript (File)… ⌘N   — local folder
//          New Manuscript (Remote)…    — bound to a backend repository
//          Save (Local) ⌘S · Save (Remote) ⇧⌘S · Load from Remote…
//          Export Submission Package… ⌘E
//   View → Next/Previous Journal Tab (⌘⇧→ / ⌘⇧←)

import SwiftUI

/// Declares the custom File and View menu items for the app.
struct ManuscriptCommands: Commands {
    var body: some Commands {

        // The project lifecycle lives under File:
        //   New           — a fresh manuscript in the app-data folder
        //   Open (Local)… — point at an existing project folder; files are
        //                   edited in place (never copied into app data)
        //   Open (Remote)…— clone a GitHub/GitLab repository into app data;
        //                   local saves land there, remote saves push
        CommandGroup(replacing: .newItem) {
            Button("New Manuscript") {
                NotificationCenter.default.post(name: .newManuscript, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)   // ⌘N

            Button("Open Manuscript (Local)…") {
                NotificationCenter.default.post(name: .openManuscriptLocal, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)   // ⌘O

            Button("Open Manuscript (Remote)…") {
                NotificationCenter.default.post(name: .newManuscriptRemote, object: nil)
            }

            Divider()

            // Saves + closes the current manuscript and returns to the
            // Welcome screen — the project manager (open / rename / remove
            // from list / trash).  Closing first guarantees you never trash
            // the project you're loaded on.
            Button("Manage Manuscripts…") {
                NotificationCenter.default.post(name: .manageManuscripts, object: nil)
            }
        }

        // Saving lives under File: local = to the manuscript folder on disk,
        // remote = to the manuscript's active backend account.
        CommandGroup(after: .saveItem) {
            Button("Save (Local)") {
                NotificationCenter.default.post(name: .saveManuscript, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)   // ⌘S

            Button("Save (Remote)") {
                NotificationCenter.default.post(name: .saveToRemote, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])   // ⇧⌘S
            // (Loading an existing remote manuscript IS "New Manuscript
            // (Remote)…" — there is deliberately no separate Load command.)
        }

        // Export here means the PROJECT — a zip of the manuscript folder that
        // "Open Manuscript (Local)…" can reopen.  Journal submission packages
        // are built in the Journal → Export pane, not the File menu.
        CommandGroup(after: .importExport) {
            Button("Export Project (Zip)…") {
                NotificationCenter.default.post(name: .exportProject, object: nil)
            }
            .keyboardShortcut("e", modifiers: .command)   // ⌘E
        }

        // Journal tab navigation (Active mode).
        CommandGroup(after: .sidebar) {
            Button("Next Journal Tab") {
                NotificationCenter.default.post(name: .nextJournalTab, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])   // ⌘⇧→

            Button("Previous Journal Tab") {
                NotificationCenter.default.post(name: .previousJournalTab, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])    // ⌘⇧←
        }
    }
}

// MARK: - Notification names

/// Strongly-typed notification names used to communicate between the menu bar and
/// `ContentView`.  Using named extensions avoids typos that would come from raw strings.
extension Notification.Name {
    /// Posted when the user chooses File → New Manuscript (⌘N).
    static let newManuscript  = Notification.Name("ManuscriptEditor.newManuscript")
    /// Posted when the user chooses File → Open Manuscript (Local)… (⌘O).
    static let openManuscriptLocal = Notification.Name("ManuscriptEditor.openManuscriptLocal")
    /// File → Manage Manuscripts… (curate the known-projects list).
    static let manageManuscripts = Notification.Name("ManuscriptEditor.manageManuscripts")
    /// Sets the manuscript-wide citation format (userInfo["code"] =
    /// RefEngine.CitationStyle raw value) — posted by the token context menu.
    static let setCitationFormat = Notification.Name("ManuscriptEditor.setCitationFormat")
    /// Posted when the user chooses File → Open Manuscript (Remote)….
    static let newManuscriptRemote = Notification.Name("ManuscriptEditor.newManuscriptRemote")
    /// Posted when the user chooses File → Save (Local) (⌘S).
    static let saveManuscript = Notification.Name("ManuscriptEditor.saveManuscript")
    /// Posted when the user chooses File → Export Project (Zip)… (⌘E).
    static let exportProject = Notification.Name("ManuscriptEditor.exportProject")
    /// Legacy: the old submission-package sheet (still used by ExportSheet).
    static let exportManuscript = Notification.Name("ManuscriptEditor.exportManuscript")
    /// Posted after a stamp/sync moves a journal's working head (userInfo:
    /// "old"/"new" version UUIDs) — Versions selections may follow it.
    static let journalHeadChanged = Notification.Name("ManuscriptEditor.journalHeadChanged")
    /// Posted when the user chooses File → Save (Remote) (⇧⌘S).
    static let saveToRemote = Notification.Name("ManuscriptEditor.saveToRemote")
    /// Posted when the user chooses File → Load from Remote….
    static let loadFromRemote = Notification.Name("ManuscriptEditor.loadFromRemote")
    /// Posted by View → Next/Previous Journal Tab (⌘⇧→ / ⌘⇧←).
    static let nextJournalTab = Notification.Name("ManuscriptEditor.nextJournalTab")
    static let previousJournalTab = Notification.Name("ManuscriptEditor.previousJournalTab")
}

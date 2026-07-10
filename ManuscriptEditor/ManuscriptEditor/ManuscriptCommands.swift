// ManuscriptCommands.swift
//
// Custom menu items added to the macOS menu bar.
//
// HOW SWIFTUI MENUS WORK
// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI's `Commands` protocol lets you inject items into the system menu bar.
// `CommandGroup(replacing:)` replaces a built-in group (like the default New/Open
// items in the File menu) with your own items.
// `CommandMenu(_:)` creates an entirely new top-level menu.
//
// Because `Commands` are declared outside the view hierarchy, they can't access
// `@Environment` directly.  Instead, actions are dispatched via `NotificationCenter`
// and `ContentView` subscribes to those notifications to drive the store.

import SwiftUI

/// Declares the custom File and Manuscript menu items for the app.
struct ManuscriptCommands: Commands {
    var body: some Commands {

        // Replace SwiftUI's default "New Item" (which would try to create a SwiftUI
        // document) with our own "New Manuscript" command.
        CommandGroup(replacing: .newItem) {
            Button("New Manuscript") {
                // Post a notification; ContentView is observing this and will call
                // store.createNew() on the main thread.
                NotificationCenter.default.post(name: .newManuscript, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)   // ⌘N
        }

        // Export lives in the File menu, next to import/new.
        CommandGroup(after: .importExport) {
            Button("Export Submission Package…") {
                NotificationCenter.default.post(name: .exportManuscript, object: nil)
            }
            .keyboardShortcut("e", modifiers: .command)   // ⌘E
        }

        // A new top-level "Manuscript" menu in the menu bar.
        CommandMenu("Manuscript") {
            Button("Save") {
                NotificationCenter.default.post(name: .saveManuscript, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)   // ⌘S
        }
    }
}

// MARK: - Notification names

/// Strongly-typed notification names used to communicate between the menu bar and
/// `ContentView`.  Using named extensions avoids typos that would come from raw strings.
extension Notification.Name {
    /// Posted when the user chooses File → New Manuscript (⌘N).
    static let newManuscript  = Notification.Name("ManuscriptEditor.newManuscript")
    /// Posted when the user chooses Manuscript → Save (⌘S).
    static let saveManuscript = Notification.Name("ManuscriptEditor.saveManuscript")
    /// Posted when the user chooses File → Export Submission Package… (⌘E).
    static let exportManuscript = Notification.Name("ManuscriptEditor.exportManuscript")
    /// Posted after a sync stamps a journal's new working head, so open
    /// comparison tabs can follow it (userInfo: "old"/"new" version UUIDs).
    static let journalHeadChanged = Notification.Name("ManuscriptEditor.journalHeadChanged")
}

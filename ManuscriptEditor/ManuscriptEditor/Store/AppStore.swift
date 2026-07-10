// AppStore.swift
//
// Global application state shared across all manuscripts.
//
// WHAT LIVES HERE vs. ManuscriptStore
// ─────────────────────────────────────────────────────────────────────────────
// ManuscriptStore holds everything about *one* manuscript (content, journals,
// settings references).  AppStore holds the global *accounts* and *templates*
// that any manuscript can reference:
//
//   AppStore.backends    — BackendAccounts (GitHub, Google Docs, …)
//   AppStore.aiServices  — AIServiceAccounts (Claude, ChatGPT, …)
//   AppStore.views       — ViewConfigs (layout templates for export/checks)
//
// Manuscripts reference these by UUID in `ManuscriptSettings`.
//
// PERSISTENCE
// ─────────────────────────────────────────────────────────────────────────────
// Saved to:
//   ~/Library/Application Support/ManuscriptEditor/app.json
//
// Uses the same atomic-write pattern as PersistenceService so crashes can't
// leave a corrupt file.

import Foundation
import Observation
import SwiftUI   // for Array.remove(atOffsets:) / move(fromOffsets:toOffset:)

// MARK: - Serialisable snapshot

/// The JSON-encodable shape of AppStore's data.
/// Keeping this separate from the store class avoids Codable conformance
/// complications with `@Observable`.
private struct AppData: Codable {
    var backends:   [BackendAccount]
    var aiServices: [AIServiceAccount]
    var views:      [ViewConfig]
    /// Global journal library (added later — optional keeps old files decoding).
    var journalLibrary: [Journal]?
}

// MARK: - AppStore

/// Global store for backend accounts, AI service accounts, and view templates.
///
/// Injected into the SwiftUI environment at the app level so every view can
/// read `@Environment(AppStore.self)`.
@MainActor
@Observable
final class AppStore {

    // MARK: - State

    /// All configured backend accounts (GitHub, Google Docs, etc.).
    var backends:   [BackendAccount]   = []

    /// All configured AI service accounts (Claude, ChatGPT, etc.).
    var aiServices: [AIServiceAccount] = []

    /// All user-created view templates.
    var views:      [ViewConfig]       = []

    /// The global **journal library**: reusable journal profiles (name,
    /// country, requirements, export outline) available when adding a journal
    /// to any manuscript.  Seeded once from the built-in presets; grows via
    /// "Save to Journal Library" in Export/Checks and the Preferences →
    /// Journals tab.
    var journalLibrary: [Journal]      = []

    // MARK: - Persistence path

    private var saveURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ManuscriptEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.json")
    }

    // MARK: - Lifecycle

    /// Called once at app launch.  Loads the saved app data if it exists and
    /// seeds the journal library from the built-in presets on first run.
    func load() {
        if let data = try? Data(contentsOf: saveURL),
           let decoded = try? JSONDecoder().decode(AppData.self, from: data) {
            backends   = decoded.backends
            aiServices = decoded.aiServices
            views      = decoded.views
            journalLibrary = decoded.journalLibrary ?? []
        }
        // Seed/merge presets: any preset name not yet in the library is
        // appended, so newly shipped presets reach existing installs too.
        let existingNames = Set(journalLibrary.map { $0.name.lowercased() })
        let missing = JournalPresets.all.filter { !existingNames.contains($0.name.lowercased()) }
        if !missing.isEmpty {
            journalLibrary += missing.map { preset in
                var journal = Journal(
                    id: UUID(), name: preset.name, publisher: preset.publisher,
                    submissionURL: "", requirements: preset.requirements,
                    viewConfigID: nil, createdAt: Date()
                )
                journal.country = preset.country
                return journal
            }
            save()
        }
    }

    /// Encodes and writes app data atomically.  Safe to call after any mutation.
    func save() {
        let snapshot = AppData(backends: backends, aiServices: aiServices,
                               views: views, journalLibrary: journalLibrary)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    // MARK: - Backends

    /// Adds a new backend account to the global list.
    func addBackend(_ account: BackendAccount) {
        backends.append(account)
        save()
    }

    /// Replaces the backend account whose `id` matches.
    func updateBackend(_ account: BackendAccount) {
        guard let idx = backends.firstIndex(where: { $0.id == account.id }) else { return }
        backends[idx] = account
        save()
    }

    /// Deletes backend accounts at the given offsets, and their Keychain
    /// secrets — an orphaned token must not outlive its account.
    func deleteBackends(at offsets: IndexSet) {
        for offset in offsets where backends.indices.contains(offset) {
            KeychainService.deleteSecret(for: backends[offset].id)
        }
        backends.remove(atOffsets: offsets)
        save()
    }

    // MARK: - AI Services

    /// Adds a new AI service account to the global list.
    func addAIService(_ account: AIServiceAccount) {
        aiServices.append(account)
        save()
    }

    /// Replaces the AI service account whose `id` matches.
    func updateAIService(_ account: AIServiceAccount) {
        guard let idx = aiServices.firstIndex(where: { $0.id == account.id }) else { return }
        aiServices[idx] = account
        save()
    }

    /// Deletes AI service accounts at the given offsets.
    func deleteAIServices(at offsets: IndexSet) {
        aiServices.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Journal library

    /// Adds (or replaces, matching by id) a library entry.
    func upsertLibraryJournal(_ journal: Journal) {
        if let idx = journalLibrary.firstIndex(where: { $0.id == journal.id }) {
            journalLibrary[idx] = journal
        } else {
            journalLibrary.append(journal)
        }
        save()
    }

    func deleteLibraryJournals(at offsets: IndexSet) {
        journalLibrary.remove(atOffsets: offsets)
        save()
    }

    // MARK: - View Configs

    /// Adds a new view config to the global list.
    func addViewConfig(_ config: ViewConfig) {
        views.append(config)
        save()
    }

    /// Replaces the view config whose `id` matches.
    func updateViewConfig(_ config: ViewConfig) {
        guard let idx = views.firstIndex(where: { $0.id == config.id }) else { return }
        views[idx] = config
        save()
    }

    /// Deletes view configs at the given offsets.
    func deleteViewConfigs(at offsets: IndexSet) {
        views.remove(atOffsets: offsets)
        save()
    }
}

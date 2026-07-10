// ManuscriptEditorApp.swift
//
// The application entry point.
//
// TWO STORES
// ─────────────────────────────────────────────────────────────────────────────
// The app uses two `@Observable` stores:
//
//   ManuscriptStore — the currently open manuscript (content, journals, settings).
//                     One instance; holds one Manuscript at a time.
//
//   AppStore        — global accounts and templates that persist across manuscripts:
//                       • BackendAccounts (GitHub, Google Docs, …)
//                       • AIServiceAccounts (Claude, ChatGPT, …)
//                       • ViewConfigs (layout/export templates)
//                     Saved to app.json; independent of any single manuscript.
//
// Both are created here with `@State` (SwiftUI owns them for the app's lifetime)
// and injected via `.environment(…)` so every view can read them with
// `@Environment(ManuscriptStore.self)` and `@Environment(AppStore.self)`.
//
// SCENES
// ─────────────────────────────────────────────────────────────────────────────
//   WindowGroup   → the main editor window (ContentView)
//   Settings      → the ⌘-comma preferences window (SettingsView)

import SwiftUI

/// The root of the application.  Created automatically when the app launches.
@main
struct ManuscriptEditorApp: App {

    /// Per-manuscript store: content, journals, letter, settings.
    @State private var store    = ManuscriptStore()

    /// Global store: backends, AI services, view configs.
    @State private var appStore = AppStore()

    /// App-wide light/dark/system appearance.
    @AppStorage(EditorPrefs.appearanceKey) private var appearance = AppearanceMode.system.rawValue

    /// The forced colour scheme, or `nil` to follow the system.
    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearance)?.colorScheme
    }

    var body: some Scene {

        // MARK: - Main window

        WindowGroup {
            ContentView()
                .environment(store)       // available as @Environment(ManuscriptStore.self)
                .environment(appStore)    // available as @Environment(AppStore.self)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            ManuscriptCommands()
        }

        // MARK: - Preferences window (⌘,)

        Settings {
            SettingsView()
                .environment(store)
                .environment(appStore)
                .preferredColorScheme(colorScheme)
        }
    }
}

// SettingsView.swift
//
// The ⌘-comma Preferences window — **app-wide** settings only (the
// manuscript-scoped Backend/AI selections live in the sidebar's Manuscript
// section):
//
//   Editor   — appearance, font, line spacing
//   Accounts — every external account in one place: storage backends
//              (GitHub, GitLab, …) and AI services (Claude, OpenAI, …),
//              each with credentials in the Keychain and Test Connection
//   Journals — the global journal library (search, details, requirements)
//   User     — the local identity: name + signing key for stamps/comments

import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var appStore

    @AppStorage("autoSave")                  private var autoSave    = true
    @AppStorage(EditorPrefs.appearanceKey)   private var appearance  = AppearanceMode.system.rawValue
    @AppStorage(EditorPrefs.fontKey)         private var defaultFont = EditorPrefs.defaultFont
    @AppStorage(EditorPrefs.fontSizeKey)     private var fontSize    = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.lineSpacingKey)  private var lineSpacing = EditorPrefs.defaultLineSpacing

    var body: some View {
        TabView {
            editorTab
                .tabItem { Label("Editor", systemImage: "textformat") }

            AccountsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle.badge.plus") }

            JournalLibraryView()
                .tabItem { Label("Journals", systemImage: "building.columns") }

            UserIdentityView()
                .tabItem { Label("User", systemImage: "signature") }
        }
        .frame(width: 720, height: 520)
    }

    // MARK: - Editor tab

    private var editorTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Editing") {
                Toggle("Auto-save", isOn: $autoSave)
                Picker("Editor font", selection: $defaultFont) {
                    Text("Serif").tag("Serif")
                    Text("Sans-serif").tag("Sans")
                    Text("Monospace").tag("Mono")
                }
                LabeledContent("Font size") {
                    Slider(value: $fontSize, in: 13...22, step: 1)
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44)
                }
                LabeledContent("Line spacing") {
                    Slider(value: $lineSpacing, in: 1.0...2.5, step: 0.25)
                    Text(String(format: "%.2f×", lineSpacing))
                        .monospacedDigit()
                        .frame(width: 44)
                }
            }

            Section {
                proseSample
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// A live sample of the current editor typography.
    private var proseSample: some View {
        let typography = EditorTypography(
            family: defaultFont, size: fontSize, lineSpacingMultiplier: lineSpacing
        )
        return Text("The quick brown fox jumps over the lazy dog. Clear typography keeps long manuscripts comfortable to read and edit.")
            .font(typography.font)
            .lineSpacing(typography.lineSpacingPoints)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

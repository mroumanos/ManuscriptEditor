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
    @AppStorage(EditorPrefs.citationStyleKey) private var citationStyle = "n"
    @AppStorage(EditorPrefs.zoomKey)          private var zoom = EditorPrefs.defaultZoom

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

            Section("Citations") {
                // App-wide: every in-text citation (single or multi) in
                // every manuscript renders with this format.
                Picker("Citation format", selection: $citationStyle) {
                    Text("Numeric — [1]").tag("n")
                    Text("Parenthesized — (1)").tag("p")
                    Text("Superscript — ¹").tag("s")
                    Text("Author–Year — (Smith et al., 2024)").tag("ay")
                    Text("Narrative — Smith et al. (2024)").tag("na")
                }
                .onChange(of: citationStyle) { _, code in
                    // Nudge open editors through the store mirror.
                    NotificationCenter.default.post(name: .setCitationFormat, object: nil,
                                                    userInfo: ["code": code])
                }
            }

            Section("Editing") {
                Toggle("Auto-save", isOn: $autoSave)
                // Phase 2: editors render the DOCUMENT's typography (the
                // journal's export format) — zoom is the personal comfort
                // knob, a pure display scale that never touches the file.
                LabeledContent("Display zoom") {
                    Slider(value: $zoom, in: 1.0...2.0, step: 0.1)
                    Text("\(Int((zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 48)
                }
                Text("Editors show each section in its journal's export font, size, and spacing; zoom only scales the display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// A live sample of the zoom scale, over a representative 12 pt export
    /// face (the actual face/size comes from each journal's export format).
    private var proseSample: some View {
        let typography = EditorTypography(
            family: EditorPrefs.defaultFont,
            size: EditorPrefs.defaultFontSize * zoom,
            lineSpacingMultiplier: EditorPrefs.defaultLineSpacing
        )
        return Text("The quick brown fox jumps over the lazy dog. Clear typography keeps long manuscripts comfortable to read and edit.")
            .font(typography.font)
            .lineSpacing(typography.lineSpacingPoints)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

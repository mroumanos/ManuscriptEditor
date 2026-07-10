// SettingsView.swift
//
// The ⌘-comma Preferences window.
//
// Tabs:
//   Editor  — auto-save, font, line spacing
//   Backend — global backend accounts (formerly Global → Backend)
//   Views   — view template management (formerly Global → Views)
//   AI      — AI service accounts (formerly Global → AI)
//   Export  — Phase 2 export settings

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

            BackendView()
                .tabItem { Label("Backend", systemImage: "externaldrive.connected.to.line.below") }

            GlobalViewsView()
                .tabItem { Label("Views", systemImage: "rectangle.split.3x1") }

            AIServicesView()
                .tabItem { Label("AI", systemImage: "sparkles") }

            exportTab
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 680, height: 480)
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

    // MARK: - Export tab (Phase 2)

    private var exportTab: some View {
        Form {
            Section("Export (Phase 2)") {
                Picker("Default format", selection: .constant("docx")) {
                    ForEach(ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt.rawValue)
                    }
                }
                .disabled(true)
            }
            Section {
                Text("Export configuration will be enabled in Phase 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

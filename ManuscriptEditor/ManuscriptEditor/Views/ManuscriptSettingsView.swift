// ManuscriptSettingsView.swift
//
// Per-manuscript settings panel.
//
// LEFT PANE (sidebar list)
//   • Backend     — pick the active sync backend
//   • Editor      — how text is DISPLAYED in every prose editor (font, size,
//                   spacing; global — identical across all journals/versions;
//                   output typography is set per journal in Export)
//   • AI Service  — pick the active AI account
//
// RIGHT PANE
//   Switches with the selection.  Defaults to Backend so it is never empty.
//
// Versions (cuts and their lineage) live in the dedicated "Versions" sidebar
// item — see VersionsView.  Global accounts are configured in Settings (⌘,).

import SwiftUI

// MARK: - ManuscriptSettingsView

struct ManuscriptSettingsView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    enum Sel: Hashable {
        case backend, editor, aiService
    }

    @State private var selection: Sel? = .backend

    /// Editor display typography — read live by every RichEditor.
    @AppStorage(EditorPrefs.fontKey)        private var editorFamily = EditorPrefs.defaultFont
    @AppStorage(EditorPrefs.fontSizeKey)    private var editorSize = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.lineSpacingKey) private var editorSpacing = EditorPrefs.defaultLineSpacing

    private var manuscript: Manuscript? { store.manuscript }

    var body: some View {
        HSplitView {
            leftList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                .frame(maxHeight: .infinity)
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left: sidebar list

    private var leftList: some View {
        List(selection: $selection) {
            Label("Backend",     systemImage: "externaldrive.connected.to.line.below")
                .tag(Sel.backend)
            Label("Editor",      systemImage: "textformat")
                .tag(Sel.editor)
            Label("AI Service",  systemImage: "sparkles")
                .tag(Sel.aiService)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Right: context panel

    @ViewBuilder
    private var rightPanel: some View {
        switch selection {
        case .backend, nil:
            settingDetail(
                title: "Active Backend",
                footer: "Files are always saved locally. A backend enables sync and collaboration."
            ) {
                if appStore.backends.isEmpty {
                    Text("No backends configured.")
                        .foregroundStyle(.secondary)
                    Text("Add one in Settings → Backend (⌘,).")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Picker("Active backend", selection: activeBackendBinding) {
                        Text("None (local only)").tag(Optional<UUID>.none)
                        ForEach(appStore.backends) { account in
                            Label(account.displayName, systemImage: account.provider.systemImage)
                                .tag(Optional(account.id))
                        }
                    }
                }
            }

        case .editor:
            settingDetail(
                title: "Editor Typography",
                footer: "How text is displayed while writing — the same in every editor, across all journals and versions. The typography of the output is set per journal in Export."
            ) {
                Picker("Font", selection: $editorFamily) {
                    Text("Sans (System)").tag("Sans")
                    Text("Serif").tag("Serif")
                    Text("Mono").tag("Mono")
                }
                Picker("Size", selection: $editorSize) {
                    ForEach([14.0, 15, 16, 17, 18, 20], id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                Picker("Line spacing", selection: $editorSpacing) {
                    Text("Single").tag(1.0)
                    Text("1.15").tag(1.15)
                    Text("1.5").tag(1.5)
                    Text("Double").tag(2.0)
                }
            }

        case .aiService:
            settingDetail(
                title: "Active AI Service",
                footer: "Required for adapting version content to journal requirements in Phase 2."
            ) {
                if appStore.aiServices.isEmpty {
                    Text("No AI services configured.")
                        .foregroundStyle(.secondary)
                    Text("Add one in Settings → AI (⌘,).")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Picker("Active AI service", selection: activeAIBinding) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(appStore.aiServices) { service in
                            Label(service.displayName, systemImage: service.provider.systemImage)
                                .tag(Optional(service.id))
                        }
                    }
                }
            }
        }
    }

    // Shared wrapper for the three picker panels.
    @ViewBuilder
    private func settingDetail<Content: View>(
        title: String,
        footer: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            Form {
                Section {
                    content()
                } header: {
                    Text(title)
                } footer: {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Bindings

    private var activeBackendBinding: Binding<UUID?> {
        Binding(
            get: { manuscript?.settings.activeBackendID },
            set: { id in
                guard var s = manuscript?.settings else { return }
                s.activeBackendID = id
                store.updateManuscriptSettings(s)
            }
        )
    }

    private var activeAIBinding: Binding<UUID?> {
        Binding(
            get: { manuscript?.settings.activeAIServiceID },
            set: { id in
                guard var s = manuscript?.settings else { return }
                s.activeAIServiceID = id
                store.updateManuscriptSettings(s)
            }
        )
    }
}

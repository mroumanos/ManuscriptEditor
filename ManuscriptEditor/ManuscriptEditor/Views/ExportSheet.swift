// ExportSheet.swift
//
// Presents the export flow: pick which version to export, the document format,
// then a destination folder. Writes the submission package via `ExportService`
// and reveals it in Finder.

import SwiftUI
import AppKit

struct ExportSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.dismiss)            private var dismiss

    /// Selected version to export.
    @State private var selection: VersionRef = .source
    /// Selected document format.
    @State private var format: ExportService.Format = .docx
    @State private var errorMessage: String?

    private let service = ExportService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Submission Package").font(.headline)

            Form {
                Picker("Version", selection: $selection) {
                    Text("Source").tag(VersionRef.source)
                    ForEach(store.versions) { version in
                        Text(version.label.isEmpty ? "(unnamed version)" : version.label)
                            .tag(VersionRef.version(version.id))
                    }
                }
                Picker("Format", selection: $format) {
                    ForEach(ExportService.Format.allCases) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }
            }
            .formStyle(.grouped)

            Text("Exports everything needed to submit — the manuscript document, a separate figures file when the journal requires it, and copies of figure images — into a folder you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Folder & Export…") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.manuscript(for: selection) == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    // MARK: - Export

    private func runExport() {
        guard let content = store.manuscript(for: selection) else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose where to save the submission package"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let folder = try service.exportPackage(
                content: content,
                journalName: packageName(for: selection),
                requiresSeparateFigures: requiresSeparateFigures(for: selection),
                format: format,
                figureURL: { store.figureURL(for: $0) },
                chartImage: { ExportRendering.chartImage(for: $0, store: store) },
                into: destination
            )
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Package name = the version's label / journal name, or the manuscript title for Source.
    private func packageName(for ref: VersionRef) -> String {
        switch ref {
        case .source:
            return store.manuscript?.title ?? "Manuscript"
        case .version(let id):
            let version = store.versions.first { $0.id == id }
            if let jid = version?.journalID,
               let journal = store.manuscript?.journals.first(where: { $0.id == jid }) {
                return journal.name
            }
            return version?.label ?? "Version"
        }
    }

    /// Whether the target journal wants figures submitted separately.
    private func requiresSeparateFigures(for ref: VersionRef) -> Bool {
        guard case .version(let id) = ref,
              let jid = store.versions.first(where: { $0.id == id })?.journalID,
              let journal = store.manuscript?.journals.first(where: { $0.id == jid })
        else { return false }
        return journal.requirements.requiresSeparateFigures
    }
}

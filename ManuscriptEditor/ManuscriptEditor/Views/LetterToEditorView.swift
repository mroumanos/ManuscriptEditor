// LetterToEditorView.swift
//
// Editor for the manuscript's cover letter (letter to the editor).
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
// The view uses a VSplitView so the header/signature form and the body editor
// are independently resizable — useful because the body is usually much longer.
//
// TOP HALF — Header form + signature:
//   • Icon picker (SF Symbol) and institution name / subtitle
//   • Signature block (plain text, monospaced font)
//
// BOTTOM HALF — Body TextEditor:
//   • Main letter text: why this journal, study novelty, conflict of interest, etc.
//
// PREVIEW PANEL
// ─────────────────────────────────────────────────────────────────────────────
// A "Preview" toggle shows a read-only approximation of the finished letter,
// assembled from header + body + signature.  This lets authors check the
// overall look before submitting.
//
// AUTO-SAVE
// ─────────────────────────────────────────────────────────────────────────────
// Every field change calls `store.updateLetterToEditor(_:)` via `onChange`,
// which routes through the `touch(_:)` helper in `ManuscriptStore` to bump
// `updatedAt` and persist to disk.

import SwiftUI

// MARK: - LetterToEditorView

/// Full editor for the manuscript's cover letter.
struct LetterToEditorView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// Mutable working copy to avoid writing to the store on every render.
    @State private var draft: LetterToEditor = .empty()
    @State private var showPreview = false
    @State private var showIconPicker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if showPreview {
                previewPanel
            } else {
                editorPanel
            }
        }
        .onAppear {
            if let letter = store.manuscript(for: versionRef)?.letterToEditor {
                draft = letter
            }
        }
        // Sync from external changes (e.g. undo, cut switch).
        .onChange(of: store.manuscript(for: versionRef)?.letterToEditor.headerTitle) { _, _ in syncDraft() }
        // Auto-save
        .onChange(of: draft.headerIconName) { _, _ in store.updateLetterToEditor(draft, ref: versionRef) }
        .onChange(of: draft.headerTitle)    { _, _ in store.updateLetterToEditor(draft, ref: versionRef) }
        .onChange(of: draft.headerSubtitle) { _, _ in store.updateLetterToEditor(draft, ref: versionRef) }
        .onChange(of: draft.body)           { _, _ in store.updateLetterToEditor(draft, ref: versionRef) }
        .onChange(of: draft.signature)      { _, _ in store.updateLetterToEditor(draft, ref: versionRef) }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Spacer()
            Toggle(isOn: $showPreview) {
                Label("Preview", systemImage: "eye")
            }
            .toggleStyle(.button)
            .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Editor panel

    private var editorPanel: some View {
        VSplitView {
            metadataForm
                .frame(minHeight: 220, idealHeight: 280)
            bodyEditor
                .frame(minHeight: 200)
        }
    }

    // MARK: – Top: header + signature form

    private var metadataForm: some View {
        ScrollView {
            Form {
                Section("Header") {
                    // Icon selection
                    HStack(spacing: 12) {
                        Image(systemName: draft.headerIconName)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Header icon").font(.caption).foregroundStyle(.secondary)
                            Button("Change Icon") { showIconPicker = true }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                    TextField("Institution / Lab name", text: $draft.headerTitle)
                    TextField("Department or subtitle (optional)", text: $draft.headerSubtitle)
                }

                Section("Signature") {
                    TextEditor(text: $draft.signature)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(selected: $draft.headerIconName, isPresented: $showIconPicker)
        }
    }

    // MARK: – Bottom: letter body

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Letter Body")
                    .font(.headline)
                Spacer()
                Text("\(WordCountService.count(draft.body.plain)) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            Divider()
            RichEditor(value: $draft.body, placeholder: "Dear Editor,…", versionRef: versionRef)
        }
    }

    // MARK: - Preview panel

    /// Read-only assembled preview of the full letter.
    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header block
                HStack(spacing: 12) {
                    Image(systemName: draft.headerIconName)
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        if !draft.headerTitle.isEmpty {
                            Text(draft.headerTitle).font(.title3.weight(.semibold))
                        }
                        if !draft.headerSubtitle.isEmpty {
                            Text(draft.headerSubtitle).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.bottom, 8)

                Divider()

                // Body
                if draft.body.isEmpty {
                    Text("(letter body is empty)")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(draft.body.plain)
                        .lineSpacing(4)
                }

                // Signature
                if !draft.signature.isEmpty {
                    Divider()
                    Text(draft.signature)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Helpers

    private func syncDraft() {
        if let letter = store.manuscript(for: versionRef)?.letterToEditor {
            draft = letter
        }
    }
}

// MARK: - IconPickerSheet

/// Simple SF Symbol picker for the letter header icon.
struct IconPickerSheet: View {
    @Binding var selected: String
    @Binding var isPresented: Bool

    /// A curated list of institution-relevant SF Symbols.
    private let icons: [String] = [
        "building.columns",        // university / institution
        "cross.case",              // medical / hospital
        "flask",                   // lab / chemistry
        "atom",                    // physics / science
        "stethoscope",             // medicine
        "microscope",              // biology / pathology
        "heart.text.square",       // cardiology
        "brain",                   // neuroscience
        "dna",                     // genetics
        "chart.bar.doc.horizontal",// data science / statistics
        "globe.europe.africa",     // international
        "leaf",                    // ecology / environmental
        "sun.max",                 // energy / climate
        "lightbulb",               // innovation / engineering
        "person.3",                // team / collaboration
        "doc.richtext",            // documents / publication
    ]

    let columns = [GridItem(.adaptive(minimum: 52))]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Icon").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(icons, id: \.self) { name in
                    Button {
                        selected = name
                        isPresented = false
                    } label: {
                        Image(systemName: name)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(
                                selected == name
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        selected == name ? Color.accentColor : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

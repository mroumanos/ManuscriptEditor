// KeywordsView.swift
//
// Manages the manuscript's keyword list — the same shape as Authors and
// Bibliography (Aug 2026): list on the left with add/remove/reorder and the
// component's export-settings gear, editor for the selected keyword on the
// right.

import SwiftUI

struct KeywordsView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    @State private var selected: String?
    /// The right pane's edit box — kept as a draft so a rename that would
    /// collide with an existing keyword doesn't clobber it mid-typing.
    @State private var draft = ""

    private var keywords: [String] { store.manuscript(for: versionRef)?.keywords ?? [] }

    var body: some View {
        if keywords.isEmpty {
            emptyState
        } else {
            HSplitView {
                // MARK: Left — keyword list
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        Section("Keywords") {
                            ForEach(keywords, id: \.self) { keyword in
                                Label(keyword, systemImage: "tag")
                                    .tag(keyword)
                            }
                            .onMove { source, destination in
                                var list = keywords
                                list.move(fromOffsets: source, toOffset: destination)
                                store.updateKeywords(list, ref: versionRef)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.windowBackgroundColor))
                    .onAppear { autoSelect() }
                    .onChange(of: keywords) { _, _ in autoSelect() }

                    Divider()

                    HStack(spacing: 4) {
                        Button {
                            addKeyword()
                        } label: {
                            Label("Add Keyword", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 10)
                        .padding(.leading, 10)

                        Spacer()
                        // Keyword-line export settings (typography) — edited
                        // here, on the component; Export only reviews them.
                        ComponentSettingsButton(item: .keywords, versionRef: versionRef)
                            .padding(.trailing, 10)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

                // MARK: Right — keyword editor
                if let selected, keywords.contains(selected) {
                    editor(for: selected)
                } else {
                    VStack {
                        Spacer()
                        Text("Select a keyword")
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func editor(for keyword: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyword").font(.headline)
            TextField("Keyword", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onChange(of: draft) { _, new in rename(keyword, to: new) }
            Text("Keywords help journals match your submission to appropriate reviewers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                store.updateKeywords(keywords.filter { $0 != keyword }, ref: versionRef)
                selected = nil
            } label: {
                Label("Remove Keyword", systemImage: "trash")
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { draft = keyword }
        .onChange(of: selected) { _, new in draft = new ?? "" }
    }

    /// Live rename: the keyword's identity IS its text, so each edit
    /// rewrites the list entry and follows the selection.  A rename that
    /// collides with another keyword (or empties out) stays a draft.
    private func rename(_ keyword: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard trimmed != keyword else { return }
        guard !trimmed.isEmpty, !keywords.contains(trimmed) else { return }
        guard let index = keywords.firstIndex(of: keyword) else { return }
        var list = keywords
        list[index] = trimmed
        store.updateKeywords(list, ref: versionRef)
        selected = trimmed
    }

    private func addKeyword() {
        var name = "New keyword"
        var n = 2
        while keywords.contains(name) { name = "New keyword \(n)"; n += 1 }
        store.updateKeywords(keywords + [name], ref: versionRef)
        selected = name
        draft = name
    }

    private func autoSelect() {
        if selected == nil || !(selected.map(keywords.contains) ?? false) {
            selected = keywords.first
            draft = selected ?? ""
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tag")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Keywords Yet")
                .font(.title3.weight(.semibold))
            Text("Keywords help journals match your submission\nto appropriate reviewers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                addKeyword()
            } label: {
                Label("Add Keyword", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// AbstractView.swift
//
// Full-height editor for the manuscript abstract text.
// Keywords are managed separately in KeywordsView.

import SwiftUI

struct AbstractView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    @State private var abstract = RichText()

    /// In a journal's tab, the venue's prompt for the abstract — what the
    /// template's Abstract entry says — shows while it is empty.
    private var placeholder: String {
        let prompt = store.paneJournal(for: versionRef)?.structure?.abstractEntry?.formatNote ?? ""
        return prompt.isEmpty ? "Write your abstract here…" : prompt
    }

    var body: some View {
        RichEditor(value: $abstract, placeholder: placeholder, versionRef: versionRef,
                   formatItem: .abstract)
            .onChange(of: abstract) { _, new in
                guard store.manuscript(for: versionRef)?.abstract != new else { return }
                store.updateAbstract(new, ref: versionRef)
            }
            .onAppear { abstract = store.manuscript(for: versionRef)?.abstract ?? RichText() }
            .onChange(of: store.manuscript?.id) { _, _ in
                abstract = store.manuscript(for: versionRef)?.abstract ?? RichText()
            }
            // The cut changed under the pane (a smart refresh, a sync, ⌘Z):
            // the local copy follows it rather than writing the old text back.
            .onChange(of: store.manuscript(for: versionRef)?.abstract) { _, new in
                if let new, new != abstract { abstract = new }
            }
    }
}

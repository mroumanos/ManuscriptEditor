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

    var body: some View {
        RichEditor(value: $abstract, placeholder: "Write your abstract here…", versionRef: versionRef)
            .onChange(of: abstract) { _, new in store.updateAbstract(new, ref: versionRef) }
            .onAppear { abstract = store.manuscript(for: versionRef)?.abstract ?? RichText() }
            .onChange(of: store.manuscript?.id) { _, _ in
                abstract = store.manuscript(for: versionRef)?.abstract ?? RichText()
            }
    }
}

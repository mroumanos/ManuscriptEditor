// TitleView.swift
//
// Content → Title: the article's title as submitted to a journal.
//
// The PROJECT name (Welcome screen, window title, File → Manage Manuscripts)
// stays on `Manuscript.title`; the ARTICLE title here is journal-facing
// content — versioned with every cut, so NEJM's title can differ from JAMA's.
// Exports print it when set, falling back to the project name.

import SwiftUI

struct TitleView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    @State private var articleTitle = ""
    @State private var runningTitle = ""
    @State private var subtitle = ""

    private var target: Manuscript? { store.manuscript(for: versionRef) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Title").font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Article title").font(.headline)
                    TextField("Full title as submitted to the journal", text: $articleTitle, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .lineLimit(2...5)
                        .onChange(of: articleTitle) { _, new in
                            store.updateArticleTitle(new, ref: versionRef)
                        }
                    Text("Journal-facing content — each cut carries its own, so the title can differ journal to journal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Subtitle").font(.headline)
                    TextField("Optional subtitle, printed under the title", text: $subtitle, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .onChange(of: subtitle) { _, new in
                            store.updateSubtitle(new, ref: versionRef)
                        }
                    Text("Rendered on the title page one heading level below the title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Running title").font(.headline)
                    TextField("Shortened title for page headers (often ≤ 50 characters)", text: $runningTitle)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: runningTitle) { _, new in
                            store.updateRunningTitle(new, ref: versionRef)
                        }
                    Text("\(runningTitle.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { syncDrafts() }
        .onChange(of: target?.articleTitle) { _, _ in syncDrafts() }
        .onChange(of: target?.subtitle)     { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        guard let m = target else { return }
        if articleTitle != (m.articleTitle ?? "") { articleTitle = m.articleTitle ?? "" }
        if runningTitle != m.runningTitle { runningTitle = m.runningTitle }
        if subtitle != (m.subtitle ?? "") { subtitle = m.subtitle ?? "" }
    }
}

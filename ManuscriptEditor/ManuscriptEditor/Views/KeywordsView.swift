// KeywordsView.swift
//
// Manages the manuscript's keyword list.
// Each keyword is displayed as a chip with an inline delete button.
// New keywords are added via a text field with an Add button.

import SwiftUI

struct KeywordsView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    @State private var newKeyword = ""
    @FocusState private var fieldFocused: Bool

    private var keywords: [String] { store.manuscript(for: versionRef)?.keywords ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Add field
                HStack(spacing: 8) {
                    TextField("Add keyword…", text: $newKeyword)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit { addKeyword() }
                    Button("Add") { addKeyword() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()

                if keywords.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tag")
                            .font(.system(size: 32, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("No keywords added yet")
                            .foregroundStyle(.secondary)
                        Text("Keywords help journals match your submission\nto appropriate reviewers.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(keywords, id: \.self) { kw in
                            keywordChip(kw)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }

                Spacer(minLength: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func keywordChip(_ keyword: String) -> some View {
        HStack(spacing: 6) {
            Text(keyword)
                .font(.callout)
            Button {
                store.updateKeywords(keywords.filter { $0 != keyword }, ref: versionRef)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .help("Remove \"\(keyword)\"")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(.blue.opacity(0.12), in: Capsule())
        .foregroundStyle(.blue)
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !keywords.contains(trimmed) else {
            newKeyword = ""
            return
        }
        store.updateKeywords(keywords + [trimmed], ref: versionRef)
        newKeyword = ""
    }
}

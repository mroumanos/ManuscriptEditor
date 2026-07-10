// WelcomeView.swift
//
// Screen shown when no manuscript is open.
// The "New Manuscript" button invokes `onNewManuscript` (injected by ContentView)
// which shows an NSOpenPanel folder picker before creating the manuscript.

import SwiftUI

struct WelcomeView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Called when the user wants to create a new manuscript.
    /// ContentView provides this closure, which shows the folder picker.
    var onNewManuscript: () -> Void

    @State private var recentManuscripts: [ManuscriptSummary] = []

    var body: some View {
        HStack(spacing: 0) {
            // Left column — branding and new-manuscript action
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "doc.richtext")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Manuscript Editor")
                        .font(.largeTitle.weight(.semibold))
                    Text("A source-of-truth for every paper you write.")
                        .foregroundStyle(.secondary)
                }

                Button(action: onNewManuscript) {
                    Label("New Manuscript", systemImage: "plus.circle.fill")
                        .font(.title3)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Right column — recent manuscripts
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent")
                    .font(.headline)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)

                if recentManuscripts.isEmpty {
                    VStack {
                        Spacer()
                        Text("No recent manuscripts")
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(recentManuscripts) { summary in
                        Button {
                            store.open(id: summary.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(summary.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 280)
        }
        .onAppear {
            recentManuscripts = store.listSaved()
        }
    }
}

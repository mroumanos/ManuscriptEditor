// ZoteroImportSheet.swift
//
// Browse the user's locally-running Zotero library, search it, select
// references, and import them into the bibliography of a given version.
// Degrades gracefully with a clear message when Zotero isn't reachable.

import SwiftUI

struct ZoteroImportSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.dismiss)            private var dismiss

    /// The version whose bibliography receives the imported entries.
    let versionRef: VersionRef

    private let service = ZoteroService()

    @State private var query = ""
    @State private var reloadToken = 0
    @State private var items: [ZoteroItem] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Zotero").font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your Zotero library…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { reloadToken += 1 }
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            content

            HStack {
                Text(selected.isEmpty ? "" : "\(selected.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import Selected") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task(id: reloadToken) { await load() }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text(errorMessage)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Retry") { reloadToken += 1 }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if items.isEmpty && !loading {
            VStack {
                Spacer()
                Text("No items found.").foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ item: ZoteroItem) -> some View {
        let isSelected = selected.contains(item.key)
        return Button {
            if isSelected { selected.remove(item.key) } else { selected.insert(item.key) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).fontWeight(.medium).lineLimit(2)
                    HStack(spacing: 6) {
                        if let first = item.creators.first?.formatted, !first.isEmpty {
                            Text(item.creators.count > 1 ? "\(first) et al." : first)
                        }
                        if let year = yearText(item) { Text("· \(year)") }
                        Text("· \(item.itemType)")
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            items = try await service.fetchItems(matching: query)
        } catch {
            items = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func importSelected() {
        for item in items where selected.contains(item.key) {
            store.addBibEntry(service.bibEntry(from: item), ref: versionRef)
        }
        dismiss()
    }

    private func yearText(_ item: ZoteroItem) -> String? {
        if let match = item.date.range(of: #"\d{4}"#, options: .regularExpression) {
            return String(item.date[match])
        }
        return nil
    }
}

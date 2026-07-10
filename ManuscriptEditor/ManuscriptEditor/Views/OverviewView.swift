// OverviewView.swift
//
// The manuscript dashboard: title + save/sync timestamps, the Source content
// snapshot (authors, keywords, abstract), and one row per journal showing its
// version state and when it was last edited.  Deliberately timer-free and
// statistics-free — the two timestamps that matter are *last saved to disk*
// and *last synced to the backend*.

import SwiftUI

/// Dashboard view showing manuscript metadata at a glance.
struct OverviewView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Whether the title is in edit mode (TextField vs display Text).
    @State private var isEditingTitle = false
    /// Local copy of the title while the user is typing, before it is committed.
    @State private var draftTitle = ""

    /// Force-unwrap is safe here because `OverviewView` is only shown when
    /// `store.manuscript != nil` (enforced by `ContentView`).
    private var m: Manuscript { store.manuscript! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                titleCard
                sourceCard
                journalsCard
            }
            .padding(28)
        }
    }

    // MARK: - Title card

    /// Displays the manuscript title with an inline edit mode, plus the two
    /// timestamps that matter: last saved (disk) and last synced (backend).
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("Manuscript title", text: $draftTitle, onCommit: {
                    store.updateTitle(draftTitle)
                    isEditingTitle = false
                })
                .font(.title.weight(.semibold))
                .textFieldStyle(.plain)
                .onExitCommand { isEditingTitle = false }   // Escape cancels
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.title)
                        .font(.title.weight(.semibold))
                    Button {
                        draftTitle = m.title
                        isEditingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit title")
                }
            }

            if !m.runningTitle.isEmpty {
                Text("Running title: \(m.runningTitle)")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            HStack(spacing: 16) {
                Label("Saved \(m.updatedAt.formatted(date: .abbreviated, time: .shortened)) (to disk)",
                      systemImage: "internaldrive")
                if let synced = m.lastSyncedAt {
                    Label("Synced \(synced.formatted(date: .abbreviated, time: .shortened)) (to backend)",
                          systemImage: "icloud")
                } else {
                    Label("Never synced to a backend", systemImage: "icloud.slash")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Source content card

    /// The Source's key front matter — authors, keywords, abstract — clearly
    /// annotated as Source (journal cuts adapt these per journal).
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Authors, Keywords & Abstract")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Source")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 14) {
                if m.authors.isEmpty {
                    Text("No authors added yet.")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.authors.sorted { $0.order < $1.order }) { author in
                            HStack(spacing: 8) {
                                Text("\(author.order + 1).")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, alignment: .trailing)
                                    .monospacedDigit()
                                Text(author.displayName.isEmpty ? "(unnamed)" : author.displayName)
                                    .fontWeight(author.isCorresponding ? .semibold : .regular)
                                if author.isCorresponding {
                                    Image(systemName: "envelope.badge")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                        .help("Corresponding author")
                                }
                                if !author.affiliations.filter({ !$0.isEmpty }).isEmpty {
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(author.affiliations.filter { !$0.isEmpty }.joined(separator: "; "))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }

                if !m.keywords.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(m.keywords, id: \.self) { kw in
                            Text(kw)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                }

                if !m.abstract.plain.isEmpty {
                    Text(m.abstract.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Journals card

    /// One row per journal — Source included and annotated — showing its
    /// version position ("v2 / latest") and when it was last edited.
    private var journalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Journals")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                journalRow(
                    name: "Source", isSource: true,
                    versionText: m.versions.filter { $0.sourceStamp == true }.isEmpty
                        ? "latest"
                        : "v\(store.sourceStamps.count) / latest",
                    lastEdited: m.updatedAt)
                Divider()
                ForEach(Array(m.journals.enumerated()), id: \.element.id) { index, journal in
                    let chain = store.versions(forJournal: journal.id)
                    journalRow(
                        name: journal.name, isSource: false,
                        versionText: chain.count > 1 ? "v\(chain.count - 1) / latest" : "latest",
                        lastEdited: chain.last?.content.updatedAt ?? journal.createdAt)
                    if index < m.journals.count - 1 { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func journalRow(name: String, isSource: Bool,
                            versionText: String, lastEdited: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSource ? "doc.text" : "building.columns")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(name).fontWeight(.semibold)
            if isSource {
                Text("Source")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Text(versionText)
                .font(.callout.weight(.medium).monospacedDigit())
            Text("edited \(lastEdited.formatted(date: .abbreviated, time: .omitted)) (last edited)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - FlowLayout

/// A custom `Layout` that places its children in rows, wrapping to the next row when
/// the current row is full — like CSS `flex-wrap: wrap`.
///
/// SwiftUI does not include a built-in flow layout, so we implement the `Layout`
/// protocol ourselves.  The two required methods are:
///   - `sizeThatFits`  → tell SwiftUI how large this layout needs to be
///   - `placeSubviews` → position each child view within the allocated space
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

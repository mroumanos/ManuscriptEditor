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

    /// Placeholder-backed: ContentView only routes here with a manuscript
    /// open, but closing to Welcome (File → Manage Manuscripts…) nils the
    /// manuscript while this view is still on screen for one update pass —
    /// a force-unwrap here crashed the app.
    @State private var placeholder = Manuscript.new()
    private var m: Manuscript { store.manuscript ?? placeholder }

    var body: some View {
        if store.manuscript != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    summaryCard
                    journalsCard
                }
                .padding(28)
            }
        }
    }

    // MARK: - Summary card

    /// The whole dashboard header in one card: editable title, the three
    /// timestamps on their own lines, everyone who has edited (with
    /// verification badges), and an editable description.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                // Title (modifiable, as before).
                if isEditingTitle {
                    TextField("Manuscript title", text: $draftTitle, onCommit: {
                        store.updateTitle(draftTitle)
                        isEditingTitle = false
                    })
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onExitCommand { isEditingTitle = false }   // Escape cancels
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.title)
                            .font(.title2.weight(.semibold))
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

                // Timestamps, one per line.
                VStack(alignment: .leading, spacing: 3) {
                    timestampLine("Created", m.createdAt.formatted(date: .abbreviated, time: .omitted))
                    timestampLine("Saved (local)", m.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    timestampLine("Saved (remote)",
                                  m.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                }

                // Everyone who has stamped a version or written a note.
                VStack(alignment: .leading, spacing: 6) {
                    subsectionLabel("Editors")
                    if editors.isEmpty {
                        Text(m.updatedAt > m.createdAt.addingTimeInterval(1)
                             ? "Edited locally — set your name in Preferences → User to appear here."
                             : "No edit activity recorded yet.")
                            .foregroundStyle(.tertiary)
                            .italic()
                            .font(.callout)
                    } else {
                        ForEach(editors) { editor in
                            SignatureBadge(
                                signerName: editor.name,
                                signerKey: editor.key,
                                signerType: editor.type,
                                message: editor.message,
                                signature: editor.signature
                            )
                            .font(.subheadline)
                        }
                    }
                }

                // Modifiable description.
                VStack(alignment: .leading, spacing: 6) {
                    subsectionLabel("Description")
                    TextField("Describe this manuscript…", text: Binding(
                        get: { m.about ?? "" },
                        set: { store.updateAbout($0) }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(2...8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func timestampLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subsectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.5)
    }

    // MARK: - Editors (unique signers across stamps + notes)

    private struct EditorEntry: Identifiable {
        let id: String
        let name: String
        let key: String?
        let type: String?
        let message: String?
        let signature: String?
        let date: Date
    }

    /// One row per distinct signer (key, or name when unsigned), badged
    /// against their most recent artifact.
    private var editors: [EditorEntry] {
        var latest: [String: EditorEntry] = [:]
        for version in store.versions where !version.author.isEmpty {
            let id = version.stampedByKey ?? "name:\(version.author)"
            let entry = EditorEntry(
                id: id, name: version.author, key: version.stampedByKey,
                type: version.stampedByType,
                message: SigningService.stampMessage(
                    id: version.id, createdAt: version.createdAt, author: version.author),
                signature: version.stampSignature, date: version.createdAt)
            if (latest[id]?.date ?? .distantPast) < entry.date { latest[id] = entry }
        }
        for note in m.notes where !note.author.isEmpty {
            let id = note.authorKey ?? "name:\(note.author)"
            let entry = EditorEntry(
                id: id, name: note.author, key: note.authorKey,
                type: note.authorType,
                message: SigningService.noteMessage(
                    id: note.id, createdAt: note.createdAt, body: note.body),
                signature: note.signature, date: note.createdAt)
            if (latest[id]?.date ?? .distantPast) < entry.date { latest[id] = entry }
        }
        // Live edits count too: before any stamp or note exists (a fresh
        // Source-only manuscript is the common case), the current user's
        // ongoing editing still shows.  The entry is signed with their
        // identity key on the spot, so the badge carries the real ✓/?
        // verdict instead of falling to unsigned.
        let userName = SigningService.userName
        if !userName.isEmpty, m.updatedAt > m.createdAt.addingTimeInterval(1) {
            let id = SigningService.publicKeyBase64 ?? "name:\(userName)"
            let alreadyListed = latest[id] != nil || latest["name:\(userName)"] != nil
            if !alreadyListed {
                let message = "editing:\(m.id.uuidString):\(userName)"
                latest[id] = EditorEntry(
                    id: id, name: userName,
                    key: SigningService.publicKeyBase64,
                    type: SigningService.effectiveIdentityType,
                    message: message,
                    signature: SigningService.sign(message),
                    date: m.updatedAt)
            }
        }
        return latest.values.sorted { $0.date > $1.date }
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

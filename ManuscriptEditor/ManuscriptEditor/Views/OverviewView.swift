// OverviewView.swift
//
// A read-only dashboard for the manuscript: title, statistics, author list, and keywords.
// It is the first thing the user sees after opening or creating a manuscript.
// Click the pencil icon next to the title to rename the manuscript inline.

import SwiftUI

/// Dashboard view showing manuscript metadata and statistics at a glance.
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
                statsGrid
                journalCutsCard
                authorsCard
                keywordsCard
            }
            .padding(28)
        }
    }

    // MARK: - Title card

    /// Displays the manuscript title with an inline edit mode.
    ///
    /// Tapping the pencil switches to a `TextField`.  Pressing Return or clicking
    /// elsewhere (onExitCommand) commits the change or cancels it.
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                // TextField bound to draftTitle; committing saves to store.
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
                    // Pencil button switches to edit mode.
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

            // Creation date and last-modified relative timestamp.
            HStack(spacing: 16) {
                Label(m.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                Label(m.updatedAt, systemImage: "clock", style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Stats grid

    /// A grid of `StatCard` tiles: word count, section count, figure/table/reference counts.
    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Statistics")
                .font(.headline)
                .foregroundStyle(.secondary)

            // `LazyVGrid` with adaptive columns automatically wraps onto new rows
            // as the window gets narrower.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                StatCard(value: "\(m.bodyWordCount)",     label: "Body Words",  icon: "text.word.spacing")
                StatCard(value: "\(m.abstractWordCount)", label: "Abstract Words", icon: "text.quote")
                StatCard(value: "\(m.sections.count)",   label: "Sections",    icon: "square.stack")
                StatCard(value: "\(m.figures.count)",    label: "Figures",     icon: "photo.on.rectangle.angled")
                StatCard(value: "\(m.tables.count)",     label: "Tables",      icon: "tablecells")
                StatCard(value: "\(m.bibliography.count)", label: "References", icon: "books.vertical")
            }
        }
    }

    // MARK: - Journal cuts card

    /// One row of statistics per journal cut, beside the Source stats above:
    /// current head version, word/asset counts of the head's content, and its
    /// live checks state — the "how is each cut doing?" dashboard.
    @ViewBuilder
    private var journalCutsCard: some View {
        let cuts: [(journal: Journal, head: ManuscriptVersion)] =
            m.journals.compactMap { journal in
                store.latestVersion(forJournal: journal.id).map { (journal, $0) }
            }
        if !cuts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Journal Cuts")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(cuts.enumerated()), id: \.element.journal.id) { index, cut in
                        journalCutRow(cut.journal, head: cut.head)
                        if index < cuts.count - 1 { Divider() }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func journalCutRow(_ journal: Journal, head: ManuscriptVersion) -> some View {
        let content = head.content
        let checks = ChecklistService.run(manuscript: content, requirements: journal.requirements)
        let passed = checks.filter(\.passed).count

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(journal.name).fontWeight(.semibold)
                Text("v\(store.journalOrdinal(of: head)) · \(head.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 130, alignment: .leading)

            Spacer()

            statChip("\(content.bodyWordCount)", "body words")
            statChip("\(content.abstractWordCount)", "abstract")
            statChip("\(content.figures.count)", "figures")
            statChip("\(content.tables.count)", "tables")
            statChip("\(content.bibliography.count)", "refs")

            // Live checks state, matching the Checks pane's verdict colors.
            if checks.isEmpty {
                Text("no checks")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Label("\(passed)/\(checks.count)",
                      systemImage: passed == checks.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(passed == checks.count ? .green : (passed == 0 ? .red : .orange))
                    .help("\(passed) of \(checks.count) requirement checks pass")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statChip(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 52)
    }

    // MARK: - Authors card

    private var authorsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authors")
                .font(.headline)
                .foregroundStyle(.secondary)

            if m.authors.isEmpty {
                Text("No authors added yet.")
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // Show authors in display order.
                    ForEach(m.authors.sorted { $0.order < $1.order }) { author in
                        HStack(spacing: 8) {
                            Text("\(author.order + 1).")
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, alignment: .trailing)
                                .monospacedDigit()
                            // Corresponding author shown in bold.
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
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Keywords card

    private var keywordsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keywords")
                .font(.headline)
                .foregroundStyle(.secondary)

            if m.keywords.isEmpty {
                Text("No keywords added yet.")
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                // FlowLayout wraps chips onto new lines when the view is narrow.
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
        }
    }
}

// MARK: - StatCard

/// A small metric tile showing an icon, a numeric value, and a label.
struct StatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()   // keeps digits from shifting width as numbers change
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
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

// MARK: - Label date helper

/// Convenience initialiser so we can write `Label(date, systemImage:, style:)`
/// instead of building the Text and Image separately.
private extension Label where Title == Text, Icon == Image {
    init(_ date: Date, systemImage: String, style: Text.DateStyle) {
        self.init {
            Text(date, style: style)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

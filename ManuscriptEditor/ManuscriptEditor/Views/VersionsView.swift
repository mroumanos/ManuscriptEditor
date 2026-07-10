// VersionsView.swift
//
// The "Versions" panel under the Journal sidebar section — **per journal**.
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
//   Journal picker (Source cuts / each target journal)
//   HSplitView
//     LEFT  — the selected journal's **linear** version history (v1 → v2 → …,
//             newest = working head), with Add Version and leaf-only delete.
//     RIGHT — the lineage diagram (upstream journal it was cut from and
//             downstream journals cut from it, modeled on
//             MasterContext/examples/lineage-detailed.png), plus the selected
//             version's details.
//
// The journal requirements/checklist editing that used to live here moved to
// the Checks pane (see ChecksView) — this pane is purely about versions.

import SwiftUI

// MARK: - VersionsView

struct VersionsView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    /// When set, this pane represents one comparison tab's journal (Source or
    /// a cut) and shows **that journal's** history only — no journal picker.
    /// nil = standalone (no tabs open); the pane falls back to Source.
    var versionRef: VersionRef? = nil

    @State private var selectedVersionID: UUID?
    @State private var showAddVersion = false

    private var manuscript: Manuscript? { store.manuscript }
    private var journals: [Journal] { manuscript?.journals ?? [] }

    /// The journal this pane shows: the tab's journal, or nil for the Source
    /// tab (whose own "chain" is the custom cuts not tied to any journal).
    private var journalID: UUID? {
        guard case .version(let id) = versionRef ?? .source else { return nil }
        return store.versions.first { $0.id == id }?.journalID
    }

    private var isSourcePane: Bool { journalID == nil }
    private var chain: [ManuscriptVersion] { store.versions(forJournal: journalID) }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                historyList
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
                    .frame(maxHeight: .infinity)
                rightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAddVersion) {
            AddVersionSheet(isPresented: $showAddVersion) { newID in
                selectedVersionID = newID
            }
        }
    }

    private var journalName: String {
        guard let journalID else { return "Source" }
        return journals.first { $0.id == journalID }?.name ?? "Journal"
    }

    // MARK: - Header (no journal picker — the pane IS the tab's journal)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Label(journalName, systemImage: isSourcePane ? "doc.text" : "building.columns")
                .font(.headline)

            Text("\(chain.count) version\(chain.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showAddVersion = true
            } label: {
                Label("Add Version", systemImage: "plus")
            }
            .disabled(manuscript == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - Left: linear history

    private var historyList: some View {
        VStack(spacing: 0) {
            if chain.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 30, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text(isSourcePane
                         ? "Source is always the live manuscript — cut versions live under their journals."
                         : "No versions for this journal yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    Button("Add Version") { showAddVersion = true }
                        .buttonStyle(.link)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedVersionID) {
                    // Newest first: the working head sits on top.
                    ForEach(chain.reversed()) { version in
                        historyRow(version)
                            .tag(version.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onAppear { autoSelect() }
                .onChange(of: chain.map(\.id)) { _, _ in autoSelect() }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func historyRow(_ version: ManuscriptVersion) -> some View {
        let ordinal = store.journalOrdinal(of: version)
        let isHead = version.id == chain.last?.id
        return HStack(spacing: 8) {
            Text("v\(ordinal)")
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(isHead ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(isHead ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // v1 is the journal's creation point — an unnamed first
                    // version reads "Created", not "(unnamed version)".
                    Text(version.label.isEmpty
                         ? (ordinal == 1 ? "Created" : "(unnamed version)")
                         : version.label)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isHead {
                        Text("Working head")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(version.createdAt.formatted(date: .abbreviated, time: .shortened))\(version.author.isEmpty ? "" : " · \(version.author)")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(parentDescription(version))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if store.isLeafVersion(version.id) {
                Button {
                    store.deleteVersion(id: version.id)
                    if selectedVersionID == version.id { selectedVersionID = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Delete version")
            }
        }
        .padding(.vertical, 3)
    }

    /// "← Source" / "← NEJM v2" — where this version was cut/synced from.
    private func parentDescription(_ version: ManuscriptVersion) -> String {
        guard let pid = version.parentID,
              let parent = store.versions.first(where: { $0.id == pid }) else { return "← Source" }
        let name: String
        if let jid = parent.journalID, let j = journals.first(where: { $0.id == jid }) {
            name = j.name
        } else {
            name = parent.label.isEmpty ? "Custom" : parent.label
        }
        return "← \(name) v\(store.journalOrdinal(of: parent))"
    }

    private func autoSelect() {
        if selectedVersionID == nil || !chain.contains(where: { $0.id == selectedVersionID }) {
            selectedVersionID = chain.last?.id   // the working head
        }
    }

    // MARK: - Right: lineage diagram + version detail

    private var rightPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LineageDiagram(highlightJournalID: journalID, highlightSource: isSourcePane)

                if let id = selectedVersionID,
                   let version = store.versions.first(where: { $0.id == id }) {
                    Divider()
                    VersionDetailView(version: version)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - LineageDiagram

/// The **entire** lineage graphic (see examples/lineage-detailed.png): one row
/// per journal — Source at the root, then every journal that has versions —
/// each drawn as a large journal circle followed by its version chain, with
/// arrows connecting the specific parent version to the specific child
/// version.  The journal the pane represents is highlighted; the rest render
/// quietly for orientation.
struct LineageDiagram: View {
    @Environment(ManuscriptStore.self) private var store

    /// The journal to highlight (nil + highlightSource = the Source pane).
    let highlightJournalID: UUID?
    var highlightSource: Bool = false

    // MARK: graph derivation

    /// A node the arrow overlay can anchor to.
    private enum Node: Hashable {
        case sourceRoot
        case version(UUID)
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let versions: [ManuscriptVersion]
        let isSelected: Bool
        let isSource: Bool
    }

    private struct Edge: Identifiable {
        let id: String
        let from: Node
        let to: Node
    }

    private func journalName(_ id: UUID?) -> String {
        guard let id else { return "Custom" }
        return store.manuscript?.journals.first(where: { $0.id == id })?.name ?? "Journal"
    }

    /// Every journal group that has versions, in manuscript order, with a
    /// trailing "Custom" group for cuts not tied to a journal.
    private var journalGroups: [UUID?] {
        var out: [UUID?] = (store.manuscript?.journals ?? [])
            .map { Optional.some($0.id) }
            .filter { !store.versions(forJournal: $0).isEmpty }
        if store.versions.contains(where: { $0.journalID == nil }) {
            out.append(nil)
        }
        return out
    }

    private var rows: [Row] {
        var rows: [Row] = [
            Row(id: "source", name: "Source", versions: [],
                isSelected: highlightSource, isSource: true)
        ]
        for gid in journalGroups {
            rows.append(Row(
                id: gid?.uuidString ?? "custom",
                name: journalName(gid),
                versions: store.versions(forJournal: gid),
                isSelected: !highlightSource && gid == highlightJournalID,
                isSource: false
            ))
        }
        return rows
    }

    /// Every cross-journal derivation: Source → first cut of a chain, and
    /// journal version → child journal version.  Same-journal succession is
    /// the dashes within a row, not an arrow.
    private var edges: [Edge] {
        var edges: [Edge] = []
        for v in store.versions {
            if let pid = v.parentID {
                if let parent = store.versions.first(where: { $0.id == pid }),
                   parent.journalID != v.journalID {
                    edges.append(Edge(id: "e-\(v.id)", from: .version(pid), to: .version(v.id)))
                }
            } else {
                edges.append(Edge(id: "e-\(v.id)", from: .sourceRoot, to: .version(v.id)))
            }
        }
        return edges
    }

    // MARK: body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lineage")
                .font(.headline)
            Text("The full derivation tree — \(highlightSource ? "Source" : journalName(highlightJournalID)) highlighted. Arrows connect the exact versions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.versions.isEmpty {
                Text("No versions yet — the diagram appears after the first cut.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 44) {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
                    .overlayPreferenceValue(NodeAnchorKey.self) { anchors in
                        GeometryReader { geo in
                            ForEach(edges) { edge in
                                if let from = anchors[edge.from], let to = anchors[edge.to] {
                                    arrow(from: geo[from], to: geo[to])
                                }
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Height pin: horizontal ScrollViews otherwise collapse/overlap
                // (see MasterContext 08 gotchas).
                .frame(height: CGFloat(rows.count) * 128)
            }
        }
    }

    // MARK: row rendering

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            journalCircle(row)
            ForEach(row.versions) { version in
                dash()
                versionCircle(version, highlight: row.isSelected)
            }
            Spacer(minLength: 0)
        }
    }

    private func journalCircle(_ row: Row) -> some View {
        let color: Color = row.isSelected ? .accentColor : .primary
        return Text(row.name)
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(6)
            .frame(width: 84, height: 84)
            .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
            .overlay(Circle().strokeBorder(color.opacity(row.isSelected ? 0.9 : 0.5),
                                           lineWidth: row.isSelected ? 2 : 1.25))
            .foregroundStyle(color)
            .anchorPreference(key: NodeAnchorKey.self, value: .bounds) { anchor in
                row.isSource ? [Node.sourceRoot: anchor] : [:]
            }
    }

    private func versionCircle(_ version: ManuscriptVersion, highlight: Bool) -> some View {
        let ordinal = store.journalOrdinal(of: version)
        let isHead = store.latestVersion(forJournal: version.journalID)?.id == version.id
        return Text("v\(ordinal)")
            .font(.caption.weight(.bold).monospacedDigit())
            .frame(width: 42, height: 42)
            .background(Circle().fill(isHead && highlight
                                      ? Color.accentColor.opacity(0.15)
                                      : Color(NSColor.controlBackgroundColor)))
            .overlay(Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 1.25))
            .help(version.label)
            .anchorPreference(key: NodeAnchorKey.self, value: .bounds) { anchor in
                [Node.version(version.id): anchor]
            }
    }

    /// The dashed connector between a journal and its versions (and between versions).
    private func dash() -> some View {
        DashedLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.tertiary)
            .frame(width: 26, height: 1)
    }

    /// A derivation arrow from the bottom of the parent node to the top of the
    /// child node.
    private func arrow(from: CGRect, to: CGRect) -> some View {
        let start = CGPoint(x: from.midX, y: from.maxY + 2)
        let end = CGPoint(x: to.midX, y: to.minY - 3)
        return ZStack {
            Path { p in
                p.move(to: start)
                // Gentle S-curve so diagonal edges stay readable.
                p.addCurve(to: end,
                           control1: CGPoint(x: start.x, y: (start.y + end.y) / 2),
                           control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
            }
            .stroke(.primary.opacity(0.65), lineWidth: 1.5)

            Path { p in
                p.move(to: end)
                p.addLine(to: CGPoint(x: end.x - 4, y: end.y - 7))
                p.addLine(to: CGPoint(x: end.x + 4, y: end.y - 7))
                p.closeSubpath()
            }
            .fill(.primary.opacity(0.65))
        }
    }

    // MARK: anchors

    private struct NodeAnchorKey: PreferenceKey {
        static var defaultValue: [Node: Anchor<CGRect>] { [:] }
        static func reduce(value: inout [Node: Anchor<CGRect>],
                           nextValue: () -> [Node: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }
}

/// A 1-pt horizontal line (stroked dashed above).
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - VersionDetailView

/// Details for one version: identity, lineage breadcrumb, notes.  The journal
/// requirements/checklist editing lives in the Checks pane.
struct VersionDetailView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    let version: ManuscriptVersion

    @State private var draft: ManuscriptVersion

    init(version: ManuscriptVersion) {
        self.version = version
        _draft = State(initialValue: version)
    }

    private var journal: Journal? {
        guard let jid = version.journalID else { return nil }
        return store.manuscript?.journals.first { $0.id == jid }
    }

    private var viewConfig: ViewConfig? {
        appStore.views.first { $0.id == version.viewConfigID }
    }

    /// "Source → Nature v1 → Science v1"
    private var breadcrumb: String {
        let names = store.lineagePath(to: version.id).map {
            $0.label.isEmpty ? "(unnamed)" : $0.label
        }
        return (["Source"] + names).joined(separator: " → ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(breadcrumb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }

            Form {
                Section("Version") {
                    TextField("Label", text: $draft.label)
                    LabeledContent("Version") {
                        Text("v\(store.journalOrdinal(of: version))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    LabeledContent("Basis") {
                        if let journal {
                            Label(journal.name, systemImage: "building.columns")
                                .foregroundStyle(.secondary)
                        } else if let viewConfig {
                            Label(viewConfig.name, systemImage: "rectangle.split.3x1")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    LabeledContent("Author") {
                        Text(version.author.isEmpty ? "—" : version.author).foregroundStyle(.secondary)
                    }
                    LabeledContent("Created") {
                        Text(version.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Cut from content of") {
                        Text(version.sourceSnapshotDate, style: .date).foregroundStyle(.secondary)
                    }
                }
                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 60)
                        .font(.callout)
                }
                if !store.isLeafVersion(version.id) {
                    Section {
                        Label("This version has child versions and cannot be deleted until they are removed.",
                              systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
        }
        .onChange(of: draft.label) { _, _ in store.updateVersion(draft) }
        .onChange(of: draft.notes) { _, _ in store.updateVersion(draft) }
        .onChange(of: version.id)  { _, _ in draft = version }
    }
}

// MARK: - AddVersionSheet

/// Sheet for cutting a new version.
///
/// The user picks:
///   1. a label,
///   2. the parent to cut from (Source or any existing version),
///   3. the basis — a target journal (existing or from a preset; its view is
///      auto-created from the requirements) or a custom view from the global
///      repository.
struct AddVersionSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @Binding var isPresented: Bool
    /// Called with the new version's id after creation.
    let onAdd: (UUID) -> Void

    enum Basis { case journal, customView }

    @State private var label = ""
    @State private var parentID: UUID? = nil
    @State private var basis: Basis = .journal

    /// Journal basis: either an existing manuscript journal or a preset name.
    enum JournalChoice: Hashable {
        case existing(UUID)
        case preset(String)
    }
    @State private var journalChoice: JournalChoice?
    @State private var customViewID: UUID?

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    /// Presets not already added to this manuscript (by name).
    private var availablePresets: [JournalPresets.JournalPreset] {
        JournalPresets.all.filter { preset in
            !journals.contains { $0.name == preset.name }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Version").font(.headline)

            TextField("Label (e.g. Nature v1)", text: $label)
                .textFieldStyle(.roundedBorder)

            // Parent: where this version is cut from.
            Picker("Cut from", selection: $parentID) {
                Text("Source").tag(Optional<UUID>.none)
                ForEach(store.versions) { version in
                    Text(version.label.isEmpty ? "(unnamed version)" : version.label)
                        .tag(Optional(version.id))
                }
            }

            Picker("Basis", selection: $basis) {
                Text("Journal").tag(Basis.journal)
                Text("Custom View").tag(Basis.customView)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if basis == .journal {
                journalPicker
            } else {
                customViewPicker
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    addVersion()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addDisabled)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: - Basis pickers

    @ViewBuilder
    private var journalPicker: some View {
        List(selection: $journalChoice) {
            if !journals.isEmpty {
                Section("This Manuscript") {
                    ForEach(journals) { journal in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(journal.name).fontWeight(.medium)
                            if !journal.publisher.isEmpty {
                                Text(journal.publisher).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(JournalChoice.existing(journal.id))
                    }
                }
            }
            Section("Presets") {
                ForEach(availablePresets) { preset in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).fontWeight(.medium)
                        Text(preset.publisher).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(JournalChoice.preset(preset.name))
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 200)
    }

    @ViewBuilder
    private var customViewPicker: some View {
        if appStore.views.isEmpty {
            Text("No views in the global repository. Create one in Settings → Views (⌘,).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("View", selection: $customViewID) {
                Text("Select a view…").tag(Optional<UUID>.none)
                ForEach(appStore.views) { config in
                    Text(config.name).tag(Optional(config.id))
                }
            }
        }
    }

    private var addDisabled: Bool {
        if label.isEmpty { return true }
        switch basis {
        case .journal:    return journalChoice == nil
        case .customView: return customViewID == nil
        }
    }

    // MARK: - Creation

    private func addVersion() {
        switch basis {
        case .journal:
            guard let choice = journalChoice else { return }

            // Resolve to a Journal on the manuscript, adding it from the preset if needed.
            var journal: Journal
            switch choice {
            case .existing(let id):
                guard let existing = journals.first(where: { $0.id == id }) else { return }
                journal = existing
            case .preset(let name):
                guard let preset = JournalPresets.all.first(where: { $0.name == name }) else { return }
                journal = Journal(
                    id: UUID(), name: preset.name, publisher: preset.publisher,
                    submissionURL: "",
                    requirements: preset.requirements,
                    viewConfigID: nil,
                    createdAt: Date()
                )
                store.addJournal(journal)
            }

            // Ensure the journal has its 1-1 auto-generated view.
            if journal.viewConfigID == nil {
                let view = ViewConfig.from(journal: journal)
                appStore.addViewConfig(view)
                journal.viewConfigID = view.id
                store.updateJournal(journal)
            }

            if let version = store.addVersion(
                label: label,
                parentID: parentID,
                journalID: journal.id,
                viewConfigID: journal.viewConfigID
            ) {
                onAdd(version.id)
            }

        case .customView:
            guard let viewID = customViewID else { return }
            if let version = store.addVersion(
                label: label,
                parentID: parentID,
                journalID: nil,
                viewConfigID: viewID
            ) {
                onAdd(version.id)
            }
        }
    }
}

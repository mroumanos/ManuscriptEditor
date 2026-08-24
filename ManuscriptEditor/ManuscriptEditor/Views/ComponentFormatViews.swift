// ComponentFormatViews.swift
//
// Component-side export formatting (the Aug 2026 export-page cleanup):
// formatting is edited WHERE the component lives, and the Export page only
// reviews it read-only.
//
//   ComponentSettingsButton — gear popover with the component's export
//     settings: typography (font/size/spacing) plus kind-specific options
//     (author delimiters/markers/+corr/+cred, bibliography citation style,
//     the title's heading look).  Sits in list components' bottom bars
//     (Authors, Bibliography, Keywords) and in the pane header for
//     components without one (Title, Figures, Tables).
//   Every component's heading (print on/off, text, style) configures in
//   the gear too — one place, one look, for text and list components
//   alike.

import SwiftUI

/// The export entry a pane maps to in the journal's outline (nil = the
/// component isn't part of any export document).
@MainActor
func componentExportEntry(_ store: ManuscriptStore,
                          item: SidebarItem, ref: VersionRef) -> ExportItem? {
    guard let key = ManuscriptStore.exportItemKey(for: item) else { return nil }
    let items = store.exportConfig(forJournal: store.journalID(for: ref))
        .documents.flatMap(\.items)
    if let hit = items.first(where: { $0.kind == key.kind && $0.sectionID == key.sectionID }) {
        return hit
    }
    // Pre-split configs carry the byline on the Title item (no .authors
    // item anywhere) — the Authors pane maps there.
    if key.kind == .authors { return items.first { $0.kind == .titlePage } }
    return nil
}

// MARK: - ComponentSettingsButton

struct ComponentSettingsButton: View {
    @Environment(ManuscriptStore.self) private var store

    let item: SidebarItem
    let versionRef: VersionRef

    @State private var showing = false

    var body: some View {
        if ManuscriptStore.exportItemKey(for: item) != nil {
            Button {
                showing = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Export settings for this component")
            .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
        }
    }

    private var entry: ExportItem? {
        componentExportEntry(store, item: item, ref: versionRef)
    }

    private func mutateItem(_ change: @escaping (inout ExportItem) -> Void) {
        store.updateExportEntry(for: item, ref: versionRef, mutateItem: change)
    }

    /// Typography writes create/extend the item's format override, seeded
    /// from the currently effective values.
    private func mutateFormat(_ change: @escaping (inout ExportDocumentFormat) -> Void) {
        let seed = store.effectiveExportFormat(for: item, ref: versionRef)
        store.updateExportEntry(for: item, ref: versionRef, mutateItem: { entry in
            var format = entry.format ?? seed
            change(&format)
            entry.format = format
        })
    }

    @ViewBuilder
    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                // Every component's heading configures HERE (one place, one
                // look).  Text components carry nothing else — their
                // typography lives in the editor toolbar; other components
                // add their own settings (typography, style, delimiters).
                switch item {
                case .abstract, .section, .letterToEditor:
                    headingSection(entry)
                case .authors:
                    typographySection
                    authorsSection(entry)
                case .title:
                    typographySection
                    titleHeadingSection(entry)
                case .keywords:
                    typographySection
                    keywordsSection(entry)
                    headingSection(entry)
                case .bibliography:
                    typographySection
                    referencesSection(entry)
                    headingSection(entry)
                default:
                    typographySection
                    headingSection(entry)
                }
                Text("Applies to this journal's export (reviewed read-only in Export).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Not in this journal's export outline — add it in Export first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var typographySection: some View {
        let format = store.effectiveExportFormat(for: item, ref: versionRef)
        Text("Export typography")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { format.fontFamily },
                set: { family in mutateFormat { $0.fontFamily = family } }
            )) {
                ForEach(ExportFontFamily.allCases) { family in
                    Text(family.shortLabel).tag(family)
                }
            }
            .labelsHidden().controlSize(.small).fixedSize()
            HStack(spacing: 1) {
                TextField("", value: Binding(
                    get: { Int(format.fontSize.rounded()) },
                    set: { value in mutateFormat { $0.fontSize = Double(min(max(value, 6), 99)) } }
                ), format: .number)
                .textFieldStyle(.roundedBorder).controlSize(.mini)
                .multilineTextAlignment(.trailing).frame(width: 30)
                Stepper("", value: Binding(
                    get: { Int(format.fontSize.rounded()) },
                    set: { value in mutateFormat { $0.fontSize = Double(min(max(value, 6), 99)) } }
                ), in: 6...99)
                .labelsHidden().controlSize(.mini)
            }
            .help("Font size (pt)")
            Picker("", selection: Binding(
                get: { format.lineSpacing },
                set: { spacing in mutateFormat { $0.lineSpacing = spacing } }
            )) {
                Text("1×").tag(1.0)
                Text("1.15").tag(1.15)
                Text("1.5").tag(1.5)
                Text("2×").tag(2.0)
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .help("Line spacing for this component")
        }
    }

    @ViewBuilder
    private func authorsSection(_ entry: ExportItem) -> some View {
        Divider()
        Text("Byline")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { entry.authorDelimiter ?? "semicolon" },
                set: { value in mutateItem { $0.authorDelimiter = value == "semicolon" ? nil : value } }
            )) {
                Text("a; b").tag("semicolon")
                Text("a, b").tag("comma")
                Text("a b").tag("space")
                Text("a / b").tag("slash")
                Text("a - b").tag("hyphen")
                Text("a ⏎ b").tag("newline")
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .help("Delimiter between authors (and affiliation lines)")
            Picker("", selection: Binding(
                get: {
                    let v = entry.affiliationMarker ?? "superscript"
                    return v == "doublecross" ? "cross" : v   // legacy value
                },
                set: { value in mutateItem { $0.affiliationMarker = value == "superscript" ? nil : value } }
            )) {
                Text("a¹").tag("superscript")
                Text("a†").tag("cross")
                Text("none").tag("none")
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .help("How authors link to their institutions — crosshatches escalate †, ‡, ††† with each institution")
            Button {
                mutateItem { $0.correspondingShown.toggle() }
            } label: {
                Text("+ corr")
                    .font(.caption)
                    .foregroundStyle(entry.correspondingShown
                        ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Annotate the corresponding author: a raised * on the name plus a \"* Corresponding author\" footnote line")
            Button {
                mutateItem { $0.authorTitlesShown.toggle() }
            } label: {
                Text("+ cred")
                    .font(.caption)
                    .foregroundStyle(entry.authorTitlesShown
                        ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Append author credentials (MD, PhD…) to the byline")
        }
    }

    @ViewBuilder
    private func referencesSection(_ entry: ExportItem) -> some View {
        Divider()
        Text("Citation style")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Picker("", selection: Binding(
            get: { entry.citationStyle },
            set: { style in mutateItem { $0.citationStyle = style } }
        )) {
            Text("Journal style").tag(String?.none)
            Text("APA").tag(String?.some("apa"))
            Text("AMA").tag(String?.some("american-medical-association"))
            Text("Vancouver").tag(String?.some("vancouver"))
            Text("MLA").tag(String?.some("modern-language-association"))
            Text("Chicago").tag(String?.some("chicago-author-date"))
            Text("Harvard").tag(String?.some("harvard-cite-them-right"))
        }
        .labelsHidden().controlSize(.small).fixedSize()
        .help("Citation style for the reference list — \"Journal style\" follows the journal's requirements")
    }

    @ViewBuilder
    private func keywordsSection(_ entry: ExportItem) -> some View {
        Divider()
        Text("Keyword line")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Picker("", selection: Binding(
            get: { entry.authorDelimiter ?? "comma" },
            set: { value in mutateItem { $0.authorDelimiter = value == "comma" ? nil : value } }
        )) {
            Text("a, b").tag("comma")
            Text("a; b").tag("semicolon")
            Text("a b").tag("space")
            Text("a / b").tag("slash")
            Text("a - b").tag("hyphen")
            Text("a ⏎ b").tag("newline")
        }
        .labelsHidden().controlSize(.small).fixedSize()
        .help("Delimiter between the exported keywords")
    }

    /// The component's heading configuration: print on/off, the printed
    /// text, and its style (bold/italic/underline, alignment, level).
    @ViewBuilder
    private func headingSection(_ entry: ExportItem) -> some View {
        Text("Heading")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Toggle("Print heading", isOn: Binding(
            get: { entry.titleShown },
            set: { on in mutateItem { $0.titleShown = on } }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Include this component's heading in the export (content always exports)")
        if entry.titleShown {
            HStack(spacing: 8) {
                TextField("", text: Binding(
                    get: { entry.customTitle ?? "" },
                    set: { text in mutateItem { $0.customTitle = text.isEmpty ? nil : text } }
                ), prompt: Text(entry.title(in: store.manuscript(for: versionRef))))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .help("The heading printed for this component — empty uses its own name")
                HeadingStyleControls(style: entry.effectiveHeadingStyle, showLevel: true) { change in
                    mutateItem { itm in
                        var hs = itm.effectiveHeadingStyle
                        change(&hs)
                        itm.headingStyle = hs
                    }
                }
            }
        }
    }

    /// The title page has no heading row (the title IS the heading), so its
    /// look — level and emphasis — lives here.
    @ViewBuilder
    private func titleHeadingSection(_ entry: ExportItem) -> some View {
        Divider()
        Text("Title heading")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        HeadingStyleControls(style: entry.effectiveHeadingStyle, showLevel: true) { change in
            mutateItem { itm in
                var hs = itm.effectiveHeadingStyle
                change(&hs)
                itm.headingStyle = hs
            }
        }
    }
}

// MARK: - HeadingStyleControls

/// Bold / underline / center (and optionally the H1–H3 level cycle) for a
/// printed heading — shared between the heading row and the title settings.
struct HeadingStyleControls: View {
    let style: ExportItem.HeadingStyle
    var showLevel: Bool = true
    let mutate: (@escaping (inout ExportItem.HeadingStyle) -> Void) -> Void

    var body: some View {
        HStack(spacing: 3) {
            toggle("bold", style.bold, "Bold heading") { $0.bold.toggle() }
            toggle("italic", style.italicOn, "Italic heading") { $0.italic = ($0.italic ?? false) ? nil : true }
            toggle("underline", style.underline, "Underlined heading") { $0.underline.toggle() }
            Picker("", selection: Binding(
                get: { style.effectiveAlignment },
                set: { align in mutate { $0.alignment = align; $0.centered = align == "center" } }
            )) {
                Image(systemName: "text.alignleft").tag("left")
                Image(systemName: "text.aligncenter").tag("center")
                Image(systemName: "text.alignright").tag("right")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .help("Heading alignment")
            if showLevel {
                Button {
                    mutate {
                        $0.level = $0.effectiveLevel % 4 + 1
                        $0.pointSize = nil   // level now governs the size
                    }
                } label: {
                    Text(style.levelLabel)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Heading level — click to cycle H1 → H2 → H3 → Body size")
            }
        }
    }

    private func toggle(_ symbol: String, _ active: Bool, _ help: String,
                        _ change: @escaping (inout ExportItem.HeadingStyle) -> Void) -> some View {
        Button { mutate(change) } label: {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(active ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

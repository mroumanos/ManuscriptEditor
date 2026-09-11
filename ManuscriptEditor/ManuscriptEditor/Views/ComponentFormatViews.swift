// ComponentFormatViews.swift
//
// **Export settings for one component of an outline**, in one form.
//
// These used to live on the component itself — a gear in each pane's header,
// editing the journal's outline from the other end.  That put a section's
// heading and typography in one place and the outline that prints it in
// another, and left a template with nowhere at all to edit them, since a
// template has no panes.  They live in the Export page now: click a row's
// formatting summary and this is what opens.
//
//   ComponentSettingsForm — typography (font/size/spacing) plus the
//     kind-specific options: the byline's delimiter, affiliation markers,
//     + corr / + cred; the reference list's citation style; the keyword
//     line's delimiter; and every component's printed heading (on/off, text,
//     style, level).
//
// Store-free on purpose: it edits an `ExportItem` through a binding, so the
// Export page uses it for a manuscript and a template uses it for its own
// outline, with no second implementation to keep in step.

import SwiftUI

// MARK: - ComponentSettingsForm

struct ComponentSettingsForm: View {

    /// The outline item being configured.
    @Binding var item: ExportItem
    /// The document's format — what a missing override inherits, and the seed
    /// for the first one.
    let inherited: ExportDocumentFormat
    /// The content whose names the heading placeholder shows (nil for a
    /// template, whose items name its own sections).
    var content: Manuscript? = nil

    /// Writes only when something changed.  Controls settle their bindings
    /// as they appear — a formatted field round-trips its value, a picker
    /// confirms its selection — and a write that changes nothing must not
    /// register as an edit: opening the gear was enough to mark the outline
    /// as differing from the template.
    private func mutateItem(_ change: @escaping (inout ExportItem) -> Void) {
        var edited = item
        change(&edited)
        guard edited != item else { return }
        item = edited
    }

    /// Typography writes create or extend the item's override, seeded from
    /// whatever is currently in effect — but a write that leaves the effective
    /// typography exactly as inherited creates no override.  An override equal
    /// to the document's format prints identically and still reads as a
    /// change.
    private func mutateFormat(_ change: @escaping (inout ExportDocumentFormat) -> Void) {
        var format = item.format ?? inherited
        change(&format)
        if item.format == nil, format == inherited { return }
        mutateItem { $0.format = format }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Every component's heading configures HERE (one place, one
            // look); each kind adds its own settings on top.
            switch item.kind {
            case .abstract, .section, .coverLetter:
                typographySection
                Divider()
                headingSection()
            case .authors:
                typographySection
                authorsSection()
            case .titlePage:
                typographySection
                titleHeadingSection()
            case .keywords:
                typographySection
                keywordsSection()
                headingSection()
            case .references:
                typographySection
                referencesSection()
                headingSection()
            default:
                typographySection
                headingSection()
            }
            Text("Applies to the EXPORT. The editor always shows your own font and spacing, from Settings → Editor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        // Wide enough for a byline row — checkbox, delimiter, index — on one
        // line; at 360 "delimiter" hyphenated itself across three lines.
        .frame(width: 440)
    }

    @ViewBuilder
    private var typographySection: some View {
        let format = item.format ?? inherited
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

    /// The byline, as the two things it is made of.
    ///
    /// **Names** and **institutions** are each optional — a journal puts the
    /// names on the title page and the affiliations at its foot, or on another
    /// page, or prints only one of them on a blind copy — and each has a
    /// delimiter of its own.  The *index* is what ties them together (a¹ on
    /// the name, ¹ on the institution), so it is one setting shown on both
    /// rows: change it on either and the other follows, because they cannot
    /// disagree.
    @ViewBuilder
    private func authorsSection() -> some View {
        Divider()
        Text("Byline")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        // ── Names ──
        HStack(spacing: 8) {
            Toggle("Names", isOn: Binding(
                get: { item.printsAuthorNames },
                set: { on in setParts(names: on, institutions: item.printsAffiliations) }
            ))
            .toggleStyle(.checkbox)
            .frame(width: 100, alignment: .leading)
            .disabled(item.printsAuthorNames && !item.printsAffiliations)
            .help("Print the authors' names")
            Text("delimiter").font(.caption).foregroundStyle(.secondary).fixedSize()
            Picker("", selection: Binding(
                get: { item.authorDelimiter ?? "semicolon" },
                set: { value in mutateItem { $0.authorDelimiter = value == "semicolon" ? nil : value } }
            )) {
                Text("a; b").tag("semicolon")
                Text("a, b").tag("comma")
                Text("a b").tag("space")
                Text("a / b").tag("slash")
                Text("a - b").tag("hyphen")
                Text("a ⏎ b").tag("newline")
                Text("1. a ⏎ 2. b").tag("numbered")
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .disabled(!item.printsAuthorNames)
            .help("How the names are separated — a numbered list puts one per line")
            Text("index").font(.caption).foregroundStyle(.secondary).fixedSize()
            indexPicker(namesRow: true)
                .disabled(!item.printsAuthorNames)
        }

        // ── Institutions ──
        HStack(spacing: 8) {
            Toggle("Institutions", isOn: Binding(
                get: { item.printsAffiliations },
                set: { on in setParts(names: item.printsAuthorNames, institutions: on) }
            ))
            .toggleStyle(.checkbox)
            .frame(width: 100, alignment: .leading)
            .disabled(item.printsAffiliations && !item.printsAuthorNames)
            .help("Print the affiliation list")
            Text("delimiter").font(.caption).foregroundStyle(.secondary).fixedSize()
            Picker("", selection: Binding(
                get: { item.affiliationDelimiterCode },
                set: { value in
                    mutateItem {
                        $0.affiliationDelimiter = value
                        $0.affiliationListStyle = nil     // superseded
                    }
                }
            )) {
                Text("a ⏎ b").tag("newline")
                Text("1. a ⏎ 2. b").tag("numbered")
                Text("a; b").tag("semicolon")
                Text("a, b").tag("comma")
                Text("a b").tag("space")
                Text("a / b").tag("slash")
                Text("a - b").tag("hyphen")
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .disabled(!item.printsAffiliations)
            .help("How the institutions are separated — a numbered list labels each 1., 2., …")
            Text("index").font(.caption).foregroundStyle(.secondary).fixedSize()
            indexPicker(namesRow: false)
                .disabled(!item.printsAffiliations)
        }

        HStack(spacing: 8) {
            Button {
                mutateItem { $0.correspondingShown.toggle() }
            } label: {
                Text("+ corr")
                    .font(.caption)
                    .foregroundStyle(item.correspondingShown
                        ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Annotate the corresponding author: a raised * on the name plus a \"* Corresponding author\" footnote line")
            Button {
                mutateItem { $0.authorTitlesShown.toggle() }
            } label: {
                Text("+ cred")
                    .font(.caption)
                    .foregroundStyle(item.authorTitlesShown
                        ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Append author credentials (MD, PhD…) to the names")
        }
    }

    /// Both halves off is not a byline; the last one stays on.
    private func setParts(names: Bool, institutions: Bool) {
        guard names || institutions else { return }
        mutateItem {
            $0.authorPartsMode = names && institutions ? "both" : names ? "names" : "institutions"
        }
    }

    /// One index for both rows — a¹ on the name is ¹ on the institution.  A
    /// numbered institution list labels itself, so that row says so instead.
    @ViewBuilder
    private func indexPicker(namesRow: Bool) -> some View {
        if !namesRow, item.affiliationListNumbered {
            Text("1., 2., …")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("A numbered list labels each institution by its number")
        } else {
            Picker("", selection: Binding(
                get: {
                    let v = item.affiliationMarker ?? "superscript"
                    return v == "doublecross" ? "cross" : v   // legacy value
                },
                set: { value in mutateItem { $0.affiliationMarker = value == "superscript" ? nil : value } }
            )) {
                if namesRow {
                    Text("a¹").tag("superscript")
                    Text("a†").tag("cross")
                    Text("none").tag("none")
                } else {
                    Text("¹ a").tag("superscript")
                    Text("† a").tag("cross")
                    Text("none").tag("none")
                }
            }
            .labelsHidden().controlSize(.small).fixedSize()
            .help("Names and institutions share one index — a¹ on the name matches ¹ on the institution. Crosses escalate †, ‡, ††† with each institution.")
        }
    }

    @ViewBuilder
    private func referencesSection() -> some View {
        Divider()
        Text("Citation style")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Picker("", selection: Binding(
            get: { item.citationStyle },
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
    private func keywordsSection() -> some View {
        Divider()
        Text("Keyword line")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Picker("", selection: Binding(
            get: { item.authorDelimiter ?? "comma" },
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
    private func headingSection() -> some View {
        Text("Heading")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Toggle("Print heading", isOn: Binding(
            get: { item.titleShown },
            set: { on in mutateItem { $0.titleShown = on } }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Include this component's heading in the export (content always exports)")
        if item.titleShown {
            HStack(spacing: 8) {
                TextField("", text: Binding(
                    get: { item.customTitle ?? "" },
                    set: { text in mutateItem { $0.customTitle = text.isEmpty ? nil : text } }
                ), prompt: Text(item.title(in: content)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .help("The heading printed for this component — empty uses its own name")
                HeadingStyleControls(style: item.effectiveHeadingStyle, showLevel: true) { change in
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
    private func titleHeadingSection() -> some View {
        Divider()
        Text("Title heading")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        HeadingStyleControls(style: item.effectiveHeadingStyle, showLevel: true) { change in
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

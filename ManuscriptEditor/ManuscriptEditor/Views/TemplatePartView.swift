// TemplatePartView.swift
//
// One part of a journal template, read-only, laid out the way its editor lays
// it out.
//
// A template is looked at from two places — Settings → Journals, and the
// "Linked to …" link in a journal's profile pane — and it used to look
// different in each: a tabbed summary in one, a row of counts in the other,
// neither resembling the sheet you actually edit that part in.  Same content,
// three shapes, and only one of them was the shape anyone had learned.
//
// So there is one view per part, and everywhere a template is shown, this is
// what is shown.  Read-only, because a template's rules are edited from a
// manuscript that has adopted it — there is no cut here to write them against.

import SwiftUI

struct TemplatePartView: View {
    let template: JournalTemplate
    let part: ProfilePart

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch part {
                case .requirements: summary
                case .structure:    content
                case .checks:       tests
                case .export:       export
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        if !template.requirements.url.isEmpty,
           let url = URL(string: template.requirements.url) {
            Link(destination: url) {
                Label("Author instructions", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
            .help(template.requirements.url)
        }
        if template.requirements.bullets.isEmpty {
            empty("No summary recorded for this journal.")
        } else {
            // Grouped by the standard categories, exactly as the Summary sheet
            // groups them.
            ForEach(Array(SourceRequirements.grouped(template.requirements.bullets).enumerated()),
                    id: \.offset) { _, group in
                Text((group.category ?? "other").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if template.structure.sections.isEmpty {
            empty("No content recorded for this journal.")
        } else {
            ForEach(Array(template.structure.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: section.kind == .questions
                              ? "list.bullet.rectangle" : "text.alignleft")
                            .font(.caption).foregroundStyle(.tertiary)
                        Text(section.title).fontWeight(.medium)
                        Text(section.required ? "required" : "optional")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                        if let format = section.format {
                            Text("\(String(format: "%g", format.fontSize)) pt · \(String(format: "%g", format.lineSpacing))×")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Format then Notes — the section's own guidance, read
                    // here rather than counted somewhere else.
                    if let value = section.formatNote, !value.isEmpty {
                        labelled("Format", value)
                    }
                    if let value = section.note, !value.isEmpty {
                        labelled("Notes", value)
                    }
                    if let sample = section.sample, !sample.isEmpty {
                        labelled("Content", sample)
                    }
                    ForEach(Array((section.questions ?? []).enumerated()), id: \.offset) { _, q in
                        labelled("Asks", q.wordLimit.map {
                            "\(q.prompt) — \($0) \((q.limitUnit ?? .words).label)"
                        } ?? q.prompt)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
            }
            if let core = template.structure.coreFormats, !core.isEmpty {
                Text("FIXED PARTS")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.top, 4)
                ForEach(core.keys.sorted(), id: \.self) { key in
                    if let format = core[key] {
                        labelled(key, "\(String(format: "%g", format.fontSize)) pt · "
                                 + "\(String(format: "%g", format.lineSpacing))× spacing"
                                 + (format.lineNumbers ? " · line numbers" : ""))
                    }
                }
            }
        }
    }

    // MARK: - Tests

    @ViewBuilder
    private var tests: some View {
        if template.checks.isEmpty {
            empty("No tests recorded for this journal.")
        } else {
            ForEach(template.checks) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: rule.isManual ? "hand.raised" : "checklist")
                        .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.displayName).font(.callout)
                        if let note = rule.note, !note.isEmpty {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if rule.isManual {
                        Text("manual").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var export: some View {
        if let export = template.export, !export.documents.isEmpty {
            ForEach(Array(export.documents.enumerated()), id: \.offset) { _, document in
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.name.isEmpty ? "Document" : document.name)
                        .fontWeight(.medium)
                    labelled("Format",
                             "\(String(format: "%g", document.format.fontSize)) pt · "
                             + "\(String(format: "%g", document.format.lineSpacing))× spacing · "
                             + "\(String(format: "%g", document.format.marginInches))\" margins"
                             + (document.format.lineNumbers ? " · line numbers" : "")
                             + (document.format.pageNumbers ? " · page numbers" : ""))
                    labelled("Includes", document.items
                        .filter { $0.kind != .pageBreak }
                        .map { $0.effectiveTitle(in: nil) }
                        .joined(separator: ", "))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            empty("No export outline recorded — manuscripts derive the standard one.")
        }
    }

    // MARK: - Pieces

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary)
    }
}

/// A template part in a sheet, with the one line that matters: you cannot edit
/// it here, and why.
struct TemplatePartSheet: View {
    let template: JournalTemplate
    let part: ProfilePart
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(template.displayName) — \(part.label)").font(.headline)
                Text("Read-only. A template's rules are edited from a manuscript that uses it, and saved back from there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TemplatePartView(template: template, part: part)
                .frame(height: 380)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

// JournalProfileReview.swift
//
// A read-only look at a journal profile: its requirements, its structure, and
// its checks.  Shown before a journal is added to a manuscript, so the choice
// is made with the rules in view rather than after the fact — and reusable
// anywhere else a profile needs explaining.
//
// Read-only on purpose.  Editing a profile belongs to a manuscript that has
// already adopted it (the Checks pane) or to the library; letting the add
// sheet edit would beg the question of which copy was being changed.

import SwiftUI

struct JournalProfileReview: View {

    let profile: JournalProfile

    private enum Tab: String, CaseIterable, Identifiable {
        case requirements, structure, checks
        var id: String { rawValue }
        var label: String {
            switch self {
            case .requirements: return "Requirements"
            case .structure:    return "Structure"
            case .checks:       return "Checks"
            }
        }
    }

    @State private var tab: Tab = .requirements

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text("\(tab.label) \(count(tab))").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .requirements: requirements
                    case .structure:    structure
                    case .checks:       checks
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }

    private func count(_ tab: Tab) -> String {
        switch tab {
        case .requirements: return profile.requirements.bullets.isEmpty ? "" : "(\(profile.requirements.bullets.count))"
        case .structure:    return profile.structure.isEmpty ? "" : "(\(profile.structure.sections.count))"
        case .checks:       return profile.checks.isEmpty ? "" : "(\(profile.checks.count))"
        }
    }

    // MARK: - Requirements

    @ViewBuilder
    private var requirements: some View {
        if !profile.requirements.url.isEmpty,
           let url = URL(string: profile.requirements.url) {
            Link(destination: url) {
                Label("Author instructions", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
            .help(profile.requirements.url)
        }
        if profile.requirements.bullets.isEmpty {
            empty("No requirements recorded for this journal.")
        } else {
            ForEach(Array(profile.requirements.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(bullet)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Structure

    @ViewBuilder
    private var structure: some View {
        if profile.structure.isEmpty {
            empty("No structure recorded for this journal.")
        } else {
            let core = profile.structure.coreSections
            let text = profile.structure.textSections
            if !core.isEmpty {
                groupLabel("Core")
                ForEach(core) { section in
                    structureRow(section, icon: section.core?.systemImage ?? "square")
                }
            }
            if !text.isEmpty {
                groupLabel("Sections").padding(.top, 6)
                ForEach(text) { section in
                    structureRow(section, icon: "text.alignleft")
                }
            }
        }
    }

    private func structureRow(_ section: StructureSection, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .font(.caption)
                .frame(width: 16)
            Text(section.title).font(.callout)
            if let note = section.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(section.required ? "Required" : "Optional")
                .font(.caption2)
                .foregroundStyle(section.required ? .secondary : .tertiary)
        }
    }

    // MARK: - Checks

    @ViewBuilder
    private var checks: some View {
        if profile.checks.isEmpty {
            empty("No checks configured for this journal.")
        } else {
            let automatic = profile.checks.filter { !$0.isManual }
            let manual = profile.checks.filter(\.isManual)
            if !automatic.isEmpty {
                groupLabel("Automatic")
                ForEach(automatic) { rule in checkRow(rule, icon: "checkmark.circle") }
            }
            if !manual.isEmpty {
                groupLabel("Manual").padding(.top, 6)
                ForEach(manual) { rule in checkRow(rule, icon: "hand.tap") }
            }
        }
    }

    private func checkRow(_ rule: CheckRule, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.displayName)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                // The name is usually a summary ("Abstract ≤ 250 words"); show
                // the conditions underneath when it isn't self-explanatory.
                if !rule.name.isEmpty, !rule.isManual, !rule.conditions.isEmpty {
                    Text(rule.conditions.map(\.summary)
                            .joined(separator: rule.combinator == .all ? " AND " : " OR "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    // MARK: - Bits

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
    }
}

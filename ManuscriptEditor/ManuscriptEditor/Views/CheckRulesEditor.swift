// CheckRulesEditor.swift
//
// The checks editor — deliberately behind a button in the Checks pane, so
// the people who never want to think about rules never see it, and the
// people refining a journal profile get the full vocabulary:
//
//   <rule name>   [all of | any of]
//     LENGTH (words) of Abstract  ≤  250
//     EXISTS Discussion
//
// Rules live on the journal (`Journal.checkRules`), seeded from the profile
// shipped with the app, and they are the WHOLE checklist — nothing shown in
// Checks is unreachable from here.  Every condition names a scope, which is
// what lets a failing rule color that pane in the sidebar.

import SwiftUI

struct CheckRulesEditor: View {
    @Environment(ManuscriptStore.self) private var store

    let journal: Journal
    @Binding var isPresented: Bool

    @State private var rules: [CheckRule] = []

    /// Body-section titles offered when a condition targets one section.
    private var sectionTitles: [String] {
        (store.manuscript?.sections ?? []).map(\.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Checks for \(journal.displayName)")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    store.updateCheckRules(rules, journalID: journal.id)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if rules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checklist")
                        .font(.system(size: 34, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No checks yet")
                        .font(.title3.weight(.semibold))
                    Text("Measure LENGTH, COUNT, EXISTS, or CONTAINS over one or\nmore sections — or add a manual check to tick by hand.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button { rules.append(.newRule()) } label: {
                            Label("Add Check", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { rules.append(.newManual()) } label: {
                            Label("Add Manual Check", systemImage: "hand.tap")
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($rules) { $rule in
                            ruleCard($rule)
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    rules.append(.newRule())
                } label: {
                    Label("Add Check", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    rules.append(.newManual())
                } label: {
                    Label("Add Manual Check", systemImage: "hand.tap")
                }
                .buttonStyle(.borderless)
                .help("A check the app can't measure — it renders as a checkbox to tick by hand")
                Spacer()
                Text("Saved with this manuscript, alongside its source requirements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .onAppear { rules = journal.checkRules ?? [] }
    }

    // MARK: rule card

    @ViewBuilder
    private func ruleCard(_ rule: Binding<CheckRule>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { rule.wrappedValue.isEnabled },
                    set: { rule.wrappedValue.enabled = $0 ? nil : false }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Include this rule in the checklist")

                TextField("Rule name (optional)", text: rule.name)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: rule.combinator) {
                    ForEach(CheckRule.Combinator.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Whether every condition must pass, or just one")

                Button(role: .destructive) {
                    rules.removeAll { $0.id == rule.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this rule")
            }

            if rule.wrappedValue.isManual {
                Label("Manual — ticked by hand in the checklist", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rule.conditions) { $condition in
                    conditionRow($condition, in: rule)
                }
            }

            HStack {
                if !rule.wrappedValue.isManual {
                    Button {
                        rule.wrappedValue.conditions.append(CheckCondition())
                    } label: {
                        Label("Add Condition", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                TextField("Guidance shown when it fails (optional)", text: Binding(
                    get: { rule.wrappedValue.note ?? "" },
                    set: { rule.wrappedValue.note = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(maxWidth: 320)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .opacity(rule.wrappedValue.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private func conditionRow(_ condition: Binding<CheckCondition>,
                              in rule: Binding<CheckRule>) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: condition.metric) {
                ForEach(CheckMetric.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .labelsHidden().fixedSize()

            Text("of").font(.caption).foregroundStyle(.secondary)

            scopeMenu(condition)

            if !subsectionChoices(for: condition.wrappedValue).isEmpty {
                subsectionMenu(condition)
            }

            if condition.wrappedValue.metric.takesNumber {
                Picker("", selection: condition.comparator) {
                    ForEach(CheckComparator.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden().fixedSize()
                TextField("", value: condition.number, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            } else if condition.wrappedValue.metric == .contains {
                TextField("text to find", text: condition.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            Spacer()
            Button {
                rule.wrappedValue.conditions.removeAll { $0.id == condition.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(rule.wrappedValue.conditions.count <= 1)
            .help("Remove this condition")
        }
        .controlSize(.small)
    }

    /// Everything measurable in ONE flat list: the fixed panes, then every
    /// body section by name.  Ticking more than one measures them together
    /// (LENGTH of Abstract + Introduction is their combined count).
    private func scopeMenu(_ condition: Binding<CheckCondition>) -> some View {
        Menu {
            ForEach(CheckScope.Kind.allCases.filter { $0 != .section }, id: \.self) { kind in
                Toggle(kind.label, isOn: scopeBinding(condition, CheckScope(kind: kind)))
            }
            if !sectionTitles.isEmpty {
                Divider()
                ForEach(sectionTitles, id: \.self) { title in
                    Toggle(title, isOn: scopeBinding(condition, CheckScope(kind: .section, name: title)))
                }
            }
        } label: {
            Text(condition.wrappedValue.scopes.isEmpty
                 ? "Choose…"
                 : condition.wrappedValue.scopes.map(\.label).joined(separator: " + "))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick one or more — several are measured together")
    }

    private func scopeBinding(_ condition: Binding<CheckCondition>,
                              _ scope: CheckScope) -> Binding<Bool> {
        Binding(
            get: { condition.wrappedValue.scopes.contains(scope) },
            set: { on in
                var scopes = condition.wrappedValue.scopes
                if on {
                    if !scopes.contains(scope) { scopes.append(scope) }
                } else {
                    scopes.removeAll { $0 == scope }
                }
                condition.wrappedValue.scopes = scopes
                let valid = Set(subsectionChoices(for: condition.wrappedValue))
                condition.wrappedValue.subsections.removeAll { !valid.contains($0) }
            }
        )
    }

    private func subsectionMenu(_ condition: Binding<CheckCondition>) -> some View {
        Menu {
            ForEach(subsectionChoices(for: condition.wrappedValue), id: \.self) { heading in
                Toggle(heading, isOn: Binding(
                    get: { condition.wrappedValue.subsections.contains(heading) },
                    set: { on in
                        var subs = condition.wrappedValue.subsections
                        if on {
                            if !subs.contains(heading) { subs.append(heading) }
                        } else {
                            subs.removeAll { $0 == heading }
                        }
                        condition.wrappedValue.subsections = subs
                    }
                ))
            }
        } label: {
            Text(condition.wrappedValue.subsections.isEmpty
                 ? "whole section"
                 : condition.wrappedValue.subsections.joined(separator: ", "))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Narrow to headings inside the selected scopes")
    }

    /// Headings inside the selected scopes — structured-abstract labels
    /// ("Objective:", "Methods:") and run-in headings.
    private func subsectionChoices(for condition: CheckCondition) -> [String] {
        guard let m = store.manuscript else { return [] }
        var out: [String] = []
        for scope in condition.scopes {
            let text: String
            switch scope.kind {
            case .abstract: text = m.abstract.plain
            case .section:
                let wanted = (scope.name ?? "").lowercased()
                text = m.sections.first { $0.title.lowercased() == wanted }?.content.plain ?? ""
            case .body: text = m.sections.map(\.content.plain).joined(separator: "\n")
            case .coverLetter: text = m.letterToEditor.body.plain
            default: continue
            }
            for heading in SubsectionParser.headings(in: text) where !out.contains(heading) {
                out.append(heading)
            }
        }
        return out
    }
}

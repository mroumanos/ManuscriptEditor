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

            // FONT_SIZE/LINE_SPACING/LINE_NUMBERS read the export config and
            // STRUCTURE reads the structure file, so neither takes a scope.
            let scoped = !condition.wrappedValue.metric.isFormat
                && !condition.wrappedValue.metric.isStructure
            if scoped {
                Text("of").font(.caption).foregroundStyle(.secondary)
                scopeMenu(condition)
                // Several components measure as a SUM — say so, since that is
                // how a journal's "body" is usually defined.
                if condition.wrappedValue.scopes.count > 1,
                   condition.wrappedValue.metric.takesNumber {
                    Text("summed").font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text(condition.wrappedValue.metric.isStructure
                     ? "— the journal's structure file"
                     : "— the export configuration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                scopeItem(condition, CheckScope(kind: kind), title: kind.label)
            }
            if !sectionTitles.isEmpty {
                Divider()
                ForEach(sectionTitles, id: \.self) { title in
                    scopeItem(condition, CheckScope(kind: .section, name: title), title: title)
                }
            }
        } label: {
            Text(condition.wrappedValue.scopes.isEmpty
                 ? "Choose…"
                 : condition.wrappedValue.scopeLabel)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick one or more — several are summed")
    }

    /// One pickable scope, with a tick when it is in the set — a menu of
    /// plain rows gives no way to see what you already chose.
    @ViewBuilder
    private func scopeItem(_ condition: Binding<CheckCondition>,
                           _ scope: CheckScope, title: String) -> some View {
        let selected = condition.wrappedValue.scopes.contains(scope)
        Button {
            scopeBinding(condition, scope).wrappedValue.toggle()
        } label: {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
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
            }
        )
    }
}

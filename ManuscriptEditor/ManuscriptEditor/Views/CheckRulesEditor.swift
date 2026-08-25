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
// Rules live on the journal (`Journal.checkRules`) and evaluate alongside
// the requirement-derived checks.  Every condition names a scope, which is
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
                    Text("No custom checks yet")
                        .font(.title3.weight(.semibold))
                    Text("The journal's built-in requirement checks still run.\nAdd a rule here to check anything else.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button { rules.append(.newRule()) } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
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
            HStack {
                Button {
                    rules.append(.newRule())
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Rules run alongside the journal's built-in checks.")
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

            ForEach(rule.conditions) { $condition in
                conditionRow($condition, in: rule)
            }

            HStack {
                Button {
                    rule.wrappedValue.conditions.append(CheckCondition())
                } label: {
                    Label("Add Condition", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
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

            Picker("", selection: condition.scope.kind) {
                ForEach(CheckScope.Kind.allCases, id: \.self) { k in
                    Text(k.label).tag(k)
                }
            }
            .labelsHidden().fixedSize()

            if condition.wrappedValue.scope.kind == .section {
                Picker("", selection: Binding(
                    get: { condition.wrappedValue.scope.name ?? sectionTitles.first ?? "" },
                    set: { condition.wrappedValue.scope.name = $0 }
                )) {
                    ForEach(sectionTitles, id: \.self) { title in
                        Text(title).tag(title)
                    }
                }
                .labelsHidden().fixedSize()
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
}

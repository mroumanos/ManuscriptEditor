// CheckRulesEditor.swift
//
// Editing a test — the full vocabulary:
//
//   <rule name>   [all of | any of]
//     LENGTH (words) of Abstract  ≤  250
//     EXISTS Discussion
//
// One card per test (`CheckRuleCard`), because the same rules are written
// in two places: a manuscript's Tests page edits each test in place behind
// its pencil, and a template's Tests pane lists them all (`CheckRulesList`).
// One card, two owners — the alternative was two editors drifting apart,
// with the template's half quietly missing whatever was added to the
// manuscript's.
//
// Every condition names a scope, which is what lets a failing rule color that
// pane in the sidebar.

import SwiftUI

// MARK: - CheckRulesList

/// The rules themselves: the empty state, one card per rule, and the bar that
/// adds one.  Owns nothing — the binding's owner decides when a change is
/// written and to what.
struct CheckRulesList: View {

    @Binding var rules: [CheckRule]
    /// Section titles a condition can be scoped to.  A template has no
    /// manuscript behind it, so it passes the titles its own structure names.
    var sectionTitles: [String] = []
    /// The line under the add bar — where these rules end up.
    var footnote: String?

    var body: some View {
        VStack(spacing: 0) {
            if rules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checklist")
                        .font(.system(size: 34, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No tests yet")
                        .font(.title3.weight(.semibold))
                    Text("Measure LENGTH, COUNT, EXISTS, or CONTAINS over one or\nmore sections — or add a manual check to tick by hand.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button { rules.append(.newRule()) } label: {
                            Label("Add Test", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { rules.append(.newManual()) } label: {
                            Label("Add Manual Test", systemImage: "hand.tap")
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($rules) { $rule in
                            CheckRuleCard(rule: $rule, sectionTitles: sectionTitles,
                                          onDelete: { rules.removeAll { $0.id == rule.id } })
                                .padding(12)
                                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
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
                    Label("Add Test", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    rules.append(.newManual())
                } label: {
                    Label("Add Manual Test", systemImage: "hand.tap")
                }
                .buttonStyle(.borderless)
                .help("A check the app can't measure — it renders as a checkbox to tick by hand")
                Spacer()
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

}

// MARK: - CheckRuleCard

/// One test, editable: its name, how its conditions combine, each
/// condition, and the guidance shown when it fails.  No frame of its own —
/// the owner draws the box (a template's list, a manuscript's test box).
struct CheckRuleCard: View {

    @Binding var rule: CheckRule
    /// Section titles a condition can be scoped to.
    var sectionTitles: [String] = []
    /// Offered as "Delete Test" when set.
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { rule.enabled = $0 ? nil : false }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Include this test in the checklist")

                TextField("Test name (optional)", text: $rule.name)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $rule.combinator) {
                    ForEach(CheckRule.Combinator.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Whether every condition must pass, or just one")
            }

            if rule.isManual {
                Label("Manual — ticked by hand in the checklist", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($rule.conditions) { $condition in
                    conditionRow($condition)
                }
            }

            HStack {
                if !rule.isManual {
                    Button {
                        rule.conditions.append(CheckCondition())
                    } label: {
                        Label("Add Condition", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                if let onDelete {
                    Button("Delete Test", role: .destructive, action: onDelete)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Remove this test")
                }
                Spacer()
                TextField("Guidance shown when it fails (optional)", text: Binding(
                    get: { rule.note ?? "" },
                    set: { rule.note = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(maxWidth: 320)
            }
        }
        .opacity(rule.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private func conditionRow(_ condition: Binding<CheckCondition>) -> some View {
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
                rule.conditions.removeAll { $0.id == condition.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(rule.conditions.count <= 1)
            .help("Remove this condition")
        }
        .controlSize(.small)
    }

    /// Everything measurable in ONE flat list: the fixed panes, then every
    /// body section by name.  Ticking more than one measures them together
    /// (LENGTH of Abstract + Introduction is their combined count).
    private func scopeMenu(_ condition: Binding<CheckCondition>) -> some View {
        Menu {
            ForEach(CheckScope.ScopeType.allCases.filter { $0 != .section }, id: \.self) { kind in
                scopeItem(condition, CheckScope(type: kind), title: kind.label)
            }
            if !sectionTitles.isEmpty {
                Divider()
                ForEach(sectionTitles, id: \.self) { title in
                    scopeItem(condition, CheckScope(type: .section, name: title), title: title)
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

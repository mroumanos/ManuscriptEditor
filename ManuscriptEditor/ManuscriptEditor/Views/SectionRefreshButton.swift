// SectionRefreshButton.swift
//
// The pane's smart refresh: one section, rewritten to its journal's
// template, tests and requirements from what it already holds.
//
// A circular arrow in the assist treatment (the violet), because it is
// the fast-forward's request scoped to one section — and it shows only
// while Assist is on, in a journal's tab, on an active section.  Pressing
// it runs nothing: it drops down the instruction the model will get — the
// default in grey, replaced by whatever you type, and used as it stands
// when you type nothing — one line saying what Run replaces, and Run.
//
// See MasterContext/features/ai-assist.md §7.3.

import SwiftUI

struct SectionRefreshButton: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self) private var appStore

    let item: SidebarItem
    let ref: VersionRef

    @State private var showing = false
    /// What was typed over the default; empty means the default runs.
    @State private var instruction = ""

    /// The journal and section this refresh is for — an active section in
    /// a journal's tab, with Assist on.  Elsewhere there is no button.
    private var target: (journal: Journal, section: ManuscriptSection)? {
        guard store.isAssistEnabled, store.canAssist(appStore: appStore),
              let journal = store.paneJournal(for: ref),
              let content = store.manuscript(for: ref) else { return nil }
        let section: ManuscriptSection?
        switch item {
        case .section(let id): section = content.sections.first { $0.id == id }
        case .abstract:        section = content.abstractSection
        default:               section = nil
        }
        guard let section, section.active, section.isJournalContent else { return nil }
        return (journal, section)
    }

    var body: some View {
        if let target {
            let busy = store.isAssisting(target.section.id)
            let fallback = FastForwardIntent.refreshInstruction(section: target.section, journal: target.journal)
            if let run = store.assistRun(target.section.id) {
                AssistRunIndicator(run: run, timeout: AIRequestService.longRunTimeout)
            }
            Button {
                showing = true
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    // Turns while the request is out — from Run until the
                    // reply lands — and sits still otherwise.
                    .symbolEffect(.rotate, options: .repeating, isActive: busy)
                    .frame(width: 26, height: 22)
                    .assistAffordance(active: true, busy: busy)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Smart refresh — rewrite this section for \(target.journal.name) from its template, tests and requirements")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SMART REFRESH — \(target.section.title.uppercased()) AT \(target.journal.name.uppercased())")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    // The default reads in grey until something is typed over
                    // it — computed, not state, so it is there the first time.
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $instruction)
                            .font(.body)
                        if instruction.isEmpty {
                            Text(fallback)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    Text("Run replaces this section's text. ⌘Z restores it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Run") {
                            showing = false
                            let typed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                            let text = typed.isEmpty ? fallback : instruction
                            Task {
                                await store.assistRefreshSection(target.section.id, ref: ref,
                                                                 instruction: text, appStore: appStore)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
                .frame(width: 440)
            }
        }
    }
}

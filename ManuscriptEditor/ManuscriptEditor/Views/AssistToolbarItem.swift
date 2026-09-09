// AssistToolbarItem.swift
//
// The title-bar pair: the **✦ Assist** toggle, and the prompt-log button
// beside it.
//
// They sit together on purpose.  The toggle is the only switch that makes this
// app talk to a model, and the log is the record of everything it has said —
// putting the record one click from the switch means "what has this thing sent
// on my behalf" is never more than a glance away.
//
// See MasterContext/11-ai-integration.md §5–6.

import SwiftUI

struct AssistToolbarItem: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @State private var showingLog = false

    private var canAssist: Bool { store.canAssist(appStore: appStore) }
    private var isOn: Bool { store.isAssistEnabled && canAssist }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.setAssistEnabled(!store.isAssistEnabled)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: AssistStyle.symbol)
                    Text("Assist")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .assistAffordance(active: isOn, busy: store.isAssistBusy)
            }
            .buttonStyle(.plain)
            .disabled(!canAssist)
            .help(canAssist
                  ? (store.isAssistEnabled
                     ? "Assist is on — AI-capable controls are live"
                     : "Turn on AI assistance for this manuscript")
                  : "Pick a model in Overview → Settings → AI first")

            Button {
                showingLog = true
            } label: {
                Image(systemName: store.promptLog.isEmpty
                      ? "bubble.left" : "bubble.left.fill")
            }
            .buttonStyle(.plain)
            .help(store.promptLog.isEmpty
                  ? "Prompt log — nothing sent from this manuscript yet"
                  : "Prompt log — \(store.promptLog.count) request\(store.promptLog.count == 1 ? "" : "s")")
            .popover(isPresented: $showingLog, arrowEdge: .bottom) {
                PromptLogView()
            }
        }
    }
}

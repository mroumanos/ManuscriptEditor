// AssistToggle.swift
//
// The ✦ switch: the only control that lets this app talk to a model.
//
// It sits in the journal tab bar, immediately left of Active/Compare, because
// those three are the same kind of thing — how the workspace is behaving right
// now — and unlike a title-bar button it stays visible in every pane.
//
// Off it is a grey glyph; on it is the assist violet.  No label: the icon is
// the vocabulary, and it is repeated on every control the toggle brings to
// life (see `Theme/AssistStyle.swift`).
//
// See MasterContext/11-ai-integration.md §5.

import SwiftUI

struct AssistToggle: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore
    @Environment(\.colorScheme)        private var scheme

    private var canAssist: Bool { store.canAssist(appStore: appStore) }
    private var isOn: Bool { store.isAssistEnabled && canAssist }

    var body: some View {
        Button {
            store.setAssistEnabled(!store.isAssistEnabled)
        } label: {
            Image(systemName: AssistStyle.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(AssistStyle.gradient(scheme))
                                      : AnyShapeStyle(Color.secondary))
                .frame(width: 26, height: 22)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AssistStyle.start(scheme).opacity(AssistStyle.fillOpacity))
                    }
                }
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(AssistStyle.gradient(scheme)
                                            .opacity(AssistStyle.strokeOpacity), lineWidth: 1)
                    }
                }
                .opacity(canAssist ? 1 : 0.35)
                // While a request is out, the glyph pulses — the only motion
                // in the assist vocabulary, and it means "still working".
                .symbolEffect(.pulse, isActive: store.isAssistBusy)
        }
        .buttonStyle(.plain)
        .disabled(!canAssist)
        .help(canAssist
              ? (store.isAssistEnabled
                 ? "Assist is on — AI-capable controls are live. Every request is recorded in Log → AI Requests."
                 : "Turn on AI assistance for this manuscript")
              : "Pick a model in Overview → Settings → AI first")
    }
}

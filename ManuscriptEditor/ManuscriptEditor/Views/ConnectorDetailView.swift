// ConnectorDetailView.swift
//
// Settings → Accounts, right-hand pane for a **connector**: a local service the
// app drives rather than an account it holds a credential for.
//
// The row deliberately has no username and no password field.  What it does
// have is the one thing that actually goes wrong — the executable's path —
// plus a model, and a Test button that resolves the path, makes one real call,
// and reports which model answered.

import SwiftUI
import UniformTypeIdentifiers

struct ConnectorDetailView: View {
    @Environment(AppStore.self) private var appStore

    let connector: AIConnector
    /// Test results for this window's lifetime — see `AccountsView`.
    @Binding var testedThisSession: [UUID: Bool]
    let onRemove: () -> Void

    @State private var pathDraft = ""
    @State private var endpointDraft = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded: Bool?


    var body: some View {
        Form {
            Section {
                LabeledContent("Service") {
                    HStack(spacing: 6) {
                        Image(systemName: connector.kind.systemImage)
                            .foregroundStyle(.secondary)
                        Text(connector.kind.displayName)
                    }
                }
                LabeledContent("Account", value: "Local")
                Text(connector.kind.howToStart)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(connector.kind.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(NSColor.textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connector.kind.installCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            } header: {
                Text("Connection")
            }

            if connector.kind.executableName != nil {
                Section {
                    pathRow(text: $pathDraft,
                            prompt: "Found automatically when you press Test",
                            onCommit: savePath,
                            change: ("Browse…", browseForExecutable))
                    Text("Apps launched from Finder don't inherit your shell's PATH, so the app looks in the usual places and then asks a login shell. Set it here if it still can't find the tool.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Executable")
                }
            }

            if connector.kind == .ollama {
                Section {
                    pathRow(text: $endpointDraft,
                            prompt: "http://localhost:11434",
                            onCommit: saveEndpoint,
                            change: nil)
                    Text("Where Ollama is listening. The default is right for a copy running on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Server")
                }
                Section {
                    if connector.availableModels.isEmpty {
                        Text("Press Test to read what this server has pulled.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // Read off the server, so it lists what is actually
                        // installed — `ollama pull` something new and press
                        // Test again.
                        Picker("Model", selection: Binding(
                            get: { connector.selectedModel },
                            set: { value in
                                var edited = connector
                                edited.selectedModel = value
                                appStore.updateConnector(edited)
                            })) {
                            ForEach(connector.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Test proves this model answers; the manuscript picks its own in Overview → Settings → AI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Models")
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test")
                        }
                    }
                    .disabled(testing || !connector.kind.isImplemented)

                    if !connector.kind.isImplemented {
                        Text("Not wired up yet — Claude Code first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("Which model to use is chosen per manuscript, in Overview → Settings → AI. Test here just proves the tool is installed and signed in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = statusMessage {
                    Label {
                        Text(message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: (testSucceeded ?? connector.lastTestSucceeded) == true
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle((testSucceeded ?? connector.lastTestSucceeded) == true
                                             ? Color.green : Color.orange)
                    }
                }
            } header: {
                Text("Status")
            }

            RemoveAccountSection(
                label: "Remove Connector",
                confirmTitle: "Remove the \(connector.kind.displayName) connection?",
                confirmMessage: "Manuscripts using it fall back to no AI until you pick another.",
                note: "Removes this connection from the app. The tool itself and your sign-in are untouched.",
                onRemove: onRemove)
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: load)
        .onChange(of: connector.id) { _, _ in load() }
    }

    private var statusMessage: String? {
        if let testMessage { return testMessage }
        guard let stored = connector.lastTestMessage else { return nil }
        guard let when = connector.lastTestedAt else { return stored }
        return "\(stored) — \(when.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Actions

    private func load() {
        pathDraft = connector.executablePath
        endpointDraft = connector.endpoint
        testMessage = nil
        testSucceeded = nil
    }

    private func savePath() {
        var edited = connector
        edited.executablePath = pathDraft.trimmingCharacters(in: .whitespaces)
        appStore.updateConnector(edited)
    }

    private func browseForExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(connector.kind.executableName ?? "") executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathDraft = url.path
        savePath()
    }

    /// A path or URL, laid out the way the install command above it is: the
    /// value on the LEFT, filling the row, and what you can do to it — copy,
    /// change — on the right.
    ///
    /// A grouped Form treats a row holding a text field as label + value and
    /// puts the field in the trailing column, right-aligned, however the row
    /// around it is framed — the field's own label is what it keys on.
    /// Hiding that label takes the row out of the two-column treatment so it
    /// spans the width like the caption rows do.
    private func pathRow(text: Binding<String>, prompt: String,
                         onCommit: @escaping () -> Void,
                         change: (label: String, action: () -> Void)?) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)
                .onSubmit(onCommit)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.wrappedValue, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(text.wrappedValue.isEmpty)
            .help("Copy")
            if let change {
                Button(change.label) { change.action() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveEndpoint() {
        var edited = connector
        edited.endpoint = endpointDraft.trimmingCharacters(in: .whitespaces)
        appStore.updateConnector(edited)
    }

    /// One real round-trip: resolve the binary, ask for a single word back, and
    /// report what happened — including which model answered.
    ///
    /// For Ollama the first step is different: read the model list off the
    /// server, so the picker shows what is actually pulled, and pick the
    /// first one if nothing is chosen yet.
    private func runTest() async {
        testing = true
        testMessage = nil
        defer { testing = false }

        var edited = connector
        if edited.kind == .ollama {
            if !endpointDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                edited.endpoint = endpointDraft.trimmingCharacters(in: .whitespaces)
            }
            let installed = await AIModelCatalog.installedOllamaModels(endpoint: edited.endpoint)
            edited.availableModels = installed.map(\.id)
            if !installed.contains(where: { $0.id == edited.selectedModel }) {
                edited.selectedModel = installed.first?.id ?? ""
            }
            appStore.updateConnector(edited)
            if installed.isEmpty {
                let message = "Ollama answered at \(edited.endpoint), but has no models pulled — run `ollama pull <model>` first."
                edited.lastTestSucceeded = false
                edited.lastTestMessage = message
                edited.lastTestedAt = Date()
                appStore.updateConnector(edited)
                testMessage = message
                testSucceeded = false
                testedThisSession[connector.id] = false
                return
            }
        }
        if edited.selectedModel.isEmpty {
            edited.selectedModel = AIModelCatalog.defaultModel(for: edited.kind)
        }

        do {
            let result = try await AIConnectorRunner.run(
                prompt: "Reply with exactly one word: ok",
                connector: edited,
                timeout: 120,
                onResolvePath: { resolved in
                    edited.executablePath = resolved
                })
            let model = result.reportedModel ?? edited.selectedModel
            let message = result.modelWasSubstituted
                ? "Connected, but \(model) answered — not the \(edited.selectedModel) you selected."
                : "Connected — \(model) answered in \(String(format: "%.1f", result.duration))s"
            edited.lastTestSucceeded = !result.modelWasSubstituted
            edited.lastTestMessage = message
            edited.lastTestedAt = Date()
            appStore.updateConnector(edited)
            pathDraft = edited.executablePath
            testMessage = message
            testSucceeded = !result.modelWasSubstituted
            testedThisSession[connector.id] = !result.modelWasSubstituted
        } catch {
            let message = error.localizedDescription
            edited.lastTestSucceeded = false
            edited.lastTestMessage = message
            edited.lastTestedAt = Date()
            appStore.updateConnector(edited)
            pathDraft = edited.executablePath
            testMessage = message
            testSucceeded = false
            testedThisSession[connector.id] = false
        }
    }
}

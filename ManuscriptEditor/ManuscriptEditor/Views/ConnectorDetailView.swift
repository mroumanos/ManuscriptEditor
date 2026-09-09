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

    @State private var pathDraft = ""
    @State private var modelDraft = ""
    @State private var customModel = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded: Bool?

    private var catalog: [AIModelCatalog.Entry] { AIModelCatalog.models(for: connector.kind) }

    /// A model the user typed that isn't in the curated list — kept selectable
    /// so a newer CLI isn't blocked by a stale app release.
    private var usingCustomModel: Bool {
        !modelDraft.isEmpty && !catalog.contains { $0.id == modelDraft }
    }

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
                    // An empty TextField title on purpose: a titled field in a
                    // grouped Form renders its title as the row's label, which
                    // turned the placeholder into a caption and squeezed the
                    // path into a sliver.
                    HStack(spacing: 8) {
                        TextField("", text: $pathDraft,
                                  prompt: Text("Found automatically when you press Test"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(savePath)
                        Button("Browse…") { browseForExecutable() }
                    }
                    Text("Apps launched from Finder don't inherit your shell's PATH, so the app looks in the usual places and then asks a login shell. Set it here if it still can't find the tool.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Executable")
                }
            }

            Section {
                if catalog.isEmpty {
                    TextField("Model id", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { modelDraft = customModel; saveModel() }
                } else {
                    Picker("Model", selection: $modelDraft) {
                        ForEach(catalog) { entry in
                            Text(entry.label).tag(entry.id)
                        }
                        if usingCustomModel {
                            Text(modelDraft).tag(modelDraft)
                        }
                        Divider()
                        Text("Other…").tag("__custom__")
                    }
                    .onChange(of: modelDraft) { _, new in
                        if new == "__custom__" {
                            customModel = ""
                        } else {
                            saveModel()
                        }
                    }
                    if modelDraft == "__custom__" {
                        HStack {
                            TextField("Model id (e.g. claude-sonnet-5)", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                            Button("Use") {
                                let trimmed = customModel.trimmingCharacters(in: .whitespaces)
                                guard !trimmed.isEmpty else { return }
                                modelDraft = trimmed
                                saveModel()
                            }
                        }
                    }
                }
                Text("The list is what this app knows about; it can go stale between releases. Test reports which model actually answered — a model your plan doesn't include will fail here rather than silently later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Model")
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
        modelDraft = connector.selectedModel
        customModel = ""
        testMessage = nil
        testSucceeded = nil
    }

    private func savePath() {
        var edited = connector
        edited.executablePath = pathDraft.trimmingCharacters(in: .whitespaces)
        appStore.updateConnector(edited)
    }

    private func saveModel() {
        var edited = connector
        edited.selectedModel = modelDraft
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

    /// One real round-trip: resolve the binary, ask for a single word back, and
    /// report what happened — including which model answered.
    private func runTest() async {
        testing = true
        testMessage = nil
        defer { testing = false }

        var edited = connector
        edited.selectedModel = modelDraft == "__custom__" ? customModel : modelDraft

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
        } catch {
            let message = error.localizedDescription
            edited.lastTestSucceeded = false
            edited.lastTestMessage = message
            edited.lastTestedAt = Date()
            appStore.updateConnector(edited)
            pathDraft = edited.executablePath
            testMessage = message
            testSucceeded = false
        }
    }
}

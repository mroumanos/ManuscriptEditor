// AIServicesView.swift
//
// Global panel for managing AI service accounts (Claude, ChatGPT, etc.).
//
// WHAT THIS PANEL DOES
// ─────────────────────────────────────────────────────────────────────────────
// Users can add multiple AI service accounts.  These are global and reusable.
// Each manuscript selects its active AI service in Manuscript → Settings.
//
// AI services are optional for source manuscript editing — they are only
// required when creating journal cuts (Phase 2 LLM adaptation).
//
// API KEY SECURITY NOTE
// ─────────────────────────────────────────────────────────────────────────────
// Phase 2 will store API keys in macOS Keychain.  For now, the "Enter API Key"
// field is shown but disabled.  The `hasKey` flag on the model acts as a
// placeholder indicator.

import SwiftUI

// MARK: - AIServicesView

/// List of AI service accounts on the left; detail form on the right.
struct AIServicesView: View {
    @Environment(AppStore.self) private var appStore

    @State private var selectedID: UUID?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            serviceList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
        }
        .sheet(isPresented: $showAddSheet) {
            AddAIServiceSheet(isPresented: $showAddSheet) { account in
                appStore.addAIService(account)
                selectedID = account.id
            }
        }
    }

    // MARK: - Left: service list

    private var serviceList: some View {
        VStack(spacing: 0) {
            if appStore.aiServices.isEmpty {
                emptyState
            } else {
                List(selection: $selectedID) {
                    ForEach(appStore.aiServices) { service in
                        serviceRow(service).tag(service.id)
                    }
                    .onDelete { appStore.deleteAIServices(at: $0) }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add AI Service", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(10)
                Spacer()
                Text("\(appStore.aiServices.count) service\(appStore.aiServices.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No AI services configured")
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Text("AI is optional for editing the source.\nIt's required to create journal cuts in Phase 2.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func serviceRow(_ service: AIServiceAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service.provider.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName).fontWeight(.medium).lineLimit(1)
                Text(service.provider.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if service.hasKey {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Right: detail form

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID,
           let service = appStore.aiServices.first(where: { $0.id == id }) {
            AIServiceDetailForm(service: service)
        } else {
            ContentUnavailableView(
                "No AI Service Selected",
                systemImage: "sparkles",
                description: Text("Add an AI service or select one to configure it.")
            )
        }
    }
}

// MARK: - AIServiceDetailForm

/// Edit form for one AI service account.
struct AIServiceDetailForm: View {
    @Environment(AppStore.self) private var appStore
    let service: AIServiceAccount
    @State private var draft: AIServiceAccount

    init(service: AIServiceAccount) {
        self.service = service
        _draft = State(initialValue: service)
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    TextField("Display name", text: $draft.displayName)
                    LabeledContent("Provider") {
                        Text(draft.provider.rawValue).foregroundStyle(.secondary)
                    }
                }

                Section("Authentication") {
                    if draft.provider.requiresAPIKey {
                        LabeledContent("API Key") {
                            HStack {
                                Text(draft.hasKey ? "Configured (stored in Keychain)" : "Not configured")
                                    .foregroundStyle(draft.hasKey ? .green : .secondary)
                                    .font(.callout)
                                Spacer()
                                Button("Set Key (Phase 2)") {}
                                    .buttonStyle(.bordered)
                                    .disabled(true)
                            }
                        }
                    } else {
                        TextField("Local endpoint URL", text: $draft.customEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section {
                    Text(draft.provider.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft.displayName)    { _, _ in appStore.updateAIService(draft) }
        .onChange(of: draft.customEndpoint) { _, _ in appStore.updateAIService(draft) }
        .onChange(of: service.id)           { _, _ in draft = service }
    }
}

// MARK: - AddAIServiceSheet

/// Sheet for adding a new AI service account.
struct AddAIServiceSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (AIServiceAccount) -> Void

    @State private var provider: AIProvider = .claude
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add AI Service").font(.headline)

            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases, id: \.self) { p in
                    Label(p.rawValue, systemImage: p.systemImage).tag(p)
                }
            }
            .labelsHidden()
            .onChange(of: provider) { _, new in
                if displayName.isEmpty { displayName = new.rawValue }
            }

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)

            Text(provider.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var account = AIServiceAccount.empty(provider: provider)
                    account.displayName = displayName.isEmpty ? provider.rawValue : displayName
                    onAdd(account)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { displayName = provider.rawValue }
    }
}

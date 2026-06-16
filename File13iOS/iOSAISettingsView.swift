import File13Core
import SwiftUI

struct iOSAISettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var apiKey: String = ""
    @State private var loadedKeyForProvider: AIProviderKind?
    @State private var availability: ProviderAvailability = .ready
    @State private var availabilityIsCurrent: Bool = false
    @State private var isCheckingAvailability: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .onChange(of: settings.aiProvider) { _, newValue in
                    syncKeyField(for: newValue)
                    settings.aiModel = newValue.availableModels.first?.id ?? ""
                    availabilityIsCurrent = false
                    Task { await refreshAvailability() }
                }

                if settings.aiProvider.requiresAPIKey {
                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField(apiKey.isEmpty ? "Required" : "", text: $apiKey)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .onChange(of: apiKey) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                let provider = settings.aiProvider
                                if trimmed.isEmpty {
                                    try? KeychainStore.deleteAIKey(for: provider)
                                } else {
                                    try? KeychainStore.saveAIKey(trimmed, for: provider)
                                }
                                availabilityIsCurrent = false
                                Task { await refreshAvailability() }
                            }
                    }

                    if !settings.aiProvider.availableModels.isEmpty {
                        Picker("Model", selection: $settings.aiModel) {
                            ForEach(settings.aiProvider.availableModels) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        if let summary = currentModelSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Text("Status")
                    Spacer()
                    AvailabilityStatusView(
                        availability: availability,
                        isChecking: isCheckingAvailability,
                        isCurrent: availabilityIsCurrent
                    )
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(settings.aiProvider.privacyNote)
            }

            Section {
                Toggle(isOn: $settings.autoCategorizeNewSenders) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-categorize new senders after refresh")
                        Text("Runs the categorizer in the background after each refresh so newly-seen senders pick up a category automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Automation")
            }

            Section {
                Label {
                    Text("Per-feature tuning (custom instructions, temperature, and max-token limits for each AI feature) is available in **File13 for Mac**. Settings may sync across your devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "macbook")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Advanced")
            }

            Section {
                Text("File13 uses AI for inbox triage on headers only (e.g., sender, subject, date). Body content is never read or sent. Choose Apple's on-device model for the strongest privacy; choose a third-party provider for more flexibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How File13 uses AI")
            }


        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            syncKeyField(for: settings.aiProvider)
            ensureValidModel()
            await refreshAvailability()
        }
    }

    private var currentModelSummary: String? {
        settings.aiProvider.availableModels.first { $0.id == settings.aiModel }?.summary
    }

    private func ensureValidModel() {
        let options = settings.aiProvider.availableModels
        guard !options.isEmpty else { return }
        if !options.contains(where: { $0.id == settings.aiModel }) {
            // `guard !options.isEmpty` above makes `.first!` safe — the
            // collection has at least one element when we reach here.
            settings.aiModel = options.first!.id
        }
    }

    private func syncKeyField(for provider: AIProviderKind) {
        guard provider.requiresAPIKey else {
            apiKey = ""
            loadedKeyForProvider = provider
            return
        }
        if loadedKeyForProvider != provider {
            apiKey = (try? KeychainStore.loadAIKey(for: provider)) ?? ""
            loadedKeyForProvider = provider
        }
    }

    private func refreshAvailability() async {
        isCheckingAvailability = true
        defer { isCheckingAvailability = false }
        let provider = LLMProviderFactory.make(kind: settings.aiProvider, settings: settings)
        availability = await provider.availability()
        availabilityIsCurrent = true
    }
}

private struct AvailabilityStatusView: View {
    let availability: ProviderAvailability
    let isChecking: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if isChecking {
            ProgressView().controlSize(.small)
        } else {
            switch availability {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsSetup:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            case .unsupported:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var message: String {
        if !isCurrent { return "Checking…" }
        let raw: String
        switch availability {
        case .ready:                       raw = "Ready"
        case .needsSetup(let m):           raw = m
        case .unsupported(let m):          raw = m
        case .error(let m):                raw = m
        }
        return raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    }
}

import File13Core
import SwiftUI

struct AIIntegrationSettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var apiKey: String = ""
    @State private var loadedKeyForProvider: AIProviderKind?
    @State private var availability: ProviderAvailability = .ready
    @State private var availabilityIsCurrent: Bool = false
    @State private var isCheckingAvailability: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Pending-changes banner shows when iCloud sync delivered an
            // AI-sensitive change (provider, model, custom instructions)
            // that hasn't been approved on this Mac. Lives outside the
            // Form because wrapping an empty banner in a Form Section
            // still renders the Section's grouping rect — a big grey box
            // with no contents — even when the banner self-collapses to
            // zero height. Hoisting it lets the empty state truly take
            // no visible space.
            PendingAIChangesBanner(settings: settings)
                .padding(.horizontal)
            Form {

            Section {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .onChange(of: settings.aiProvider) { _, newValue in
                    syncKeyField(for: newValue)
                    // Always anchor the model selection to the new provider's default (or empty,
                    // for providers like Apple that don't surface model IDs).
                    settings.aiModel = newValue.availableModels.first?.id ?? ""
                    Task { await refreshAvailability() }
                }

                if settings.aiProvider.requiresAPIKey {
                    LabeledContent("API Key") {
                        SecureField(apiKey.isEmpty ? "Required" : "", text: $apiKey)
                            .textContentType(.password)
                            .frame(width: 280)
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
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }

                // Status appears as its own right-aligned row so the indicator lines up with the
                // pickers above it instead of crowding the Provider row.
                HStack(spacing: 0) {
                    Spacer()
                    AvailabilityStatusView(
                        availability: availability,
                        isChecking: isCheckingAvailability,
                        isCurrent: availabilityIsCurrent
                    )
                }
            } header: {
                Text("Provider").font(.headline)
            } footer: {
                Text(settings.aiProvider.privacyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: $settings.autoCategorizeNewSenders) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-categorize new senders after refresh")
                        Text("Runs the categorizer in the background after each refresh so newly-seen senders pick up a category automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Automation").font(.headline)
            }

            Section {
                ForEach(AIFeature.allCases) { feature in
                    AIFeatureTuningRow(feature: feature, settings: settings)
                }
            } header: {
                Text("Advanced — per-feature tuning").font(.headline)
            } footer: {
                Text("Custom instructions are appended to the system prompt for that feature. Temperature and max-token tuning are advisory; Apple Foundation Models honors temperature on supported builds and ignores fields it doesn't expose. None of these knobs change *what* File13 sends to the model, only *how* the model is instructed and constrained.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("File13 uses AI for inbox triage on headers only (e.g., sender, subject, date). Body content is never read or sent. Choose Apple's on-device model for the strongest privacy; choose a third-party provider for more flexibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("How File13 uses AI").font(.headline)
            }
            }
            .formStyle(.grouped)
        }
        .padding(.vertical, 4)
        .task {
            syncKeyField(for: settings.aiProvider)
            ensureValidModel()
            await refreshAvailability()
        }
    }

    private var currentModelSummary: String? {
        settings.aiProvider.availableModels.first { $0.id == settings.aiModel }?.summary
    }

    /// If `aiModel` isn't a known option for the current provider — either because it was empty
    /// on first launch or because a previous build allowed custom IDs — anchor it to the
    /// provider's first available model so the Picker has a valid selection.
    private func ensureValidModel() {
        let options = settings.aiProvider.availableModels
        guard !options.isEmpty else { return }
        if !options.contains(where: { $0.id == settings.aiModel }) {
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

import File13Core
import SwiftUI

/// One disclosure row in the "Advanced — per-feature tuning" section. Edits a single
/// `AIFeatureTuning` value on `SettingsStore` for one `AIFeature`. Collapsed by default
/// because the defaults are sensible — we only want this UI in front of users who go
/// looking for it.
struct AIFeatureTuningRow: View {
    let feature: AIFeature
    @Bindable var settings: SettingsStore

    @State private var isExpanded: Bool = false
    /// Local working copy. Mirrored to `SettingsStore` on every change so the row never
    /// needs an explicit "Save". Re-synced from settings whenever the feature changes
    /// (currently never — features are static — but cheap to be safe).
    @State private var draft: AIFeatureTuning = AIFeatureTuning()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                providerOverrideRow
                modelOverrideRow
                temperatureRow
                maxTokensRow
                customInstructionsRow
                resetRow
            }
            .padding(.vertical, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.label).font(.body)
                    if !draft.isDefault {
                        Text("Customized")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(feature.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: feature.id) {
            draft = settings.tuning(for: feature)
        }
        .onChange(of: draft) { _, newValue in
            settings.setTuning(newValue, for: feature)
        }
    }

    // MARK: - Provider override

    @ViewBuilder
    private var providerOverrideRow: some View {
        let binding = Binding<ProviderChoice>(
            get: { draft.providerOverride.map(ProviderChoice.override) ?? .global },
            set: { newValue in
                switch newValue {
                case .global:
                    draft.providerOverride = nil
                    draft.modelOverride = ""
                case .override(let kind):
                    draft.providerOverride = kind
                    // Anchor model to the new provider's default so the model picker
                    // immediately has a valid selection. User can change it on the next row.
                    draft.modelOverride = kind.availableModels.first?.id ?? ""
                }
            }
        )
        Picker("Provider", selection: binding) {
            Text("Use global default (\(settings.aiProvider.label))").tag(ProviderChoice.global)
            Divider()
            ForEach(AIProviderKind.allCases) { kind in
                Text(kind.label).tag(ProviderChoice.override(kind))
            }
        }
        if let override = draft.providerOverride, override.requiresAPIKey, !hasKey(for: override) {
            Label("No API key for \(override.label) — set one above before this feature can run.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func hasKey(for kind: AIProviderKind) -> Bool {
        guard let key = try? KeychainStore.loadAIKey(for: kind) else { return false }
        return !(key ?? "").isEmpty
    }

    private enum ProviderChoice: Hashable {
        case global
        case override(AIProviderKind)
    }

    // MARK: - Model override

    @ViewBuilder
    private var modelOverrideRow: some View {
        if let override = draft.providerOverride, !override.availableModels.isEmpty {
            Picker("Model", selection: $draft.modelOverride) {
                ForEach(override.availableModels) { option in
                    Text(option.label).tag(option.id)
                }
            }
            if let summary = currentModelSummary(for: override) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func currentModelSummary(for kind: AIProviderKind) -> String? {
        kind.availableModels.first { $0.id == draft.modelOverride }?.summary
    }

    // MARK: - Temperature

    @ViewBuilder
    private var temperatureRow: some View {
        let overrideBinding = Binding<Bool>(
            get: { draft.temperature != nil },
            set: { newValue in
                draft.temperature = newValue ? feature.defaultTemperature : nil
            }
        )
        let valueBinding = Binding<Double>(
            get: { draft.temperature ?? feature.defaultTemperature },
            set: { draft.temperature = $0 }
        )

        HStack {
            Toggle("Override temperature", isOn: overrideBinding)
            Spacer()
            Text(String(format: "%.2f", valueBinding.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(draft.temperature == nil ? .secondary : .primary)
                .frame(width: 40, alignment: .trailing)
        }
        Slider(value: valueBinding, in: 0.0...1.0, step: 0.05)
            .disabled(draft.temperature == nil)
        Text("Default: \(String(format: "%.2f", feature.defaultTemperature))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Max tokens

    @ViewBuilder
    private var maxTokensRow: some View {
        let overrideBinding = Binding<Bool>(
            get: { draft.maxTokens != nil },
            set: { newValue in
                draft.maxTokens = newValue ? feature.defaultMaxTokens : nil
            }
        )
        let valueBinding = Binding<Int>(
            get: { draft.maxTokens ?? feature.defaultMaxTokens },
            set: { draft.maxTokens = $0 }
        )

        Toggle("Override max output tokens", isOn: overrideBinding)
        HStack {
            Stepper(value: valueBinding, in: 256...8192, step: 256) {
                Text("\(valueBinding.wrappedValue) tokens")
                    .foregroundStyle(draft.maxTokens == nil ? .secondary : .primary)
            }
            .disabled(draft.maxTokens == nil)
        }
        Text("Default: \(feature.defaultMaxTokens) tokens. Apple Foundation Models may ignore this on builds without `maximumResponseTokens` exposed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Custom instructions

    @ViewBuilder
    private var customInstructionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Custom instructions")
                    .font(.subheadline)
                Spacer()
                Text("\(draft.customInstructions.count) / \(AIFeatureTuning.customInstructionsMaxChars)")
                    .font(.caption)
                    .foregroundStyle(
                        draft.customInstructions.count > AIFeatureTuning.customInstructionsMaxChars
                            ? .red : .secondary
                    )
                    .monospacedDigit()
            }
            TextEditor(text: $draft.customInstructions)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                // Hard cap input length at the same limit that
                // `customInstructionsBlock` enforces downstream, so the
                // user can't accidentally type past it (and the counter
                // never goes red in normal use).
                .onChange(of: draft.customInstructions) { _, newValue in
                    if newValue.count > AIFeatureTuning.customInstructionsMaxChars {
                        draft.customInstructions = String(
                            newValue.prefix(AIFeatureTuning.customInstructionsMaxChars)
                        )
                    }
                }
            Text("Appended to the system prompt for this feature. Empty = no override. Example: \"Treat anything from @acme.com as VIP. Be conservative on charity senders.\"")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Reset

    @ViewBuilder
    private var resetRow: some View {
        HStack {
            Spacer()
            Button("Reset to defaults") {
                draft = AIFeatureTuning()
            }
            .disabled(draft.isDefault)
        }
    }
}

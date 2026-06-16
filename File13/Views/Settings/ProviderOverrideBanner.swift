import File13Core
import SwiftUI

/// Small banner that warns when the AI feature about to run uses a
/// *different* provider than the global setting. Defends against the
/// scenario where an iCloud-account-compromise (or a forgotten
/// override) silently routes one feature's metadata through a
/// third-party provider while the user's mental model says "I'm on
/// Apple Foundation Models, my data stays on-device."
///
/// Shown above the action button in the AI sheets that initiate
/// provider calls (Analyze senders, Rule suggestions). Renders nothing
/// when the feature's effective provider matches the global setting.
struct ProviderOverrideBanner: View {
    let feature: AIFeature
    let globalProvider: AIProviderKind
    let effectiveProvider: AIProviderKind

    init(feature: AIFeature, settings: SettingsStore) {
        self.feature = feature
        self.globalProvider = settings.aiProvider
        let override = settings.tuning(for: feature).providerOverride
        self.effectiveProvider = override ?? settings.aiProvider
    }

    var body: some View {
        if effectiveProvider != globalProvider {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text("Provider override active")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(feature.label) is set to use **\(effectiveProvider.label)**, not your default (\(globalProvider.label)). Metadata sent for this action will reach \(effectiveProvider.label).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.25))
        )
    }
}

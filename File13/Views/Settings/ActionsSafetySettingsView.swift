import File13Core
import SwiftUI

struct ActionsSafetySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var vipStore: VIPStore
    @Bindable var repliedStore: RepliedMessagesStore
    @Bindable var categoryStore: SenderCategoryStore

    var body: some View {
        VStack(spacing: 0) {
            // Pending-sync banners for the four sensitive surfaces that
            // touch destructive-action guard rails. They live outside
            // the Form on purpose: wrapping an empty banner in a Form
            // Section still renders the Section's grouping rect — four
            // empty grey rows — even when each banner self-collapses to
            // zero height. Hoisting them lets the empty state truly take
            // no visible space. Same pattern as `AIIntegrationSettingsView`.
            VStack(spacing: 8) {
                PendingSafetyChangesBanner(settings: settings)
                PendingVIPChangesBanner(vipStore: vipStore)
                PendingRepliedMessagesChangesBanner(repliedStore: repliedStore)
                PendingCategoriesChangesBanner(categoryStore: categoryStore)
            }
            .padding(.horizontal)

            Form {
                Section {
                Picker("Undo Buffer Duration", selection: $settings.undoBufferSeconds) {
                    ForEach(SettingsStore.allowedUndoBufferSeconds, id: \.self) { seconds in
                        Text(seconds == 0 ? "No undo (commit immediately)" : "\(seconds)s")
                            .tag(seconds)
                    }
                }
                Toggle("Confirm Before Delete", isOn: $settings.confirmBeforeDelete)
                Toggle("Confirm Before Unsubscribe", isOn: $settings.confirmBeforeUnsubscribe)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Handling of deleted items", selection: $settings.softDeleteToTrash) {
                        Text("Delete permanently").tag(false)
                        Text("Move to Trash folder").tag(true)
                    }
                    Text("Moving messages into your account's Trash folder allows you to recover them via your email client.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $settings.protectTransactionalFromDeletion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protect transactions from deletion")
                        Text("Delete skips receipts, order confirmations, invoices, bills, and shipping notifications. Detection is a heuristic on subject lines.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $settings.protectVIPsFromRules) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protect VIPs from deletion")
                        Text("Delete skips every message whose sender is a VIP. Pin or unpin VIPs from any sender row's context menu.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Destructive Actions").font(.headline)
            }

            Section {
                Toggle("Dry Run Mode", isOn: $settings.dryRunMode)
            } header: {
                Text("Automation").font(.headline)
            } footer: {
                Text("Dry Run Mode shows what actions would happen without committing them to the server. A banner is shown while it is active.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
        }
        .padding(.vertical, 4)
    }
}

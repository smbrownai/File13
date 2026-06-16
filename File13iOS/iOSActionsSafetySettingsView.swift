import File13Core
import SwiftUI

struct iOSActionsSafetySettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
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
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.protectTransactionalFromDeletion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protect transactions from deletion")
                        Text("Delete skips receipts, order confirmations, invoices, bills, and shipping notifications. Detection is a heuristic on subject lines.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.protectVIPsFromRules) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protect VIPs from deletion")
                        Text("Delete skips every message whose sender is a VIP. Pin or unpin VIPs from any sender row's context menu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.dryRunMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dry Run Mode")
                        Text("Dry Run Mode shows what actions would happen without committing them to the server. A banner is shown while it is active.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Destructive Actions")
            }
        }
        .navigationTitle("Actions & Safety")
        .navigationBarTitleDisplayMode(.inline)
    }
}

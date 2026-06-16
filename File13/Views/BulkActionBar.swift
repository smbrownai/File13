import File13Core
import SwiftUI

/// Footer strip that just reports selection state. The actual bulk actions live in
/// `BulkActionToolbar`, mounted in the window toolbar.
struct BulkActionBar: View {
    @Bindable var store: InboxStore

    var body: some View {
        HStack(spacing: 12) {
            Text(store.hasSelection
                 ? "\(store.selectedMessageCount.formatted()) selected"
                 : "No selection")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if store.hasSelection {
                Button {
                    store.clearSelection()
                } label: {
                    Label("Clear Selection", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Clear selection")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

import File13Core
import SwiftUI

/// Destination picker for the third bulk action — Move. Lists every mailbox
/// the session enumerated via XLIST, except the one the user is currently
/// viewing (moving into the current folder is a no-op). Tapping a row routes
/// through `InboxStore.moveSelection(to:)`, which arms the buffered pending
/// action with its undo banner — same path Delete and Archive use.
///
/// Sorting matches the nav-bar mailbox picker added in #14: system folders
/// first (inbox / sent / drafts / archive / trash / junk) in their natural
/// enum order, then custom folders alphabetically.
struct iOSMoveToFolderSheet: View {
    @Bindable var inbox: InboxStore
    let session: AccountSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if destinations.isEmpty {
                    ContentUnavailableView {
                        Label("No other folders", systemImage: "folder")
                    } description: {
                        Text("This account didn't advertise additional mailboxes. Add a folder on the Mac app or your IMAP host to expand the destination list.")
                    }
                } else {
                    ForEach(destinations) { mailbox in
                        Button {
                            inbox.moveSelection(to: mailbox.name)
                            dismiss()
                        } label: {
                            mailboxRow(mailbox)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func mailboxRow(_ mailbox: Mailbox) -> some View {
        HStack(spacing: 12) {
            Image(systemName: mailbox.systemIcon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(mailbox.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !mailbox.isSystem {
                    Text(mailbox.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let count = mailbox.messageCount {
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Mailboxes the user is allowed to move into. We strip the current
    /// mailbox (moving into the folder you're already in is a no-op) and apply
    /// the same sort the nav-bar picker uses.
    private var destinations: [Mailbox] {
        session.mailboxes
            .filter { $0.name != session.currentMailbox }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }
}

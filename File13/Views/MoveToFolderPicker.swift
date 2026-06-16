import File13Core
import SwiftUI

struct MoveToFolderPicker: View {
    @Bindable var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""

    private var destinations: [Mailbox] {
        let pool = inbox.mailboxes.filter { $0.name != inbox.currentMailbox }
        guard !search.isEmpty else { return pool }
        let q = search.lowercased()
        return pool.filter { $0.name.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text("Move \(inbox.selectedMessageCount.formatted()) message\(inbox.selectedMessageCount == 1 ? "" : "s") to…")
                        .font(.title3).bold()
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                TextField("Search folders", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Divider()

            if destinations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(inbox.mailboxes.isEmpty ? "No folders loaded yet." : "No folders match \"\(search)\".")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                List {
                    ForEach(destinations) { folder in
                        Button {
                            inbox.moveSelection(to: folder.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: folder.systemIcon)
                                    .foregroundStyle(folder.isSystem ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                                    .frame(width: 18)
                                Text(folder.displayName)
                                Spacer()
                                if folder.name != folder.displayName {
                                    Text(folder.name)
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 240, maxHeight: 360)
            }
        }
        .frame(width: 420)
    }
}

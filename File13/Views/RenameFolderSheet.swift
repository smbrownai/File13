import File13Core
import SwiftUI

struct RenameFolderSheet: View {
    @Bindable var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss

    let mailbox: Mailbox
    @State private var newName: String
    @State private var isWorking = false
    @State private var errorText: String?

    init(inbox: InboxStore, mailbox: Mailbox) {
        self.inbox = inbox
        self.mailbox = mailbox
        _newName = State(initialValue: mailbox.name)
    }

    private var trimmed: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmed.isEmpty && trimmed != mailbox.name && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "pencil")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename folder").font(.title3).bold()
                    Text("Renames \"\(mailbox.name)\" on the mail server. Changes are visible to every other client connected to the same account.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSubmit { Task { await submit() } } }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).lineLimit(3, reservesSpace: false)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Rename")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        errorText = nil
        do {
            try await inbox.renameMailbox(from: mailbox.name, to: trimmed)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

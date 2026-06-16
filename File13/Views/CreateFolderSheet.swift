import File13Core
import SwiftUI

struct CreateFolderSheet: View {
    @Bindable var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss

    /// Optional parent folder path. When set, the sheet pre-fills the input
    /// with `parentPath/` and the user types only the leaf name. Used by the
    /// sidebar's "New Subfolder…" context-menu action so the nesting is
    /// obvious in the UI rather than relying on the user remembering to type
    /// the slash separator themselves.
    var parentPath: String? = nil
    /// Hierarchy delimiter reported by the server for `parentPath`. When `nil`
    /// (or no parent is set) we fall back to `/` for backward compatibility
    /// with the original create flow, which has always assumed `/` in the
    /// hint copy.
    var parentDelimiter: String? = nil

    @State private var name: String = ""
    @State private var isWorking = false
    @State private var errorText: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && !isWorking
    }

    private var heading: String {
        parentPath == nil ? "Create folder" : "Create subfolder"
    }

    private var hint: String {
        if let parentPath {
            return "New folder under “\(parentPath)”."
        }
        return "Use a slash for nested folders, e.g. \"Receipts/2026\"."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading).font(.title3).bold()
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Folder name", text: $name, prompt: Text(parentPath == nil ? "Receipts" : "2026"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSubmit { Task { await submit() } } }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3, reservesSpace: false)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        errorText = nil
        let fullName: String
        if let parentPath, !parentPath.isEmpty {
            // Force-unwrap is guarded by the inline `.isEmpty == false`
            // check — when the optional is non-empty it's by definition
            // non-nil. Same pattern as `SidebarView.depth(of:)`.
            let delim = (parentDelimiter?.isEmpty == false) ? parentDelimiter! : "/"
            fullName = "\(parentPath)\(delim)\(trimmedName)"
        } else {
            fullName = trimmedName
        }
        do {
            try await inbox.createMailbox(named: fullName)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

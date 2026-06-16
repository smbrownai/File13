import File13Core
import SwiftUI

/// Bulk action cluster for the window toolbar — each button is its own
/// `ToolbarItem` so macOS renders them with native toolbar styling and spacing,
/// matching Apple Mail's Reply / Archive / Trash row.
struct BulkActionToolbar: ToolbarContent {
    @Bindable var store: InboxStore
    @Bindable var ruleStore: RuleStore
    var onAnalyzeSenders: ([Sender]) -> Void = { _ in }

    @Binding var showMovePicker: Bool
    @Binding var showDeleteConfirm: Bool
    @Binding var ruleDraft: Rule?
    @Binding var unsubscribeCandidates: [InboxStore.UnsubscribeCandidate]?
    @Binding var unsubscribeAutoRun: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                if store.requiresDeleteConfirmation {
                    showDeleteConfirm = true
                } else {
                    store.startDelete()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!store.hasSelection)
            .help(store.hasSelection ? "Delete selected messages" : "Delete (no selection)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.archiveSelection()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(!store.canArchiveSelection)
            .help(store.canArchiveSelection ? "Archive selected messages" : "Archive (no selection)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showMovePicker = true
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
            .disabled(!store.canMoveSelection || store.mailboxes.isEmpty)
            .help(store.canMoveSelection
                  ? "Move selected messages to a folder"
                  : "Move to Folder — switch to a single account to enable.")
            .popover(isPresented: $showMovePicker, arrowEdge: .top) {
                MoveToFolderPicker(inbox: store)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                unsubscribeAutoRun = !store.requiresUnsubscribeConfirmation
                unsubscribeCandidates = store.unsubscribeCandidatesForSelection()
            } label: {
                Label("Unsubscribe", systemImage: "envelope.badge")
            }
            .disabled(!store.canUnsubscribeSelection)
            .help(store.canUnsubscribeSelection
                  ? "Unsubscribe from selected senders"
                  : "Unsubscribe — none of the selected senders include a List-Unsubscribe header.")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                ruleDraft = store.draftRuleFromSelection()
            } label: {
                Label("Create Rule", systemImage: "wand.and.stars")
            }
            .disabled(!store.hasSelection)
            .help(store.hasSelection ? "Create a rule from the selection" : "Create Rule (no selection)")
        }
    }
}

/// Owns the dialog/sheet/popover state for the bulk-action toolbar items and
/// renders the dialogs. ToolbarItems can host popovers but their detached
/// presentation makes sheet/confirmation hosting fragile, so we anchor those on
/// a sibling overlay that stays inside the main detail hierarchy.
struct BulkActionDialogs: ViewModifier {
    @Bindable var store: InboxStore
    @Bindable var ruleStore: RuleStore

    @Binding var showDeleteConfirm: Bool
    @Binding var ruleDraft: Rule?
    @Binding var unsubscribeCandidates: [InboxStore.UnsubscribeCandidate]?
    var unsubscribeAutoRun: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                if deleteablePending > 0 {
                    Button(deleteActionLabel, role: .destructive) { store.startDelete() }
                }
                Button(deleteablePending == 0 ? "OK" : "Cancel", role: .cancel) { }
            } message: {
                Text(deleteDialogMessage)
            }
            .sheet(item: $ruleDraft) { draft in
                RuleBuilderSheet(ruleStore: ruleStore, inbox: store, initial: draft)
            }
            .sheet(isPresented: Binding(
                get: { unsubscribeCandidates != nil },
                set: { if !$0 { unsubscribeCandidates = nil } }
            )) {
                UnsubscribeSheet(
                    candidates: unsubscribeCandidates ?? [],
                    autoRun: unsubscribeAutoRun,
                    mailClientAppURL: store.preferredMailClientAppURL,
                    browserAppURL: store.preferredBrowserAppURL
                )
            }
    }

    private var deleteablePending: Int {
        max(0, store.selectedMessageCount - store.selectedTransactionalCount)
    }

    private var deleteActionLabel: String {
        store.isSoftDeleteActive ? "Move to Trash" : "Delete"
    }

    private var deleteDialogTitle: String {
        let pending = deleteablePending
        if pending == 0 {
            return "All selected messages are protected"
        }
        let suffix = pending == 1 ? "" : "s"
        if store.isSoftDeleteActive {
            return "Move \(pending.formatted()) message\(suffix) to Trash?"
        }
        return "Permanently delete \(pending.formatted()) message\(suffix)?"
    }

    private var deleteDialogMessage: String {
        let pending = deleteablePending
        let protected = store.selectedTransactionalCount
        let bufferSeconds = store.undoBufferSeconds

        let actionPhrase = store.isSoftDeleteActive
            ? "moved to your account's Trash folder"
            : "permanently removed from the server"

        var lines: [String] = []
        if pending > 0 {
            lines.append("\(pending.formatted()) message\(pending == 1 ? "" : "s") will be \(actionPhrase) after the undo buffer (\(bufferSeconds)s).")
        }
        if protected > 0 {
            let plural = protected == 1 ? "" : "s"
            lines.append("\(protected.formatted()) message\(plural) will be protected. Turn off the protection in Settings → Actions & Safety to act on them.")
        }
        return lines.isEmpty ? " " : lines.joined(separator: "\n\n")
    }
}

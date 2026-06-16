import File13Core
import SwiftUI

/// Subject-grouped view of the current scope's INBOX. Tapping a cluster
/// pushes `iOSSubjectDetailView` showing every message that normalized to
/// the same subject (across all senders in scope).
///
/// Multi-select binds to a local `Set<String>` of cluster ids and an
/// `.onChange` materializes the union of message ids into
/// `inbox.selectedMessageIds`, mirroring how `iOSSenderListView` works.
/// Bulk actions live on `iOSMessageListView`'s bottom bar.
struct iOSSubjectListView: View {
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore

    @State private var clusterSelection: Set<String> = []
    /// Cluster awaiting confirmation for a swipe-driven "Delete all" action.
    /// Same shape as `iOSSenderListView.pendingDeleteSender` — the swipe row
    /// has already collapsed by the time the user is presented with the
    /// dialog, so we stash the cluster here to fire the delete on accept.
    @State private var pendingDeleteCluster: SubjectCluster?

    /// See the matching comment in `iOSSenderListView`: pass `nil` to
    /// `List(selection:)` when not editing so single taps push the
    /// `NavigationLink(value:)` instead of being absorbed as selection
    /// changes that go nowhere.
    @Environment(\.editMode) private var editMode

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    var body: some View {
        List(selection: isEditing ? $clusterSelection : nil) {
            ForEach(inbox.subjectClusters) { cluster in
                // Value-based NavigationLink + navigationDestination below.
                // Closure-based NavigationLink rows suppress List(selection:)
                // edit-mode selection circles; routing through the value/
                // destination pair restores multi-select while keeping
                // single-tap navigation in non-edit mode.
                NavigationLink(value: cluster.id) {
                    ClusterRow(cluster: cluster)
                }
                .tag(cluster.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        if settings.confirmBeforeDelete {
                            pendingDeleteCluster = cluster
                        } else {
                            applyOneOff(.delete, to: Set(cluster.messages.map(\.id)))
                        }
                    } label: {
                        Label("Delete all", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if inbox.archiveMailboxName != nil {
                        Button {
                            applyOneOff(.archive, to: Set(cluster.messages.map(\.id)))
                        } label: {
                            Label("Archive all", systemImage: "archivebox")
                        }
                        .tint(.blue)
                    }
                }
            }
            tabBarSpacer
        }
        .listStyle(.plain)
        .navigationDestination(for: String.self) { clusterId in
            if let cluster = inbox.subjectClusters.first(where: { $0.id == clusterId }) {
                iOSSubjectDetailView(cluster: cluster)
            }
        }
        .searchable(text: $inbox.search, prompt: "Search subjects")
        .onChange(of: clusterSelection) { _, newSet in
            inbox.selectedMessageIds = messageIds(forSelectedClusters: newSet)
        }
        .onChange(of: inbox.selectedMessageIds.isEmpty) { _, isEmpty in
            if isEmpty, !clusterSelection.isEmpty {
                clusterSelection.removeAll()
            }
        }
        .overlay {
            if inbox.subjectClusters.isEmpty {
                ContentUnavailableView {
                    Label("No subjects", systemImage: "text.alignleft")
                } description: {
                    Text(inbox.effectiveSearch.isEmpty
                         ? "Pull down to refresh."
                         : "No subjects match \"\(inbox.effectiveSearch)\".")
                }
            }
        }
        .confirmationDialog(
            pendingDeleteCluster.map {
                "Delete \($0.messageCount) message\($0.messageCount == 1 ? "" : "s") with subject \"\($0.representative.isEmpty ? "(no subject)" : $0.representative)\"?"
            } ?? "Delete messages?",
            isPresented: Binding(
                get: { pendingDeleteCluster != nil },
                set: { if !$0 { pendingDeleteCluster = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let cluster = pendingDeleteCluster {
                    applyOneOff(.delete, to: Set(cluster.messages.map(\.id)))
                }
                pendingDeleteCluster = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteCluster = nil }
        } message: {
            Text(settings.dryRunMode
                 ? "Dry-run mode is on — local list will update but the server won't be touched."
                 : "You'll have \(settings.undoBufferSeconds) seconds to undo before it commits to the server.")
        }
    }

    private func messageIds(forSelectedClusters clusterIds: Set<String>) -> Set<String> {
        var ids: Set<String> = []
        let lookup = inbox.subjectClusters
        for clusterId in clusterIds {
            guard let cluster = lookup.first(where: { $0.id == clusterId }) else { continue }
            for message in cluster.messages {
                ids.insert(message.id)
            }
        }
        return ids
    }

    /// Same swap-and-restore shape as `iOSMessageListView.applyOneOff` and
    /// `InboxStore.applyAction(_:toSender:)` — saves the visible multi-select
    /// state, swaps to the cluster's message ids, fires the buffered action
    /// (which clears selection internally), then restores. The Mac app's
    /// `InboxStore` doesn't ship an `applyAction(_:toCluster:)` helper today
    /// because the desktop interaction model doesn't need one; we keep the
    /// pattern inline here rather than growing the shared API surface for one
    /// iOS-only swipe target.
    private func applyOneOff(_ kind: InboxStore.PendingAction.Kind, to ids: Set<String>) {
        let saved = inbox.selectedMessageIds
        inbox.selectedMessageIds = ids
        switch kind {
        case .delete:                  inbox.startDelete()
        case .archive:                 inbox.archiveSelection()
        case .move(let destination):   inbox.moveSelection(to: destination)
        }
        inbox.selectedMessageIds = saved
    }
}

/// Single subject-cluster row. Representative subject + message count on
/// top, unread badge + last-seen date + unique-sender count on the bottom.
/// Unique-sender count helps the user spot when a single subject is being
/// reused by many different senders (newsletter pattern).
private struct ClusterRow: View {
    let cluster: SubjectCluster

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(cluster.representative.isEmpty ? "(no subject)" : cluster.representative)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text("\(cluster.messageCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                if cluster.unreadCount > 0 {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tint)
                    Text("\(cluster.unreadCount) unread")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if cluster.uniqueSenderCount > 1 {
                    Label("\(cluster.uniqueSenderCount) senders", systemImage: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Text(cluster.mostRecent, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

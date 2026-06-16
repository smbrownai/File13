import File13Core
import SwiftUI

/// Sender-grouped view of the current scope's INBOX. Tapping a sender pushes
/// `iOSSenderDetailView` showing every message from that sender; multi-select
/// in Edit mode picks whole senders at a time — the row's id is the sender
/// id, and changing the selection materializes the union of that sender's
/// message ids into `inbox.selectedMessageIds` so the shared
/// `inbox.startDelete()` / `inbox.archiveSelection()` paths Just Work.
///
/// Also hosts the on-demand AI categorization run. A toolbar button kicks off
/// `SenderCategorizer` for the senders that don't already have a category, or
/// re-runs the whole set on long-press. Results merge into the shared
/// `SenderCategoryStore`; `SenderRow` reads back from the store so the colored
/// category badge appears on each row that has a result.
///
/// Bulk action toolbar lives on `iOSMessageListView`. This view is just the
/// content body for `inbox.displayMode == .sender`.
struct iOSSenderListView: View {
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore

    /// Local selection of sender ids. We can't bind the SwiftUI List
    /// selection to `inbox.selectedMessageIds` directly here because the row
    /// id space is sender ids, not message ids — they don't line up. Instead
    /// we own a `Set<String>` of sender ids, and `.onChange` flattens that
    /// into the matching message ids on the store. When `displayMode`
    /// switches, `iOSMessageListView` clears both sets so we don't render a
    /// stale partial selection.
    @State private var senderSelection: Set<String> = []

    @State private var categorization: CategorizationState = .idle
    @State private var categorizationError: String?
    /// Sender awaiting confirmation for a swipe-driven "Delete all" action.
    /// Held here because the swipe row dismisses immediately; the
    /// `.confirmationDialog` below uses this target to fire the buffered
    /// delete when the user accepts. Bypassed when
    /// `settings.confirmBeforeDelete` is off.
    @State private var pendingDeleteSender: Sender?

    /// Edit-mode binding propagated by `iOSMessageListView`. When inactive,
    /// we pass `nil` to `List(selection:)` so single taps fall through to the
    /// row's `NavigationLink(value:)` and push the detail view. When active,
    /// the selection binding takes over and taps toggle multi-select. Without
    /// the conditional, an always-on selection binding silently absorbed the
    /// non-edit-mode tap — row darkened but no navigation.
    @Environment(\.editMode) private var editMode

    /// Optional category narrowing. When set, only senders whose
    /// `SenderCategoryStore.category(for:)` matches stay in the rendered
    /// list. Local @State on purpose: the filter is iOS-only chrome and
    /// hasn't earned a home on `InboxStore` yet. The macOS app's analog of
    /// this lives in the activity dashboard's faceted view, not the sender
    /// list itself.
    @State private var categoryFilter: SenderCategory?

    private enum CategorizationState: Equatable {
        case idle
        case running(completed: Int, total: Int)
    }

    /// The senders to render. `inbox.displaySenders` already applies the
    /// inbox search + sort; we just narrow it further when `categoryFilter`
    /// is set. Uncategorized senders fall out of the result entirely when a
    /// filter is active — by design, an unclassified sender doesn't qualify
    /// for any specific category.
    private var visibleSenders: [Sender] {
        guard let filter = categoryFilter else { return inbox.displaySenders }
        return inbox.displaySenders.filter { sender in
            categoryStore.category(for: sender.id) == filter
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // View-mode controls (Filter + Categorize) as a second row
            // below the nav bar. Used to be `.bottomBar` items, but that
            // collided with the floating iOS 26 tab bar. Briefly tried a
            // top `safeAreaInset` instead — that broke the principal
            // mailbox-picker Menu's popover positioning. A plain VStack
            // sibling above the List is the geometry SwiftUI handles
            // cleanly without interfering with nav-bar interactions.
            HStack(spacing: 12) {
                filterButton
                Spacer()
                categorizeButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            senderList
        }
    }

    /// `true` only while the parent has toggled iOS multi-select on. Read via
    /// `@Environment(\.editMode)` so the conditional selection binding flips
    /// in lockstep with the toolbar's Select / Done button.
    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    private var senderList: some View {
        List(selection: isEditing ? $senderSelection : nil) {
            // Trailing transparent spacer — see comment on the closing
            // `tabBarSpacer` row at the bottom of this list. Don't move or
            // remove without checking the iOS 26 tab-bar overlap fix.
            ForEach(visibleSenders) { sender in
                // Value-based NavigationLink so SwiftUI's `List(selection:)`
                // shows multi-select circles in EditMode. The previous
                // closure-based NavigationLink claimed the row's tap and
                // suppressed selection rendering — Edit toggled to Done but
                // no circles appeared. The destination is registered via
                // `.navigationDestination(for: String.self)` on the List
                // below; tag matches the value type so the selection set
                // (sender ids) lines up with the row's identity.
                NavigationLink(value: sender.id) {
                    SenderRow(sender: sender, category: categoryStore.category(for: sender.id))
                }
                .tag(sender.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        if settings.confirmBeforeDelete {
                            pendingDeleteSender = sender
                        } else {
                            inbox.applyAction(.delete, toSender: sender)
                        }
                    } label: {
                        Label("Delete all", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if inbox.archiveMailboxName != nil {
                        Button {
                            inbox.applyAction(.archive, toSender: sender)
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
        .navigationDestination(for: String.self) { senderId in
            if let sender = inbox.sender(byId: senderId) {
                iOSSenderDetailView(
                    sender: sender,
                    inbox: inbox,
                    settings: settings,
                    categoryStore: categoryStore
                )
            }
        }
        .searchable(text: $inbox.search, prompt: "Search senders")
        .onChange(of: senderSelection) { _, newSet in
            inbox.selectedMessageIds = messageIds(forSelectedSenders: newSet)
        }
        .onChange(of: inbox.selectedMessageIds.isEmpty) { _, isEmpty in
            if isEmpty, !senderSelection.isEmpty {
                senderSelection.removeAll()
            }
        }
        .alert(
            "Categorization failed",
            isPresented: Binding(
                get: { categorizationError != nil },
                set: { if !$0 { categorizationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(categorizationError ?? "")
        }
        .overlay {
            if visibleSenders.isEmpty {
                emptyStateOverlay
            }
        }
        .confirmationDialog(
            pendingDeleteSender.map {
                "Delete \($0.messageCount) message\($0.messageCount == 1 ? "" : "s") from \($0.name.isEmpty ? $0.address : $0.name)?"
            } ?? "Delete messages?",
            isPresented: Binding(
                get: { pendingDeleteSender != nil },
                set: { if !$0 { pendingDeleteSender = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let sender = pendingDeleteSender {
                    inbox.applyAction(.delete, toSender: sender)
                }
                pendingDeleteSender = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteSender = nil }
        } message: {
            Text(settings.dryRunMode
                 ? "Dry-run mode is on — local list will update but the server won't be touched."
                 : "You'll have \(settings.undoBufferSeconds) seconds to undo before it commits to the server.")
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if let filter = categoryFilter, !inbox.displaySenders.isEmpty {
            // The unfiltered list has senders; the active filter is what's
            // hiding everything. Give the user a one-tap escape rather than
            // making them re-find the filter menu.
            ContentUnavailableView {
                Label("No senders in \(filter.label)", systemImage: filter.symbol)
                    .foregroundStyle(filter.color)
            } description: {
                Text("No senders match this category. Run Categorize if you haven't yet.")
            } actions: {
                Button("Show all") { categoryFilter = nil }
                    .buttonStyle(.borderedProminent)
            }
        } else if inbox.displaySenders.isEmpty {
            ContentUnavailableView {
                Label("No senders", systemImage: "person.crop.circle")
            } description: {
                Text(inbox.effectiveSearch.isEmpty
                     ? "Pull down to refresh."
                     : "No senders match \"\(inbox.effectiveSearch)\".")
            }
        }
    }

    @ViewBuilder
    private var categorizeButton: some View {
        switch categorization {
        case .idle:
            Menu {
                Button {
                    Task { await runCategorization(force: false) }
                } label: {
                    Label("Categorize new senders", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
                Button {
                    Task { await runCategorization(force: true) }
                } label: {
                    Label("Recategorize all", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
            } label: {
                Label("Categorize", systemImage: "sparkles")
                    .font(.callout)
            }
            .disabled(inbox.displaySenders.isEmpty)
        case .running(let completed, let total):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("\(completed) / \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Category narrowing. Menu shows All + every defined `SenderCategory`,
    /// each entry decorated with its symbol/color so the current taxonomy
    /// stays visually consistent with the row badges. Selected option gets a
    /// leading checkmark. The button label flips between a neutral "Filter"
    /// icon and the selected category's symbol so the active state is
    /// recognisable at a glance.
    @ViewBuilder
    private var filterButton: some View {
        Menu {
            Button {
                categoryFilter = nil
            } label: {
                if categoryFilter == nil {
                    Label("All senders", systemImage: "checkmark")
                } else {
                    Text("All senders")
                }
            }
            Divider()
            ForEach(SenderCategory.allCases) { category in
                Button {
                    categoryFilter = (categoryFilter == category) ? nil : category
                } label: {
                    if categoryFilter == category {
                        Label(category.label, systemImage: "checkmark")
                    } else {
                        Label(category.label, systemImage: category.symbol)
                    }
                }
            }
        } label: {
            if let filter = categoryFilter {
                Label(filter.label, systemImage: filter.symbol)
                    .foregroundStyle(filter.color)
                    .font(.callout)
            } else {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout)
            }
        }
    }

    // MARK: - Run

    @MainActor
    private func runCategorization(force: Bool) async {
        let allIds = inbox.displaySenders.map(\.id)
        let targetIds = force
            ? Set(allIds)
            : Set(categoryStore.uncategorized(amongSenderIds: allIds))
        let targets = inbox.displaySenders.filter { targetIds.contains($0.id) }
        guard !targets.isEmpty else { return }

        let provider = LLMProviderFactory.make(for: .senderCategorize, settings: settings)
        let categorizer = SenderCategorizer(
            provider: provider,
            tuning: settings.tuning(for: .senderCategorize)
        )
        categorization = .running(completed: 0, total: targets.count)
        defer { categorization = .idle }
        do {
            let (results, errors) = try await categorizer.categorize(targets) { completed, total in
                categorization = .running(completed: completed, total: total)
            }
            if !results.isEmpty {
                categoryStore.merge(results)
            }
            if !errors.isEmpty, results.isEmpty {
                categorizationError = errors.first?.localizedDescription ?? "Unknown error"
            } else if !errors.isEmpty {
                categorizationError = "Some batches failed: \(errors.first?.localizedDescription ?? "")"
            }
        } catch {
            categorizationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func messageIds(forSelectedSenders senderIds: Set<String>) -> Set<String> {
        var ids: Set<String> = []
        for senderId in senderIds {
            guard let sender = inbox.sender(byId: senderId) else { continue }
            for message in sender.messages {
                ids.insert(message.id)
            }
        }
        return ids
    }
}

/// Single sender row. Name + count on top, address on the second line, last
/// seen + unread + category on the bottom. Category badge only appears when
/// the categorizer has produced one — uncategorized senders show the same
/// row they always did.
private struct SenderRow: View {
    let sender: Sender
    let category: SenderCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(sender.name.isEmpty ? sender.address : sender.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(sender.messageCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !sender.name.isEmpty {
                Text(sender.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                if sender.unreadCount > 0 {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tint)
                    Text("\(sender.unreadCount) unread")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let category {
                    CategoryBadge(category: category)
                }
                Spacer()
                Text(sender.mostRecent, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Transparent footer row used by all three iOS list views (sender,
/// subject, chronological) to guarantee that the last real row clears
/// the iOS 26 floating Liquid Glass tab bar. `.listStyle(.plain)` inside
/// a `TabView` does not extend the safe area for the floating tab bar,
/// so without this the bottom row stays clipped behind the
/// Mailboxes / Rules / Settings pill. Height matches the tab bar's
/// visible region (~60pt including the home-indicator gap).
@MainActor
var tabBarSpacer: some View {
    Color.clear
        .frame(height: 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .selectionDisabled()
}

/// Compact pill that shows a sender's category. Uses
/// `SenderCategory.symbol` and `.color` so the visual identity matches
/// what the macOS activity dashboard surfaces.
struct CategoryBadge: View {
    let category: SenderCategory

    var body: some View {
        Label(category.label, systemImage: category.symbol)
            .font(.caption2)
            .foregroundStyle(category.color)
            .labelStyle(.titleAndIcon)
    }
}

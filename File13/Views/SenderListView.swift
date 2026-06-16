import File13Core
import SwiftUI

struct SenderListView: View {
    @Bindable var store: InboxStore
    var onAnalyzeSender: (Sender) -> Void = { _ in }

    /// Set by `SectionJumpBar` to ask `SenderTable` to scroll the matching
    /// group's header into view. `SenderTable.updateNSView` consumes the
    /// value and resets it back to nil — so this round-trips through the
    /// table once per click and stays clear the rest of the time.
    @State private var scrollTarget: UnsubscribeGroup?

    var body: some View {
        VStack(spacing: 0) {
            if store.newslettersOnly {
                SectionJumpBar(
                    sections: store.displaySendersGrouped,
                    onJump: { group in scrollTarget = group }
                )
            }
            SenderTable(
                store: store,
                rows: rows,
                onAnalyzeSender: onAnalyzeSender,
                scrollToGroup: $scrollTarget
            )
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search senders")
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Flat sender list by default; when the Newsletters toggle is on we
    /// interleave `SenderGroupSection` headers with their senders so the
    /// table renders one-click → website → email buckets in priority order.
    /// The grouping is presentational only — `SenderTable` routes selection
    /// and actions through the same `InboxStore` paths in both modes.
    private var rows: [SenderTable.Row] {
        guard store.newslettersOnly else {
            return store.displaySenders.map { .sender($0) }
        }
        let sections = store.displaySendersGrouped
        // If `displaySendersGrouped` returns empty (e.g., none of the
        // newsletter senders has a `List-Unsubscribe` header), fall back to
        // the flat list so the user still sees something rather than a blank
        // table.
        guard !sections.isEmpty else {
            return store.displaySenders.map { .sender($0) }
        }
        var rows: [SenderTable.Row] = []
        rows.reserveCapacity(sections.reduce(0) { $0 + $1.count + 1 })
        for section in sections {
            rows.append(.header(section))
            for sender in section.senders {
                rows.append(.sender(sender))
            }
        }
        return rows
    }
}

// MARK: - Jump-to-section bar

/// Slim navigation strip rendered above `SenderTable` whenever the
/// Newsletters toggle is on. One pill per non-empty `UnsubscribeGroup`
/// (One-Click / Website / Email / No Link), each labeled with its sender
/// count. Tapping a pill scrolls the table so that section's header lands
/// at the top of the visible area.
///
/// Static-state pills (no "active" highlight tracking the visible scroll
/// position). Keeping it stateless avoids the cost of constantly polling
/// `NSScrollView` for what's centered; the user clicks, the table scrolls,
/// done.
private struct SectionJumpBar: View {
    let sections: [SenderGroupSection]
    let onJump: (UnsubscribeGroup) -> Void

    var body: some View {
        if sections.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Text("Jump to")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(sections) { section in
                    Button {
                        onJump(section.group)
                    } label: {
                        HStack(spacing: 4) {
                            Text(section.group.title)
                                .font(.callout)
                            Text("\(section.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(section.group.caption)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

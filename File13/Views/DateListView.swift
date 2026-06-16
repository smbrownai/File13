import File13Core
import SwiftUI

struct DateListView: View {
    @Bindable var store: InboxStore
    @State private var focusedBucketKind: DateBucketKind?
    @FocusState private var listFocused: Bool

    var body: some View {
        let buckets = store.dateBuckets
        let total = max(1, buckets.reduce(0) { $0 + $1.messageCount })

        VStack(spacing: 0) {
            ColumnHeader()
            Divider()
            ScrollView {
                // `.leading` alignment + the `.frame(maxWidth:.infinity,
                // alignment:.leading)` on each row prevents the centering
                // trap: when a bucket label + the fixed columns overflow the
                // pane, a default-aligned `LazyVStack` centers the row,
                // pushing the checkbox off-screen-left.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(buckets) { bucket in
                        BucketRow(
                            store: store,
                            bucket: bucket,
                            total: total,
                            isFocused: focusedBucketKind == bucket.kind
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedBucketKind = bucket.kind
                            listFocused = true
                        }
                        .contextMenu {
                            BucketContextMenu(store: store, bucket: bucket)
                        }
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            toggleSelectionOfFocused(in: buckets)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            setExpansionOfFocused(true)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            setExpansionOfFocused(false)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveFocus(by: -1, in: buckets)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(by: 1, in: buckets)
            return .handled
        }
        .onKeyPress(.escape) {
            if store.hasSelection { store.clearSelection(); return .handled }
            return .ignored
        }
    }

    private func toggleSelectionOfFocused(in buckets: [DateBucket]) {
        guard let kind = focusedBucketKind,
              let bucket = buckets.first(where: { $0.kind == kind }) else { return }
        let isOn = store.isBucketFullySelected(bucket)
        store.setBucketSelected(bucket, selected: !isOn)
    }

    private func setExpansionOfFocused(_ expand: Bool) {
        guard let kind = focusedBucketKind else { return }
        let isExpanded = store.expandedBucketIds.contains(kind)
        if expand && !isExpanded { store.toggleBucketExpansion(kind) }
        if !expand && isExpanded { store.toggleBucketExpansion(kind) }
    }

    private func moveFocus(by delta: Int, in buckets: [DateBucket]) {
        guard !buckets.isEmpty else { return }
        listFocused = true
        if let current = focusedBucketKind,
           let i = buckets.firstIndex(where: { $0.kind == current }) {
            let next = max(0, min(buckets.count - 1, i + delta))
            focusedBucketKind = buckets[next].kind
        } else {
            focusedBucketKind = delta > 0 ? buckets.first?.kind : buckets.last?.kind
        }
    }
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 32)             // checkbox col
            Spacer().frame(width: 16)             // disclosure col
            Text("Time bucket")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Share")
                .frame(width: 96, alignment: .trailing)
            Text("Messages")
                .frame(width: 96, alignment: .trailing)
            Text("Unread")
                .frame(width: 80, alignment: .trailing)
            // "Most recent" intentionally removed — each bucket *is* a date
            // range (Today / This week / etc.), so the per-bucket newest-date
            // column was redundant and a 140pt cost that pushed rows into
            // the `LazyVStack` centering trap on narrower windows.
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BucketRow: View {
    @Bindable var store: InboxStore
    let bucket: DateBucket
    let total: Int
    var isFocused: Bool = false

    private var isExpanded: Bool { store.expandedBucketIds.contains(bucket.kind) }
    private var sharePercent: Int {
        Int((Double(bucket.messageCount) / Double(total)) * 100.rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TriStateCheckbox(
                    isOn: store.isBucketFullySelected(bucket),
                    isMixed: store.isBucketPartiallySelected(bucket)
                ) { newValue in
                    store.setBucketSelected(bucket, selected: newValue)
                }
                .frame(width: 32)

                Button {
                    store.toggleBucketExpansion(bucket.kind)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
                .disabled(bucket.messageCount == 0)

                HStack(spacing: 8) {
                    Image(systemName: bucket.kind.symbol)
                        .foregroundStyle(.secondary)
                    Text(bucket.kind.label)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ShareBar(percent: sharePercent)
                    .frame(width: 96, alignment: .trailing)

                Text(bucket.messageCount.formatted())
                    .monospacedDigit()
                    .frame(width: 96, alignment: .trailing)

                UnreadBadge(count: bucket.unreadCount)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isFocused ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if bucket.messageCount > 0 { store.toggleBucketExpansion(bucket.kind) }
            }

            if isExpanded {
                SenderBreakdown(store: store, bucket: bucket)
            }
        }
    }
}

private struct BucketContextMenu: View {
    @Bindable var store: InboxStore
    let bucket: DateBucket

    var body: some View {
        let count = bucket.messageCount
        let fullySelected = store.isBucketFullySelected(bucket)
        Button(fullySelected ? "Deselect all in \(bucket.kind.label)" : "Select all in \(bucket.kind.label)") {
            store.setBucketSelected(bucket, selected: !fullySelected)
        }
        .disabled(count == 0)

        Divider()

        Button("Delete \(bucket.kind.label) (\(count))…") {
            store.replaceSelection(withBucket: bucket)
            store.startDelete()
        }
        .disabled(count == 0)

        Button("Archive \(bucket.kind.label) (\(count))") {
            store.replaceSelection(withBucket: bucket)
            store.archiveSelection()
        }
        .disabled(count == 0)
    }
}

private struct ShareBar: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: max(0, CGFloat(percent) * 0.6), height: 6)
            }
            .frame(width: 60)
            Text("\(percent)%")
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private struct SenderBreakdown: View {
    @Bindable var store: InboxStore
    let bucket: DateBucket

    var body: some View {
        // `bucket.topSenders` is precomputed at cache-rebuild time — see
        // `DateBucketAccumulator.finish`. Re-running the grouping here on
        // every expand/collapse used to dominate frame time for large
        // buckets (50k+ messages re-grouped per disclosure tap).
        let groups = bucket.topSenders
        let hasMore = bucket.distinctSenderCount > groups.count

        VStack(spacing: 0) {
            ForEach(groups) { sender in
                HStack(spacing: 12) {
                    Spacer().frame(width: 32)
                    Spacer().frame(width: 16)
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(sender.name.isEmpty ? sender.address : sender.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(sender.messageCount.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
            }
            if hasMore {
                Text("…and \((bucket.distinctSenderCount - groups.count).formatted()) more")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
            }
        }
        .padding(.leading, 28)
    }
}

import File13Core
import SwiftUI

/// Drill-in from `iOSSubjectListView` — every message that normalized to
/// the same subject, across however many senders contributed to the cluster.
/// Read-only in v1; sender-level and message-level actions belong on the
/// chronological or sender views back upstream.
struct iOSSubjectDetailView: View {
    let cluster: SubjectCluster

    var body: some View {
        List {
            Section {
                ForEach(cluster.messages) { header in
                    ClusterMessageRow(header: header)
                }
            } header: {
                summaryHeader
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .navigationTitle(cluster.representative.isEmpty ? "(no subject)" : cluster.representative)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(cluster.messageCount) message\(cluster.messageCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if cluster.unreadCount > 0 {
                    Text("· \(cluster.unreadCount) unread")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
                Spacer()
            }
            if cluster.uniqueSenderCount > 1 {
                Text("\(cluster.uniqueSenderCount) senders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Compact row for the per-cluster detail view. Leads with sender (so the
/// "who's sending this same subject" question is visible at a glance) and
/// drops the subject line — the navigation title already says it.
private struct ClusterMessageRow: View {
    let header: MessageHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(header.senderName.isEmpty ? header.senderAddress : header.senderName)
                    .font(.subheadline)
                    .fontWeight(header.isRead ? .regular : .medium)
                    .lineLimit(1)
                Spacer()
                Text(header.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !header.senderName.isEmpty {
                Text(header.senderAddress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !header.isRead || header.isLikelyTransactional {
                HStack(spacing: 6) {
                    if !header.isRead {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tint)
                    }
                    if header.isLikelyTransactional {
                        Label("Transactional", systemImage: "receipt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

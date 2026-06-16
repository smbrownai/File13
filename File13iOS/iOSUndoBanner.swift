import File13Core
import SwiftUI

/// Bottom-of-list banner that surfaces a buffered action with an Undo
/// affordance and a per-second countdown. The countdown reads from a
/// `TimelineView(.periodic:)` so we don't have to manage a Timer — the view
/// re-renders once a second and recomputes the remaining seconds against the
/// pending action's `firesAt` stamp.
///
/// When the buffer expires, `InboxStore` commits the action and clears
/// `pendingAction`. SwiftUI's transition pulls the banner away when the
/// containing optional flips back to `nil`.
struct iOSUndoBanner: View {
    let pending: InboxStore.PendingAction
    let onUndo: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = max(0, Int(pending.firesAt.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Committing in \(remaining)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Button("Undo", action: onUndo)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var title: String {
        let count = pending.messageIds.count
        let suffix = count == 1 ? "" : "s"
        let verb = pending.kind.verb.capitalized
        var base = "\(verb) \(count.formatted()) message\(suffix)"
        if pending.protectedFromDeletion > 0 {
            let p = pending.protectedFromDeletion
            base += " · \(p) protected"
        }
        return base
    }
}

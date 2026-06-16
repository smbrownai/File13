import File13Core
import Combine
import SwiftUI

struct UndoBanner: View {
    @Bindable var store: InboxStore
    @State private var now: Date = .now

    /// `@State`-stored so the publisher is created once per view identity.
    /// A plain `let` here would re-evaluate `Timer.publish(…).autoconnect()`
    /// every time SwiftUI reinitializes the struct (every parent body
    /// re-render), churning timer instances even when the banner is hidden.
    @State private var ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        if let pending = store.pendingAction {
            bar(
                title: title(for: pending),
                detail: countdownText(firesAt: pending.firesAt),
                accent: accent(for: pending.kind)
            ) {
                store.undoPendingAction()
            }
            .onReceive(ticker) { now = $0 }
        }
    }

    private func title(for action: InboxStore.PendingAction) -> String {
        let count = action.messageIds.count
        let suffix = count == 1 ? "" : "s"
        var base = "\(action.kind.label) \(count.formatted()) message\(suffix)"
        if action.protectedFromDeletion > 0 {
            let p = action.protectedFromDeletion
            base += " · \(p.formatted()) protected"
        }
        return base
    }

    private func accent(for kind: InboxStore.PendingAction.Kind) -> Color {
        switch kind {
        case .delete:  .red
        case .archive: .blue
        case .move:    .blue
        }
    }

    private func countdownText(firesAt: Date) -> String {
        let remaining = max(0, Int(firesAt.timeIntervalSince(now).rounded(.up)))
        return "Undo in \(remaining)s"
    }

    @ViewBuilder
    private func bar(title: String, detail: String?, accent: Color, undo: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
            Text(title).font(.callout)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Undo", action: undo)
                .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

import File13Core
import SwiftUI

struct UnsubscribeSheet: View {
    let candidates: [InboxStore.UnsubscribeCandidate]
    let autoRun: Bool
    /// Override for `mailto:` mechanisms. `nil` = use the system-default mail client.
    let mailClientAppURL: URL?
    /// Override for web confirmation pages. `nil` = use the system-default browser.
    let browserAppURL: URL?
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row]
    @State private var isWorking: Bool = false
    @State private var hasRun: Bool = false
    @State private var didAutoRun: Bool = false

    private let service = UnsubscribeService()

    init(
        candidates: [InboxStore.UnsubscribeCandidate],
        autoRun: Bool = false,
        mailClientAppURL: URL? = nil,
        browserAppURL: URL? = nil
    ) {
        self.candidates = candidates
        self.autoRun = autoRun
        self.mailClientAppURL = mailClientAppURL
        self.browserAppURL = browserAppURL
        _rows = State(initialValue: candidates.map { Row(candidate: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
                .padding(.bottom, 0)

            Divider()

            if rows.isEmpty {
                ContentUnavailableView(
                    "No unsubscribe links",
                    systemImage: "tray",
                    description: Text("None of the selected senders included a List-Unsubscribe header. You'll need to unsubscribe from these manually in your mail client.")
                )
                .padding(.vertical, 24)
            } else {
                List {
                    ForEach($rows) { $row in
                        RowView(row: $row)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220, maxHeight: 360)
            }

            Divider()
            HStack(spacing: 8) {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasRun {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task { await runAll() }
                    } label: {
                        if isWorking {
                            ProgressView().controlSize(.small).padding(.horizontal, 8)
                        } else {
                            Text("Unsubscribe All")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty || isWorking)
                }
            }
            .padding(12)
        }
        .frame(width: 520)
        .task {
            guard autoRun, !didAutoRun, !rows.isEmpty else { return }
            didAutoRun = true
            await runAll()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: "envelope.open")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unsubscribe").font(.title3).bold()
                Text("File13 will follow each sender's `List-Unsubscribe` link. One-click HTTPS links unsubscribe automatically. Other links open in your default browser or mail client. The senders may identify you from the URL.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String {
        if hasRun {
            let succeeded = rows.lazy.filter { row in
                if case .done = row.status { return true }
                return false
            }.count
            let opened = rows.lazy.filter { row in
                if case .opened = row.status { return true }
                return false
            }.count
            let failed = rows.lazy.filter { row in
                if case .failed = row.status { return true }
                return false
            }.count
            var parts: [String] = []
            if succeeded > 0 { parts.append("\(succeeded) succeeded") }
            if opened > 0 { parts.append("\(opened) opened externally") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.isEmpty ? "Done." : parts.joined(separator: " · ")
        }
        return "\(rows.count) sender\(rows.count == 1 ? "" : "s") with an unsubscribe link."
    }

    private func runAll() async {
        isWorking = true
        defer {
            isWorking = false
            hasRun = true
        }
        for index in rows.indices {
            guard let mechanism = rows[index].candidate.primary else {
                rows[index].status = .skipped(reason: "No mechanism")
                continue
            }
            rows[index].status = .running
            let outcome = await service.perform(
                mechanism,
                mailClientAppURL: mailClientAppURL,
                browserAppURL: browserAppURL
            )
            rows[index].status = Row.Status.from(outcome: outcome)
        }
    }
}

// MARK: - Row state

private struct Row: Identifiable {
    let candidate: InboxStore.UnsubscribeCandidate
    var status: Status = .pending
    var id: String { candidate.id }

    enum Status: Equatable {
        case pending
        case running
        case done(label: String)
        case opened
        case failed(String)
        case skipped(reason: String)

        static func from(outcome: UnsubscribeService.Outcome) -> Status {
            switch outcome {
            case .oneClickSucceeded(let code):
                return .done(label: "Unsubscribed (\(code))")
            case .oneClickServerError(let code, _):
                return .failed("Server returned \(code)")
            case .oneClickFailed(let message):
                return .failed(message)
            case .openedExternally:
                return .opened
            case .externalOpenFailed:
                return .failed("Couldn't open in another app.")
            }
        }
    }
}

private struct RowView: View {
    @Binding var row: Row

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.candidate.sender.name.isEmpty
                     ? row.candidate.sender.address
                     : row.candidate.sender.name)
                    .font(.headline)
                Text(row.candidate.sender.address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let primary = row.candidate.primary {
                    Text(primary.label)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            statusView
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusView: some View {
        switch row.status {
        case .pending:
            Text("Pending").font(.callout).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done(let label):
            Label(label, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        case .opened:
            Label("Opened", systemImage: "arrow.up.forward.app")
                .foregroundStyle(.blue)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .lineLimit(2)
        case .skipped(let reason):
            Label(reason, systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        }
    }
}

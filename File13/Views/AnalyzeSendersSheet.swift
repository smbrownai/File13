import File13Core
import SwiftUI
import Observation

/// Drives the per-sender AI triage flow. Builds rows from the top senders by volume, calls the
/// configured provider sequentially, and tracks each row's status as the user applies / skips.
@Observable
@MainActor
final class AnalyzeSendersModel {
    private let inbox: InboxStore
    private let ruleStore: RuleStore
    private let provider: any LLMProvider
    private let tuning: AIFeatureTuning
    let providerKind: AIProviderKind

    private(set) var rows: [Row]
    private(set) var isAnalyzing: Bool = false
    private(set) var providerErrorMessage: String?

    private var analysisTask: Task<Void, Never>?
    private let unsubscribeService = UnsubscribeService()

    init(inbox: InboxStore, ruleStore: RuleStore, provider: any LLMProvider, tuning: AIFeatureTuning = AIFeatureTuning(), senders: [Sender]) {
        self.inbox = inbox
        self.ruleStore = ruleStore
        self.provider = provider
        self.tuning = tuning
        self.providerKind = provider.kind
        self.rows = senders.map { Row(sender: $0) }
    }

    var totalCount: Int { rows.count }
    var analyzedCount: Int { rows.lazy.filter { $0.status == .ready || $0.status == .failed }.count }
    var appliedCount: Int { rows.lazy.filter { $0.disposition == .applied || $0.disposition == .appliedWithRule }.count }
    var skippedCount: Int { rows.lazy.filter { $0.disposition == .skipped }.count }

    func startAnalysis() {
        guard analysisTask == nil else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.runAnalysisLoop()
        }
        analysisTask = task
    }

    func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }

    private func runAnalysisLoop() async {
        isAnalyzing = true
        defer { isAnalyzing = false; analysisTask = nil }

        // Surface availability up front so we can stop early with a clear message.
        switch await provider.availability() {
        case .ready: break
        case .needsSetup(let m), .unsupported(let m), .error(let m):
            providerErrorMessage = m
            return
        }

        let advisor = SenderAdvisor(provider: provider, tuning: tuning)
        for index in rows.indices {
            if Task.isCancelled { return }
            rows[index].status = .analyzing
            let profile = rows[index].sender.makeProfile()
            do {
                let advice = try await advisor.analyze(profile)
                rows[index].advice = advice
                rows[index].status = .ready
            } catch {
                rows[index].errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                rows[index].status = .failed
            }
        }
    }

    func apply(rowId: String, alsoCreateRule: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }),
              let advice = rows[index].advice else { return }
        let sender = rows[index].sender

        switch advice.action {
        case .keep:
            break
        case .archive:
            inbox.applyAction(.archive, toSender: sender)
        case .delete:
            inbox.applyAction(.delete, toSender: sender)
        case .unsubscribe:
            // Run the unsubscribe mechanism (HTTPS one-click POST or web/mailto handoff) AND
            // archive the existing messages — the user is saying "I'm done with this sender."
            if let anchor = sender.unsubscribeAnchor,
               let mechanism = UnsubscribeParser.parse(
                   listUnsubscribe: anchor.listUnsubscribe,
                   listUnsubscribePost: anchor.listUnsubscribePost
               ).first {
                Task { _ = await unsubscribeService.perform(mechanism) }
            }
            inbox.applyAction(.archive, toSender: sender)
        }

        if alsoCreateRule, let outcome = ruleOutcome(for: advice.action) {
            let rule = Rule(
                name: "AI: \(advice.action.label) — \(sender.address)",
                enabled: true,
                conditions: Rule.Conditions(fromAddressOrDomain: sender.address.lowercased()),
                outcome: outcome
            )
            ruleStore.upsert(rule)
            rows[index].disposition = .appliedWithRule
        } else {
            rows[index].disposition = .applied
        }
    }

    func skip(rowId: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }) else { return }
        rows[index].disposition = .skipped
    }

    /// We can only persist archive/delete as rules. `keep` is a no-op; `unsubscribe` doesn't have
    /// an executable rule outcome on the server side.
    private func ruleOutcome(for action: SenderAdvice.ActionKind) -> Rule.Outcome? {
        switch action {
        case .archive: .archive
        case .delete:  .delete
        case .unsubscribe, .keep: nil
        }
    }

    struct Row: Identifiable {
        let sender: Sender
        var status: Status = .pending
        var advice: SenderAdvice?
        var errorMessage: String?
        var disposition: Disposition = .pending
        var id: String { sender.id }
    }

    enum Status: Hashable {
        case pending, analyzing, ready, failed
    }

    enum Disposition: Hashable {
        case pending, applied, appliedWithRule, skipped
    }
}

// MARK: - Sheet

struct AnalyzeSendersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AnalyzeSendersModel
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)

            // Warn the user when this feature is using a different
            // provider than the global setting — see
            // `ProviderOverrideBanner` for why this matters
            // (defense against silent provider re-routing via
            // iCloud sync or stale per-feature overrides).
            ProviderOverrideBanner(feature: .senderAdvice, settings: settings)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            if let errorMessage = model.providerErrorMessage {
                ContentUnavailableView(
                    "AI provider unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.rows) { row in
                            RowCard(row: row, model: model)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            footer
                .padding(12)
        }
        .frame(width: 720, height: 640)
        .task { model.startAnalysis() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Triage with \(model.providerKind.label)")
                    .font(.title3).bold()
                Text("File13 asks the AI to recommend an action for each top sender, based only on metadata. Apply once or convert to an ongoing rule. Nothing is committed until you click Apply.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ProgressBar(model: model)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ProgressBar: View {
    @Bindable var model: AnalyzeSendersModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isAnalyzing {
                ProgressView().controlSize(.small)
            } else if model.analyzedCount == model.totalCount {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(progressText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var progressText: String {
        if model.isAnalyzing {
            return "Analyzed \(model.analyzedCount.formatted()) of \(model.totalCount.formatted()) — \(model.appliedCount.formatted()) applied · \(model.skippedCount.formatted()) skipped"
        }
        return "Analyzed \(model.analyzedCount.formatted()) of \(model.totalCount.formatted()) — \(model.appliedCount.formatted()) applied · \(model.skippedCount.formatted()) skipped"
    }
}

private struct RowCard: View {
    let row: AnalyzeSendersModel.Row
    @Bindable var model: AnalyzeSendersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.sender.name.isEmpty ? row.sender.address : row.sender.name)
                        .font(.headline)
                    Text(row.sender.address)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(row.sender.messageCount.formatted()) messages · \(row.sender.unreadCount.formatted()) unread")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                statusGlyph
            }

            switch row.status {
            case .pending:
                Text("Queued.").font(.callout).foregroundStyle(.tertiary)
            case .analyzing:
                HStack { ProgressView().controlSize(.small); Text("Analyzing…").foregroundStyle(.secondary) }
                    .font(.callout)
            case .failed:
                Label(row.errorMessage ?? "Analysis failed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            case .ready:
                if let advice = row.advice {
                    Text(advice.summary)
                        .font(.callout)
                    Label(advice.action.label, systemImage: advice.action.symbol)
                        .foregroundStyle(advice.action.color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(advice.action.color.opacity(0.15), in: Capsule())
                        .font(.callout.weight(.semibold))
                    Text(advice.rationale)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    actions(for: advice)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch row.disposition {
        case .applied:
            Label("Applied", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.caption)
        case .appliedWithRule:
            Label("Applied + Rule", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.caption)
        case .skipped:
            Label("Skipped", systemImage: "minus.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .font(.caption)
        case .pending:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(for advice: SenderAdvice) -> some View {
        if row.disposition == .pending {
            HStack(spacing: 8) {
                Button {
                    model.apply(rowId: row.id, alsoCreateRule: false)
                } label: {
                    Label("Apply once", systemImage: advice.action.symbol)
                }
                .disabled(advice.action == .keep)

                if advice.suitableForRule, advice.action == .archive || advice.action == .delete {
                    Button {
                        model.apply(rowId: row.id, alsoCreateRule: true)
                    } label: {
                        Label("Apply + Rule", systemImage: "wand.and.stars")
                    }
                }

                Button {
                    model.skip(rowId: row.id)
                } label: {
                    Text("Skip")
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
    }
}

import File13Core
import Charts
import SwiftUI

/// Inbox activity dashboard. Surfaces volume, engagement, mail-shape, and standout senders
/// drawn from `InboxStore.activityReport` (cached aggregate over the current scope).
struct ActivityView: View {
    @Bindable var store: InboxStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var settings: SettingsStore
    @Bindable var ruleStore: RuleStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore

    @State private var categorizationProgress: CategorizationProgress = .idle
    @State private var categorizationError: String?
    /// Monotonic token. The progress callback writes only when its captured generation matches
    /// the current one, so trailing callbacks from a prior run can't resurrect the spinner.
    @State private var categorizationGeneration: Int = 0
    /// When non-nil, the per-sender suggestions sheet is presented for this sender.
    @State private var senderForSuggestions: Sender?
    @State private var isDetectingReplies: Bool = false
    @State private var replyDetectionError: String?
    @State private var isRunningCategoryRules: Bool = false
    @State private var categoryRunReport: RuleRunReport?
    @State private var categoryRunError: String?
    /// When non-nil, the whole dashboard re-scopes to senders in this category — charts,
    /// shape breakdown, and the senders grid all reflect just that slice. Nil means "all".
    @State private var categoryFilter: SenderCategory?

    var body: some View {
        let baseReport = store.activityReport
        let report = displayedReport(baseReport: baseReport)
        VStack(spacing: 0) {
            // Visual drag-handle affordance for the VSplitView divider above.
            // The actual hit area is the AppKit divider; this pill is purely a
            // hint that the panel is resizable.
            DragHandlePill()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if baseReport.isEmpty {
                        emptyState
                    } else {
                        if !categoryStore.categories.isEmpty {
                            categoryFilterStrip(baseReport: baseReport)
                            categoryRunBar()
                        }
                        summaryRow(report)
                        volumeCard(report)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            weekdayCard(report)
                            hourCard(report)
                        }
                        shapeCard(report)
                        categoryCard(baseReport)
                        replyCard(report)
                        vipCard(report)
                        sendersGrid(report)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("AI categorization failed",
               isPresented: Binding(get: { categorizationError != nil },
                                    set: { if !$0 { categorizationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(categorizationError ?? "")
        }
        .sheet(item: $senderForSuggestions) { sender in
            SuggestionsSheet(
                sender: sender,
                ruleStore: ruleStore,
                inbox: store,
                settings: settings,
                categoryStore: categoryStore,
                suggestionDismissals: suggestionDismissals,
                vipStore: vipStore
            )
        }
    }

    // MARK: - Filter strip

    /// Build a category-scoped report by filtering `store.allHeaders` to senders in the
    /// selected category. Computing fresh on filter change is cheap (one O(N) pass) and
    /// avoids a second cache layer.
    private func displayedReport(baseReport: ActivityReport) -> ActivityReport {
        guard let filter = categoryFilter else { return baseReport }
        let map = categoryStore.categories
        let senderIdsInCategory: Set<String> = Set(
            map.compactMap { (key, value) in value == filter ? key : nil }
        )
        guard !senderIdsInCategory.isEmpty else { return .empty }
        let filtered = store.allHeaders.filter { senderIdsInCategory.contains($0.senderAddress.lowercased()) }
        return ActivityReport.compute(from: filtered)
    }

    @ViewBuilder
    private func categoryFilterStrip(baseReport: ActivityReport) -> some View {
        // Only show categories the user actually has data for, plus an "All" pill.
        let senderCounts = senderCountByCategory()
        let presentCategories = SenderCategory.allCases.filter { (senderCounts[$0] ?? 0) > 0 }
        if presentCategories.isEmpty { EmptyView() } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterPill(
                        label: "All",
                        symbol: nil,
                        color: .secondary,
                        count: baseReport.uniqueSenders,
                        isSelected: categoryFilter == nil
                    ) { categoryFilter = nil }
                    ForEach(presentCategories) { category in
                        FilterPill(
                            label: category.label,
                            symbol: category.symbol,
                            color: category.color,
                            count: senderCounts[category] ?? 0,
                            isSelected: categoryFilter == category
                        ) {
                            categoryFilter = (categoryFilter == category) ? nil : category
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func senderCountByCategory() -> [SenderCategory: Int] {
        let map = categoryStore.categories
        var counts: [SenderCategory: Int] = [:]
        for sender in store.senders {
            if let category = map[sender.id] {
                counts[category, default: 0] += 1
            }
        }
        return counts
    }

    /// Action row that appears under the filter strip whenever the user has scoped to a
    /// category and at least one enabled rule targets it. Lets the user fire those rules in
    /// place without leaving the activity dashboard for the Rules tab.
    @ViewBuilder
    private func categoryRunBar() -> some View {
        if let category = categoryFilter {
            let matching = matchingRules(for: category)
            if !matching.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        Task { await runCategoryRules(matching) }
                    } label: {
                        if isRunningCategoryRules {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Running…")
                            }
                        } else {
                            Label(
                                "Run \(matching.count) \(category.label) rule\(matching.count == 1 ? "" : "s")",
                                systemImage: "play.circle"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningCategoryRules || store.connectedAccount == nil)
                    .help("Run only the enabled rules whose `category` condition matches \(category.label). Same engine as the Rules tab — just scoped to the active filter.")

                    if let report = categoryRunReport {
                        Text(categoryRunSummary(report))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let error = categoryRunError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func matchingRules(for category: SenderCategory) -> [Rule] {
        ruleStore.rules.filter {
            $0.enabled && $0.conditions.category == category
        }
    }

    private func categoryRunSummary(_ report: RuleRunReport) -> String {
        if let reason = report.skipReason { return "Skipped: \(reason)" }
        if report.actions.isEmpty { return "No matches." }
        return "Affected \(report.totalAffected.formatted()) message\(report.totalAffected == 1 ? "" : "s")."
    }

    @MainActor
    private func runCategoryRules(_ rules: [Rule]) async {
        isRunningCategoryRules = true
        categoryRunReport = nil
        categoryRunError = nil
        defer { isRunningCategoryRules = false }
        let report = await store.runRules(rules)
        ruleStore.recordRun(report)
        categoryRunReport = report
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No activity yet",
            systemImage: "chart.bar.xaxis",
            description: Text("Connect an account and let File13 fetch some headers. Your inbox stats will appear here.")
        )
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - Summary tiles

    private func summaryRow(_ report: ActivityReport) -> some View {
        HStack(spacing: 12) {
            SummaryTile(
                label: "Messages",
                value: report.totalMessages.formatted(),
                subtitle: dateRangeSubtitle(report)
            )
            SummaryTile(
                label: "Read",
                value: percent(report.readRate),
                subtitle: "\(report.readMessages.formatted()) of \(report.totalMessages.formatted())"
            )
            SummaryTile(
                label: "Unique senders",
                value: report.uniqueSenders.formatted(),
                subtitle: averageSubtitle(report)
            )
            SummaryTile(
                label: "Newsletters / lists",
                value: percent(broadcastShare(report)),
                subtitle: "\(report.broadcastCount.formatted()) messages"
            )
        }
    }

    private func dateRangeSubtitle(_ report: ActivityReport) -> String? {
        guard let range = report.dateRange else { return nil }
        let f = Self.dateRangeFormatter
        return "\(f.string(from: range.lowerBound)) – \(f.string(from: range.upperBound))"
    }

    /// Shared per-process DateFormatter. Instantiating a fresh
    /// `DateFormatter` on every body re-eval threads the user locale
    /// each time and is one of the slower operations Foundation
    /// exposes; once is enough.
    private static let dateRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// 0..23 → "1 AM" / "11 PM" labels, cached at first read. The hour
    /// axis ticks paint 24 labels per chart per render; calling
    /// `Calendar.current.date(from:)` + `.formatted(...)` for each was
    /// quietly the slowest path inside Activity's chart cards.
    private static let hourLabels: [String] = {
        let cal = Calendar.current
        var labels: [String] = []
        labels.reserveCapacity(24)
        for hour in 0..<24 {
            var components = DateComponents(); components.hour = hour
            let date = cal.date(from: components) ?? .now
            labels.append(date.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow))))
        }
        return labels
    }()

    private func averageSubtitle(_ report: ActivityReport) -> String? {
        guard report.uniqueSenders > 0 else { return nil }
        let avg = Double(report.totalMessages) / Double(report.uniqueSenders)
        return String(format: "%.1f msgs / sender avg", avg)
    }

    private func broadcastShare(_ report: ActivityReport) -> Double {
        guard report.totalMessages > 0 else { return 0 }
        return Double(report.broadcastCount) / Double(report.totalMessages)
    }

    private func percent(_ value: Double) -> String {
        let pct = (value * 100).rounded()
        return "\(Int(pct))%"
    }

    /// Per-card chart color. In `Colorful` palette mode we walk through the
    /// 6-color Apple-logo cycle (green, yellow, orange, …) so each chart gets
    /// its own hue; in `App` palette mode we keep every chart on the primary
    /// `AccentColor` since there are only two palette colors and one
    /// (SecondaryAccent) is already in use as the muted "Unread" series on
    /// the volume chart. That keeps the App-mode look monochromatic-on-
    /// purpose without exposing arbitrary index-cycling.
    private func chartColor(at index: Int) -> Color {
        switch settings.accentPalette {
        case .colorful: settings.accentPalette.color(at: index)
        case .app:      settings.accentPalette.primary
        }
    }

    // MARK: - Volume chart (last 30 days)

    private func volumeCard(_ report: ActivityReport) -> some View {
        Card(title: "Volume — last 30 days", subtitle: "Daily message count, with read share highlighted.") {
            Chart {
                ForEach(report.volumeByDay) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Read", day.readCount)
                    )
                    .foregroundStyle(by: .value("Status", "Read"))
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Unread", day.count - day.readCount)
                    )
                    .foregroundStyle(by: .value("Status", "Unread"))
                }
            }
            .chartForegroundStyleScale([
                "Read":   chartColor(at: 0),
                // App mode pulls in SecondaryAccent so the user actually sees
                // the second palette color somewhere prominent. Colorful mode
                // stays muted-gray so the bars don't compete with each other.
                "Unread": settings.accentPalette == .app
                    ? Color("SecondaryAccent", bundle: .main).opacity(0.7)
                    : Color.secondary.opacity(0.4)
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 220)
        }
    }

    // MARK: - Weekday + hour cards

    private func weekdayCard(_ report: ActivityReport) -> some View {
        Card(title: "By weekday", subtitle: nil) {
            Chart(report.volumeByWeekday) { bucket in
                BarMark(
                    x: .value("Weekday", weekdaySymbol(bucket.weekday)),
                    y: .value("Messages", bucket.count)
                )
                .foregroundStyle(chartColor(at: 1).gradient)
            }
            .frame(height: 160)
        }
    }

    private func hourCard(_ report: ActivityReport) -> some View {
        Card(title: "By hour of day", subtitle: nil) {
            Chart(report.volumeByHour) { bucket in
                BarMark(
                    x: .value("Hour", bucket.hour),
                    y: .value("Messages", bucket.count)
                )
                .foregroundStyle(chartColor(at: 2).gradient)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine()
                    if let hour = value.as(Int.self) {
                        AxisValueLabel(formatHour(hour))
                    }
                }
            }
            .frame(height: 160)
        }
    }

    private func weekdaySymbol(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let index = (weekday - 1).clamped(to: 0..<symbols.count)
        return symbols[index]
    }

    private func formatHour(_ hour: Int) -> String {
        let clamped = max(0, min(23, hour))
        return Self.hourLabels[clamped]
    }

    // MARK: - Mail-shape breakdown

    private func shapeCard(_ report: ActivityReport) -> some View {
        let segments: [ShapeSegment] = [
            .init(label: "Personal",       count: report.personalCount,      color: .green),
            .init(label: "Newsletters",    count: report.broadcastCount,     color: .blue),
            .init(label: "Transactional",  count: report.transactionalCount, color: .orange),
            .init(label: "Other",          count: report.otherCount,         color: .gray)
        ].filter { $0.count > 0 }

        return Card(
            title: "Mail shape",
            subtitle: "Heuristic split based on List-Unsubscribe / List-ID, recipient count, and subject patterns."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if segments.isEmpty {
                    Text("No mail to classify yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    StackedBar(segments: segments, total: report.totalMessages)
                    HStack(spacing: 16) {
                        ForEach(segments) { segment in
                            HStack(spacing: 6) {
                                Circle().fill(segment.color).frame(width: 8, height: 8)
                                Text("\(segment.label) · \(segment.count.formatted())")
                                    .font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct ShapeSegment: Identifiable {
        let label: String
        let count: Int
        let color: Color
        var id: String { label }
    }

    // MARK: - AI category breakdown

    private func categoryCard(_ report: ActivityReport) -> some View {
        Card(
            title: "AI categories",
            subtitle: "Senders grouped by File13's AI provider — banking, shopping, news, etc."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                categoryStatusLine(report)
                if let buckets = categoryBuckets(report) {
                    StackedBar(
                        segments: buckets.map { ShapeSegment(label: $0.category.label, count: $0.count, color: $0.category.color) },
                        total: buckets.reduce(0) { $0 + $1.count }
                    )
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(buckets, id: \.category) { bucket in
                            HStack(spacing: 6) {
                                Image(systemName: bucket.category.symbol)
                                    .foregroundStyle(bucket.category.color)
                                    .frame(width: 14)
                                Text(bucket.category.label)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(bucket.count.formatted())
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                categorizeButton(report)
            }
        }
    }

    @ViewBuilder
    private func categoryStatusLine(_ report: ActivityReport) -> some View {
        let categorized = categorizedSenderCount(in: report)
        let totalSenders = report.uniqueSenders
        switch categorizationProgress {
        case .running(let completed, let batchTotal):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Categorizing \(completed)/\(batchTotal)…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .idle:
            if categorized == 0 {
                Text("No senders categorized yet — run the AI to label \(totalSenders.formatted()) senders.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastRun = categoryStore.lastRunAt {
                Text("Last run \(lastRun.formatted(.relative(presentation: .numeric))) — \(categorized.formatted()) of \(totalSenders.formatted()) senders categorized.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(categorized.formatted()) of \(totalSenders.formatted()) senders categorized.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func categorizeButton(_ report: ActivityReport) -> some View {
        let uncategorizedIds = categoryStore.uncategorized(amongSenderIds: store.senders.map(\.id))
        let hasNewSenders = !uncategorizedIds.isEmpty
        let hasExistingCategorizations = !categoryStore.categories.isEmpty

        HStack(spacing: 8) {
            // Primary action is always the *incremental* path — fire only on senders we haven't
            // categorized yet. Disabled (with explanatory label) when there's nothing new.
            Button {
                Task { await runCategorization(force: false) }
            } label: {
                Label(
                    hasNewSenders
                        ? "Categorize \(uncategorizedIds.count.formatted()) new sender\(uncategorizedIds.count == 1 ? "" : "s")"
                        : "All senders categorized",
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCategorizationRunning || !hasNewSenders)
            .help("Run AI categorization only on senders that haven't been categorized yet — much faster than starting from scratch.")

            // Re-categorize-all is a separate, explicit action so users don't trigger a long
            // run by accident. Only shown when there's prior data to throw away.
            if hasExistingCategorizations {
                Button {
                    Task { await runCategorization(force: true) }
                } label: {
                    Label("Re-categorize all", systemImage: "arrow.clockwise")
                }
                .disabled(isCategorizationRunning)
                .help("Discard existing categorizations and re-run the AI over every sender.")
            }
            Spacer()
        }
    }

    private var isCategorizationRunning: Bool {
        if case .running = categorizationProgress { return true }
        return false
    }

    // MARK: - Reply activity

    private func replyCard(_ report: ActivityReport) -> some View {
        Card(
            title: "Reply activity",
            subtitle: "Senders you actually reply to. Strongest engagement signal we can compute, much sharper than read rate."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                replyStatusLine(report)
                if !report.topRepliedSenders.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(report.topRepliedSenders) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.displayName.isEmpty ? row.address : row.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(row.repliedCount.formatted()) repl\(row.repliedCount == 1 ? "y" : "ies") · \(Int((row.replyRate * 100).rounded()))%")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = replyDetectionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .lineLimit(3, reservesSpace: false)
                }
                replyDetectButton(report)
            }
        }
    }

    @ViewBuilder
    private func replyStatusLine(_ report: ActivityReport) -> some View {
        if isDetectingReplies {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning Sent folder…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if report.totalRepliedToCount == 0 {
            Text("Reply detection hasn't run yet. File13 will scan your Sent folder and match In-Reply-To headers against your inbox.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(report.totalRepliedToCount.formatted()) message\(report.totalRepliedToCount == 1 ? "" : "s") in your inbox have a reply in your Sent folder.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func replyDetectButton(_ report: ActivityReport) -> some View {
        HStack {
            Button {
                Task { await runReplyDetection() }
            } label: {
                Label(
                    report.totalRepliedToCount == 0 ? "Detect replies" : "Refresh reply data",
                    systemImage: "arrowshape.turn.up.left"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDetectingReplies || store.sessions.isEmpty)
            .help("Scans your Sent folder for In-Reply-To headers. Heavier than a normal sync — runs only when you ask.")
            Spacer()
        }
    }

    @MainActor
    private func runReplyDetection() async {
        isDetectingReplies = true
        replyDetectionError = nil
        defer { isDetectingReplies = false }
        await store.refreshAllSentReplies()
        if store.repliedMessageIds.isEmpty {
            // No replies discovered — usually because no Sent mailbox was identified or it's
            // empty. Surface a soft message rather than failing silently.
            replyDetectionError = "Couldn't find any replies. Either the Sent folder isn't identified on this account, or it's empty."
        }
    }

    // MARK: - VIPs

    private func vipCard(_ report: ActivityReport) -> some View {
        let effective = vipStore.effective
        let visibleSenders = vipSendersForDisplay(effective: effective)
        return Card(
            title: "VIP senders",
            subtitle: "Senders you actually engage with — high read rate, frequent replies. Useful for spotting who you'd never want a rule to act on."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                vipStatusLine(effectiveCount: effective.count)
                if !visibleSenders.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(visibleSenders) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                                    .frame(width: 12)
                                Text(row.displayName.isEmpty ? row.address : row.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                if vipStore.pinned.contains(row.address.lowercased()),
                                   !vipStore.autoDetected.contains(row.address.lowercased()) {
                                    Text("Pinned")
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.yellow.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(vipMetricLabel(row))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Button {
                                    vipStore.unpin(senderId: row.address)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from VIPs")
                            }
                        }
                    }
                }
                vipDetectButton()
            }
        }
    }

    @ViewBuilder
    private func vipStatusLine(effectiveCount: Int) -> some View {
        if effectiveCount == 0 {
            if vipStore.lastDetectionAt == nil {
                Text("Run detection to surface senders you actually engage with. Reply data sharpens the result, but isn't required.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No VIPs found at the current thresholds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let lastRun = vipStore.lastDetectionAt {
            Text("\(effectiveCount.formatted()) VIP\(effectiveCount == 1 ? "" : "s") · last detected \(lastRun.formatted(.relative(presentation: .numeric))).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(effectiveCount.formatted()) VIP\(effectiveCount == 1 ? "" : "s").")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func vipDetectButton() -> some View {
        HStack {
            Button {
                runVIPDetection()
            } label: {
                Label(
                    vipStore.lastDetectionAt == nil ? "Detect VIPs" : "Re-detect VIPs",
                    systemImage: "star"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.senders.isEmpty)
            .help("Mark senders you've replied to ≥ 2× or read ≥ 90% of as VIPs. Replays of pin/unpin are preserved.")
            Spacer()
        }
    }

    /// Resolve the effective VIP id set into displayable rows. Cap at the same length as the
    /// other top-N cards so the dashboard stays scannable.
    private func vipSendersForDisplay(effective: Set<String>) -> [ActivityReport.SenderStat] {
        let lookup = effective
        let report = store.activityReport
        // Build a single dictionary from address → SenderStat by walking each existing list.
        var statById: [String: ActivityReport.SenderStat] = [:]
        let pools: [[ActivityReport.SenderStat]] = [
            report.topSendersByVolume, report.topSendersByReadRate,
            report.topRepliedSenders, report.ghostSenders, report.dormantSenders
        ]
        for pool in pools {
            for stat in pool { statById[stat.address.lowercased()] = stat }
        }
        // Also include any VIPs that don't appear in the existing top-lists by reaching back
        // to the live `Sender` set.
        for id in lookup where statById[id] == nil {
            if let sender = store.sender(byId: id) {
                statById[id] = ActivityReport.SenderStat(
                    address: sender.address,
                    displayName: sender.name.isEmpty ? sender.address : sender.name,
                    messageCount: sender.messageCount,
                    readCount: sender.messageCount - sender.unreadCount,
                    mostRecent: sender.mostRecent,
                    repliedCount: sender.messages.lazy.filter {
                        store.repliedMessageIds.contains($0.rawMessageId)
                    }.count
                )
            }
        }
        return lookup
            .compactMap { statById[$0] }
            .sorted { lhs, rhs in
                if lhs.repliedCount != rhs.repliedCount { return lhs.repliedCount > rhs.repliedCount }
                if lhs.readRate != rhs.readRate { return lhs.readRate > rhs.readRate }
                return lhs.messageCount > rhs.messageCount
            }
            .prefix(10)
            .map { $0 }
    }

    private func vipMetricLabel(_ row: ActivityReport.SenderStat) -> String {
        var parts: [String] = []
        if row.repliedCount > 0 {
            parts.append("\(row.repliedCount.formatted()) repl\(row.repliedCount == 1 ? "y" : "ies")")
        }
        let readPct = Int((row.readRate * 100).rounded())
        parts.append("\(readPct)% read")
        parts.append("\(row.messageCount.formatted()) msgs")
        return parts.joined(separator: " · ")
    }

    private func runVIPDetection() {
        let detected = VIPDetector.detect(
            senders: store.senders,
            repliedMessageIds: store.repliedMessageIds,
            categoryFor: { categoryStore.category(for: $0) }
        )
        vipStore.updateAutoDetected(detected)
    }

    private struct CategoryBucket {
        let category: SenderCategory
        let count: Int
    }

    /// Group senders by their cached category and total their message counts. Senders without
    /// a category are excluded — they show up under the "Categorize" CTA instead.
    private func categoryBuckets(_ report: ActivityReport) -> [CategoryBucket]? {
        let map = categoryStore.categories
        guard !map.isEmpty else { return nil }
        var byCategory: [SenderCategory: Int] = [:]
        for sender in store.senders {
            guard let category = map[sender.id] else { continue }
            byCategory[category, default: 0] += sender.messageCount
        }
        guard !byCategory.isEmpty else { return nil }
        return byCategory
            .map { CategoryBucket(category: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func categorizedSenderCount(in report: ActivityReport) -> Int {
        let map = categoryStore.categories
        return store.senders.reduce(into: 0) { count, sender in
            if map[sender.id] != nil { count += 1 }
        }
    }

    enum CategorizationProgress: Equatable {
        case idle
        case running(completed: Int, total: Int)
    }

    @MainActor
    private func runCategorization(force: Bool) async {
        let allIds = store.senders.map(\.id)
        let targetIds = force ? Set(allIds) : Set(categoryStore.uncategorized(amongSenderIds: allIds))
        let targets = store.senders.filter { targetIds.contains($0.id) }
        guard !targets.isEmpty else { return }

        let provider = LLMProviderFactory.make(for: .senderCategorize, settings: settings)
        let categorizer = SenderCategorizer(provider: provider, tuning: settings.tuning(for: .senderCategorize))

        // Each run gets a unique generation token. Progress callbacks check against the
        // current generation before writing — that way if a Task lingers past the user
        // starting a new run (or the View tearing down and being remade), stale callbacks
        // can't resurrect the spinner.
        categorizationGeneration &+= 1
        let myGeneration = categorizationGeneration
        categorizationProgress = .running(completed: 0, total: targets.count)

        // Defer the reset so it always fires — including if an `await` is cancelled and
        // unwinds the function. The generation guard makes sure only the *latest* run is
        // allowed to clear the spinner, so concurrent runs can't clobber each other's UI.
        defer {
            if categorizationGeneration == myGeneration {
                categorizationProgress = .idle
            }
        }

        do {
            let (results, errors) = try await categorizer.categorize(targets) { completed, total in
                guard categorizationGeneration == myGeneration else { return }
                categorizationProgress = .running(completed: completed, total: total)
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
            categorizationError = error.localizedDescription
        }
    }

    private struct StackedBar: View {
        let segments: [ShapeSegment]
        let total: Int

        /// Inter-segment gutter. The HStack draws this between every pair, so
        /// the bar's natural width is (sum of segment widths) + (n-1) ·
        /// `spacing`. We have to subtract the gutters from the usable pool
        /// before slicing widths proportionally, or the bar overflows its
        /// container — which is what was pushing the AI-categories chart
        /// past the right edge when there were a lot of categories.
        private static let spacing: CGFloat = 2

        var body: some View {
            GeometryReader { geo in
                let gutters = CGFloat(max(0, segments.count - 1)) * Self.spacing
                let usable = max(0, geo.size.width - gutters)
                HStack(spacing: Self.spacing) {
                    ForEach(segments) { segment in
                        // No minimum-width clamp here — `max(2, …)` would
                        // inflate every tiny segment to 2pt, and with N
                        // segments that adds up to more than the
                        // data-proportional total, pushing the bar past
                        // its container. Truly negligible segments rendering
                        // as 0pt is the right behavior; the legend below
                        // still names them with counts.
                        let width = total > 0
                            ? usable * CGFloat(segment.count) / CGFloat(total)
                            : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.color)
                            .frame(width: max(0, width))
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
        }
    }

    // MARK: - Sender highlights

    private func sendersGrid(_ report: ActivityReport) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 16, alignment: .top),
            GridItem(.flexible(), spacing: 16, alignment: .top)
        ]
        let onSuggest: (ActivityReport.SenderStat) -> Void = { stat in
            // Look up the live `Sender` so the sheet has full message context — the report's
            // `SenderStat` is a stripped-down summary.
            senderForSuggestions = store.sender(byId: stat.address.lowercased())
        }
        return LazyVGrid(columns: columns, spacing: 16) {
            SenderListCard(
                title: "Top senders by volume",
                subtitle: "Where most of your mail comes from.",
                empty: "No senders.",
                rows: report.topSendersByVolume,
                metric: .count,
                categoryStore: categoryStore,
                vipStore: vipStore,
                onSuggest: onSuggest
            )
            SenderListCard(
                title: "Most engaged",
                subtitle: "Senders you actually open (≥ 5 msgs).",
                empty: "Need a few more reads to compute this.",
                rows: report.topSendersByReadRate,
                metric: .readRate,
                categoryStore: categoryStore,
                vipStore: vipStore,
                onSuggest: onSuggest
            )
            SenderListCard(
                title: "Ghost senders",
                subtitle: "High volume, almost never opened — unsubscribe candidates.",
                empty: "No ghost senders. Nice.",
                rows: report.ghostSenders,
                metric: .ghostScore,
                categoryStore: categoryStore,
                vipStore: vipStore,
                onSuggest: onSuggest
            )
            SenderListCard(
                title: "Dormant senders",
                subtitle: "Last sent more than 90 days ago.",
                empty: "No dormant senders.",
                rows: report.dormantSenders,
                metric: .lastSeen,
                categoryStore: categoryStore,
                vipStore: vipStore,
                onSuggest: onSuggest
            )
        }
    }
}

// MARK: - Reusable card chrome

/// Solid card background. Materials (`.background.secondary` etc.) sample what's behind them
/// and ghost during rapid resize because the sample rate doesn't match the layout rate. A flat
/// `Color` paints atomically with the rest of the layer.
private let cardFillColor = Color(nsColor: .controlBackgroundColor)

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardFillColor))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }
}

private struct SummaryTile: View {
    let label: String
    let value: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardFillColor))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }
}

private struct SenderListCard: View {
    enum Metric { case count, readRate, ghostScore, lastSeen }

    /// Same rationale as `ActivityView.dateRangeFormatter`: allocating a
    /// fresh `RelativeDateTimeFormatter` per row (when `metric == .lastSeen`)
    /// showed up under instruments as the slowest path inside the senders
    /// grid. `localizedString(for:relativeTo:)` is stateless once the
    /// formatter is configured, so a single shared instance is fine.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    let title: String
    let subtitle: String
    let empty: String
    let rows: [ActivityReport.SenderStat]
    let metric: Metric
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var vipStore: VIPStore
    /// Closure into `ActivityView` that opens the per-sender suggestions sheet. Lifted up so
    /// only one sheet ever lives in the activity tree.
    let onSuggest: (ActivityReport.SenderStat) -> Void

    var body: some View {
        Card(title: title, subtitle: subtitle) {
            if rows.isEmpty {
                Text(empty)
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    if vipStore.isVIP(senderId: row.address) {
                                        VIPChip()
                                    }
                                    if let category = categoryStore.category(for: row.address) {
                                        CategoryChip(category: category)
                                    }
                                    Text(row.displayName.isEmpty ? row.address : row.displayName)
                                        .font(.callout)
                                        .lineLimit(1)
                                }
                                if !row.displayName.isEmpty, row.displayName != row.address {
                                    Text(row.address)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(metricLabel(row))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                onSuggest(row)
                            } label: {
                                Label("Suggest rules with AI…", systemImage: "sparkles")
                            }
                            Divider()
                            vipToggle(for: row)
                            categoryMenu(for: row)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func vipToggle(for row: ActivityReport.SenderStat) -> some View {
        let isVIP = vipStore.isVIP(senderId: row.address)
        Button {
            if isVIP {
                vipStore.unpin(senderId: row.address)
            } else {
                vipStore.pin(senderId: row.address)
            }
        } label: {
            Label(isVIP ? "Remove from VIPs" : "Pin as VIP",
                  systemImage: isVIP ? "star.slash" : "star")
        }
    }

    @ViewBuilder
    private func categoryMenu(for row: ActivityReport.SenderStat) -> some View {
        let current = categoryStore.category(for: row.address)
        Menu("Set category") {
            ForEach(SenderCategory.allCases) { category in
                Button {
                    categoryStore.set(category, for: row.address)
                } label: {
                    if category == current {
                        Label(category.label, systemImage: "checkmark")
                    } else {
                        Label(category.label, systemImage: category.symbol)
                    }
                }
            }
        }
        if current != nil {
            Divider()
            Button("Clear category") {
                categoryStore.clear(senderId: row.address)
            }
        }
    }

    private func metricLabel(_ row: ActivityReport.SenderStat) -> String {
        switch metric {
        case .count:
            return "\(row.messageCount.formatted())"
        case .readRate:
            return "\(Int((row.readRate * 100).rounded()))% · \(row.messageCount.formatted())"
        case .ghostScore:
            return "\(Int((row.readRate * 100).rounded()))% read · \(row.messageCount.formatted())"
        case .lastSeen:
            return "\(Self.relativeFormatter.localizedString(for: row.mostRecent, relativeTo: .now)) · \(row.messageCount.formatted())"
        }
    }
}

private extension Comparable {
    func clamped(to range: Range<Int>) -> Int where Self == Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound - 1, self))
    }
}

/// Small icon-only badge used inline with sender names in the activity-dashboard sender lists.
/// Tooltip surfaces the category label so the icon never has to stand alone in interpretation.
private struct CategoryChip: View {
    let category: SenderCategory

    var body: some View {
        Image(systemName: category.symbol)
            .font(.caption2)
            .foregroundStyle(category.color)
            .frame(width: 14, height: 14)
            .help(category.label)
    }
}

/// Yellow star next to senders the user has marked (or auto-detected) as VIPs. Distinct from
/// the category chip so a sender can be both — e.g. a "personal" sender who's also pinned VIP.
private struct VIPChip: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.caption2)
            .foregroundStyle(.yellow)
            .frame(width: 14, height: 14)
            .help("VIP — high engagement.")
    }
}

/// Tappable pill in the activity dashboard's category filter strip. Selected state uses the
/// category color as the background fill so the active filter is visually obvious.
private struct FilterPill: View {
    let label: String
    let symbol: String?
    let color: Color
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption2)
                }
                Text(label)
                    .font(.callout)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(count.formatted())
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? color.opacity(0.22) : Color.clear)
            )
            .overlay(
                Capsule().stroke(isSelected ? color : Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? color : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// Small horizontal pill that sits at the top of the activity drawer to
/// signal the panel is resizable. The actual drag affordance comes from the
/// VSplitView divider that AppKit renders just above this view; the pill is
/// purely a visual hint, à la iOS sheet handles.
private struct DragHandlePill: View {
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(isHovering ? 0.55 : 0.35))
                .frame(width: 36, height: 4)
                .padding(.vertical, 4)
                .help("Drag the divider above to resize the activity panel.")
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onHover { isHovering = $0 }
    }
}

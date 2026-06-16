import File13Core
import SwiftUI

struct RuleBuilderSheet: View {
    @Bindable var ruleStore: RuleStore
    @Bindable var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Rule

    @State private var olderThanEnabled: Bool
    @State private var olderThanDays: Int

    @State private var outcomeKind: OutcomeKind
    @State private var moveDestination: String

    @State private var scopeKind: ScopeKind
    @State private var scopeFolder: String

    private let isEditing: Bool

    init(ruleStore: RuleStore, inbox: InboxStore, initial: Rule, isEditing: Bool = false) {
        self.ruleStore = ruleStore
        self.inbox = inbox
        _draft = State(initialValue: initial)
        _olderThanEnabled = State(initialValue: initial.conditions.olderThanDays != nil)
        _olderThanDays = State(initialValue: initial.conditions.olderThanDays ?? 30)
        let kind = OutcomeKind(initial.outcome)
        _outcomeKind = State(initialValue: kind)
        if case .moveToFolder(let dest) = initial.outcome {
            _moveDestination = State(initialValue: dest)
        } else {
            _moveDestination = State(initialValue: "")
        }
        let scope = initial.effectiveScope
        _scopeKind = State(initialValue: ScopeKind(scope))
        if case .folder(let name) = scope {
            _scopeFolder = State(initialValue: name)
        } else {
            _scopeFolder = State(initialValue: "")
        }
        self.isEditing = isEditing
    }

    private enum ReadStateChoice: String, CaseIterable, Identifiable {
        case any, unread, read
        var id: String { rawValue }
        var label: String {
            switch self { case .any: "Any"; case .unread: "Unread only"; case .read: "Read only" }
        }
    }

    /// Three-state picker for the `senderDomainIsDisposable` condition. Maps to the
    /// optional `Bool?` on `Rule.Conditions`: nil = ignore, true = disposable only,
    /// false = non-disposable only.
    private enum DisposableDomainChoice: String, CaseIterable, Identifiable {
        case any, disposable, notDisposable
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any:           "Any"
            case .disposable:    "Disposable only"
            case .notDisposable: "Not disposable"
            }
        }
        var value: Bool? {
            switch self {
            case .any:           nil
            case .disposable:    true
            case .notDisposable: false
            }
        }
        static func from(_ value: Bool?) -> DisposableDomainChoice {
            switch value {
            case .none:        .any
            case .some(true):  .disposable
            case .some(false): .notDisposable
            }
        }
    }

    private enum ScopeKind: String, CaseIterable, Identifiable {
        case currentMailbox, folder, allFolders
        var id: String { rawValue }
        var label: String {
            switch self {
            case .currentMailbox: "Current mailbox"
            case .folder:         "Specific folder"
            case .allFolders:     "All folders"
            }
        }
        init(_ scope: RuleScope) {
            switch scope {
            case .currentMailbox: self = .currentMailbox
            case .folder:         self = .folder
            case .allFolders:     self = .allFolders
            }
        }
    }

    private enum OutcomeKind: String, CaseIterable, Identifiable {
        case delete, archive, moveToFolder, unsubscribe
        var id: String { rawValue }
        var label: String {
            switch self {
            case .delete: "Delete"
            case .archive: "Archive"
            case .moveToFolder: "Move to Folder"
            case .unsubscribe: "Unsubscribe"
            }
        }
        init(_ outcome: Rule.Outcome) {
            switch outcome {
            case .delete: self = .delete
            case .archive: self = .archive
            case .moveToFolder: self = .moveToFolder
            case .unsubscribe: self = .unsubscribe
            }
        }
    }

    private var canSubmit: Bool {
        !resolvedConditions().isEmpty && resolvedOutcome() != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit rule" : "New rule").font(.title3).bold()
                    Text("Rules run against the currently active mailbox when you click Run, and run on app open if enabled.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .padding(.bottom, 0)

            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. \"LinkedIn cleanup\""))
                    Toggle("Enabled", isOn: $draft.enabled)
                } header: { Text("Rule").font(.headline) }

                Section {
                    LabeledContent("From") {
                        TextField("", text: Binding(
                            get: { draft.conditions.fromAddressOrDomain ?? "" },
                            set: { draft.conditions.fromAddressOrDomain = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    LabeledContent("Subject contains") {
                        TextField("", text: Binding(
                            get: { draft.conditions.subjectContains ?? "" },
                            set: { draft.conditions.subjectContains = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    Toggle("Older than", isOn: $olderThanEnabled)
                    if olderThanEnabled {
                        Stepper(value: $olderThanDays, in: 1...3650) {
                            Text("\(olderThanDays) day\(olderThanDays == 1 ? "" : "s")")
                                .monospacedDigit()
                        }
                    }
                    Picker("Read state", selection: Binding(
                        get: {
                            if let v = draft.conditions.isUnread { return v ? ReadStateChoice.unread : .read }
                            return ReadStateChoice.any
                        },
                        set: { newValue in
                            switch newValue {
                            case .any:    draft.conditions.isUnread = nil
                            case .unread: draft.conditions.isUnread = true
                            case .read:   draft.conditions.isUnread = false
                            }
                        }
                    )) {
                        ForEach(ReadStateChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    Picker("AI category", selection: Binding(
                        get: { draft.conditions.category?.rawValue ?? "" },
                        set: { draft.conditions.category = SenderCategory(rawValue: $0) }
                    )) {
                        Text("Any").tag("")
                        Divider()
                        ForEach(SenderCategory.allCases) { category in
                            Label(category.label, systemImage: category.symbol).tag(category.rawValue)
                        }
                    }
                    // Disposable-domain condition. Three-state picker: Any (default),
                    // Disposable (sender domain on the bundled list), Not disposable
                    // (sender domain explicitly NOT on the list). Mirrors the read-state
                    // picker above.
                    Picker("Sender domain", selection: Binding(
                        get: { DisposableDomainChoice.from(draft.conditions.senderDomainIsDisposable) },
                        set: { draft.conditions.senderDomainIsDisposable = $0.value }
                    )) {
                        ForEach(DisposableDomainChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Conditions").font(.headline)
                        Text("a message must match all of these")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Leave a field blank or set it to “Any” to ignore that condition. The “From” field accepts a single address, a bare domain, or a comma-separated list (any match wins).")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if resolvedConditions().isEmpty {
                            Text("At least one condition is required.")
                                .font(.callout).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Picker("Outcome", selection: $outcomeKind) {
                        ForEach(OutcomeKind.allCases) { kind in
                            HStack {
                                Image(systemName: outcomeSymbol(kind))
                                Text(kind.label)
                            }
                            .tag(kind)
                        }
                    }
                    if outcomeKind == .moveToFolder {
                        if !inbox.mailboxes.isEmpty {
                            Picker("Destination", selection: $moveDestination) {
                                Text("Choose a folder…").tag("")
                                ForEach(inbox.mailboxes.filter { !$0.isSystem || $0.kind == .archive }) { mb in
                                    Text(mb.name).tag(mb.name)
                                }
                            }
                        } else {
                            TextField("Destination folder", text: $moveDestination, prompt: Text("Receipts/2026"))
                        }
                    }
                    if outcomeKind == .unsubscribe {
                        Label("Unsubscribe is not yet supported.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                } header: { Text("Outcome").font(.headline) }

                Section {
                    Picker("Scope", selection: $scopeKind) {
                        ForEach(ScopeKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if scopeKind == .folder {
                        if !inbox.mailboxes.isEmpty {
                            Picker("Folder", selection: $scopeFolder) {
                                Text("Choose a folder…").tag("")
                                ForEach(inbox.mailboxes) { mb in
                                    Text(mb.displayName).tag(mb.name)
                                }
                            }
                        } else {
                            TextField("Folder name", text: $scopeFolder, prompt: Text("INBOX"))
                        }
                    }
                } header: { Text("Scope").font(.headline) } footer: {
                    Text(scopeFooter)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(12)
        }
        .frame(width: 540, height: 560)
    }

    private func outcomeSymbol(_ kind: OutcomeKind) -> String {
        switch kind {
        case .delete: "trash"
        case .archive: "archivebox"
        case .moveToFolder: "folder"
        case .unsubscribe: "envelope.badge"
        }
    }

    private func resolvedConditions() -> Rule.Conditions {
        var c = draft.conditions
        c.olderThanDays = olderThanEnabled ? max(1, olderThanDays) : nil
        if c.fromAddressOrDomain?.isEmpty ?? false { c.fromAddressOrDomain = nil }
        if c.subjectContains?.isEmpty ?? false { c.subjectContains = nil }
        return c
    }

    private func resolvedOutcome() -> Rule.Outcome? {
        switch outcomeKind {
        case .delete: .delete
        case .archive: .archive
        case .moveToFolder:
            moveDestination.isEmpty ? nil : .moveToFolder(moveDestination)
        case .unsubscribe: nil
        }
    }

    private func resolvedScope() -> RuleScope {
        switch scopeKind {
        case .currentMailbox: .currentMailbox
        case .folder:         scopeFolder.isEmpty ? .currentMailbox : .folder(scopeFolder)
        case .allFolders:     .allFolders
        }
    }

    private var scopeFooter: String {
        switch scopeKind {
        case .currentMailbox:
            return "Runs against whichever mailbox is selected when the rule fires. Same as before scope was a setting."
        case .folder:
            return "Runs against this exact folder in every account. Loaded from the local cache, so accounts that haven't synced this folder are skipped."
        case .allFolders:
            return "Runs across every cached folder in every account. Use sparingly with destructive outcomes."
        }
    }

    private func submit() {
        guard let outcome = resolvedOutcome() else { return }
        var rule = draft
        rule.conditions = resolvedConditions()
        rule.outcome = outcome
        rule.scope = resolvedScope()
        if rule.name.isEmpty { rule.name = autoName(for: rule) }
        ruleStore.upsert(rule)
        dismiss()
    }

    private func autoName(for rule: Rule) -> String {
        var pieces: [String] = []
        if let f = rule.conditions.fromAddressOrDomain { pieces.append(f) }
        if let s = rule.conditions.subjectContains { pieces.append("\"\(s)\"") }
        if let d = rule.conditions.olderThanDays { pieces.append(">\(d)d") }
        if let c = rule.conditions.category { pieces.append(c.label) }
        let target = pieces.isEmpty ? "Anything" : pieces.joined(separator: " · ")
        return "\(rule.outcome.label) \(target)"
    }
}

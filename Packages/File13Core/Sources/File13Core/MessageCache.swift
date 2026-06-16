import Foundation
import SwiftData

@MainActor
public struct MessageCache {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Per-launch memoization of HMAC verification results. Re-hashing the
    /// SwiftData rows on every `loadHeaders` call is wasteful (a 5k-row
    /// mailbox takes ~10ms); after we've verified once per (account,
    /// mailbox), trust the result for the rest of the process lifetime.
    /// Failures land in the dictionary as `false` so we don't keep paying
    /// the verify cost for a known-tampered mailbox.
    @MainActor
    private static var verifiedKeys: [String: Bool] = [:]

    private static func verificationCacheKey(accountId: UUID, mailbox: String) -> String {
        "\(accountId.uuidString)|\(mailbox)"
    }

    /// Verify the HMAC for an (account, mailbox). Returns true when the
    /// stored MAC matches the rows currently in SwiftData, false when it
    /// doesn't, and true (failing open) when integrity isn't initialized
    /// yet for this mailbox — that case covers first-time loads on a
    /// pre-HMAC store. Mismatch is treated as cache corruption: callers
    /// purge the rows and force a re-fetch.
    private func verifyIntegrity(accountId: UUID, mailbox: String, headers: [MessageHeader]) -> Bool {
        let cacheKey = Self.verificationCacheKey(accountId: accountId, mailbox: mailbox)
        if let cached = Self.verifiedKeys[cacheKey] {
            return cached
        }
        // No stored MAC yet → first-time path. Don't reject; just install
        // the MAC for next time so subsequent loads have something to
        // compare against. This is the bootstrap on upgrade from a
        // pre-integrity build.
        guard let expected = CachedHeadersIntegrity.loadMAC(accountId: accountId, mailbox: mailbox) else {
            let uv = loadUIDValidity(accountId: accountId, mailbox: mailbox)
            if let mac = CachedHeadersIntegrity.computeMAC(
                accountId: accountId, mailbox: mailbox, uidValidity: uv, headers: headers
            ) {
                CachedHeadersIntegrity.saveMAC(mac, accountId: accountId, mailbox: mailbox)
            }
            Self.verifiedKeys[cacheKey] = true
            return true
        }
        let uv = loadUIDValidity(accountId: accountId, mailbox: mailbox)
        guard let actual = CachedHeadersIntegrity.computeMAC(
            accountId: accountId, mailbox: mailbox, uidValidity: uv, headers: headers
        ) else {
            // Couldn't compute (Keychain unavailable). Fail open so the
            // cache stays usable.
            Self.verifiedKeys[cacheKey] = true
            return true
        }
        let ok = CachedHeadersIntegrity.macsEqual(expected, actual)
        Self.verifiedKeys[cacheKey] = ok
        return ok
    }

    /// Refresh the persisted HMAC after a transactional mutation
    /// (`replaceHeaders` / `applyDiff`). Always called from a `@MainActor`
    /// context so the verification-result cache stays consistent with
    /// what's on disk.
    private func updateIntegrityMAC(accountId: UUID, mailbox: String) {
        let headers = loadHeadersWithoutVerification(accountId: accountId, mailbox: mailbox)
        let uv = loadUIDValidity(accountId: accountId, mailbox: mailbox)
        guard let mac = CachedHeadersIntegrity.computeMAC(
            accountId: accountId, mailbox: mailbox, uidValidity: uv, headers: headers
        ) else { return }
        CachedHeadersIntegrity.saveMAC(mac, accountId: accountId, mailbox: mailbox)
        Self.verifiedKeys[Self.verificationCacheKey(accountId: accountId, mailbox: mailbox)] = true
    }

    /// Same SwiftData query as `loadHeaders` but without the
    /// integrity-verify pass — used internally by the post-mutation
    /// refresh, where verifying would be circular.
    private func loadHeadersWithoutVerification(accountId: UUID, mailbox: String) -> [MessageHeader] {
        let id = accountId
        let mb = mailbox
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == id && $0.mailboxName == mb },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map { $0.toHeader() }
    }

    /// Load every cached header for an account across every mailbox in one
    /// query. Used by the whole-inbox rule suggester so the model gets a
    /// cross-folder view (archived patterns, sent-folder hints, etc.), not
    /// just whatever's loaded in the currently-displayed mailbox.
    /// Single SwiftData fetch covering many accounts at once. Cuts the
    /// "N accounts × one query each" pattern down to a single round-trip,
    /// which is felt at launch (cold cache load) and on every whole-
    /// inbox rule-suggestion run. Verification still happens per
    /// (account, mailbox), reusing the same `verifyIntegrity` machinery
    /// — so an integrity failure in one account-mailbox still self-heals
    /// without taking the others with it.
    public func loadAllHeadersForAccounts(_ accountIds: [UUID]) -> [UUID: [MessageHeader]] {
        guard !accountIds.isEmpty else { return [:] }
        let idSet = Set(accountIds)
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { idSet.contains($0.accountId) },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        let groupedRows = Dictionary(grouping: rows, by: { $0.accountId })
        var result: [UUID: [MessageHeader]] = [:]
        result.reserveCapacity(accountIds.count)

        for accountId in accountIds {
            let accountRows = groupedRows[accountId] ?? []
            let perMailbox = Dictionary(grouping: accountRows, by: { $0.mailboxName })
            var kept: [MessageHeader] = []
            kept.reserveCapacity(accountRows.count)
            var compromisedToDelete: [CachedMessage] = []
            for (mailbox, mailboxRows) in perMailbox {
                let headers = mailboxRows.map { $0.toHeader() }
                if verifyIntegrity(accountId: accountId, mailbox: mailbox, headers: headers) {
                    kept.append(contentsOf: headers)
                } else {
                    compromisedToDelete.append(contentsOf: mailboxRows)
                }
            }
            if !compromisedToDelete.isEmpty {
                for row in compromisedToDelete { context.delete(row) }
            }
            result[accountId] = kept
        }
        if rows.count != result.values.reduce(0, { $0 + $1.count }) {
            try? context.save()
        }
        return result
    }

    public func loadAllHeaders(accountId: UUID) -> [MessageHeader] {
        let id = accountId
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == id },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        // Group by mailbox so we can verify per-(account, mailbox). One
        // pass through the rows builds both the verification input and
        // the result; the prior implementation hashed twice and used an
        // O(N²) lookup for the post-filter step.
        let byMailbox = Dictionary(grouping: rows, by: { $0.mailboxName })
        var kept: [MessageHeader] = []
        kept.reserveCapacity(rows.count)
        var anyDeleted = false
        // Preserve the descriptor's date-desc order: iterate mailboxes in
        // an order that yields the same overall sort. Concatenating the
        // per-mailbox slices doesn't preserve global sort, so we walk
        // `rows` once at the end to assemble in descriptor order.
        var keptMailboxes: Set<String> = []
        for (mailbox, mailboxRows) in byMailbox {
            let headers = mailboxRows.map { $0.toHeader() }
            if verifyIntegrity(accountId: accountId, mailbox: mailbox, headers: headers) {
                keptMailboxes.insert(mailbox)
            } else {
                for row in mailboxRows { context.delete(row) }
                anyDeleted = true
            }
        }
        if anyDeleted { try? context.save() }
        if keptMailboxes.count == byMailbox.count {
            return rows.map { $0.toHeader() }
        }
        for row in rows where keptMailboxes.contains(row.mailboxName) {
            kept.append(row.toHeader())
        }
        return kept
    }

    public func loadHeaders(accountId: UUID, mailbox: String) -> [MessageHeader] {
        let id = accountId
        let mb = mailbox
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == id && $0.mailboxName == mb },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        // Defense in depth against cache corruption: if two SwiftData rows
        // share the same UID in the same (account, mailbox) — which
        // *shouldn't* happen under IMAP UID uniqueness, but has historically
        // when migrations or interrupted writes left orphan rows — dedupe by
        // keeping the most-recently-fetched copy and dropping the rest from
        // SwiftData on the spot. This self-heals the store on the next read.
        let (deduped, removed) = dedupeByUID(rows)
        if !removed.isEmpty {
            for row in removed { context.delete(row) }
            try? context.save()
        }
        let headers = deduped.map { $0.toHeader() }
        // Verify the HMAC for this (account, mailbox). On failure, purge
        // the whole mailbox's rows and treat as a cache miss — the next
        // refresh will repopulate from the server.
        if !verifyIntegrity(accountId: accountId, mailbox: mailbox, headers: headers) {
            for row in deduped { context.delete(row) }
            try? context.save()
            return []
        }
        return headers
    }

    /// Keep one `CachedMessage` per UID (newest by `fetchedAt`), return the
    /// kept set and the cast-offs so the caller can delete them.
    private func dedupeByUID(_ rows: [CachedMessage]) -> (kept: [CachedMessage], remove: [CachedMessage]) {
        var keepByUID: [UInt32: CachedMessage] = [:]
        var rowsWithoutUID: [CachedMessage] = []
        var remove: [CachedMessage] = []
        for row in rows {
            // UID is non-optional on CachedMessage (we always have one for
            // cached server messages), but guard anyway.
            let uid = row.uid
            guard uid != 0 else { rowsWithoutUID.append(row); continue }
            if let existing = keepByUID[uid] {
                if row.fetchedAt > existing.fetchedAt {
                    remove.append(existing)
                    keepByUID[uid] = row
                } else {
                    remove.append(row)
                }
            } else {
                keepByUID[uid] = row
            }
        }
        return (Array(keepByUID.values) + rowsWithoutUID, remove)
    }

    /// Replace every cached message for an (account, mailbox) pair in a single transaction.
    public func replaceHeaders(_ headers: [MessageHeader], accountId: UUID, mailbox: String) throws {
        let id = accountId
        let mb = mailbox
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == id && $0.mailboxName == mb }
        )
        let existing = try context.fetch(descriptor)
        for row in existing {
            context.delete(row)
        }
        let now = Date()
        for header in headers {
            context.insert(CachedMessage(header, mailbox: mailbox, fetchedAt: now))
        }
        try context.save()
        updateIntegrityMAC(accountId: accountId, mailbox: mailbox)
    }

    /// Apply an incremental diff to the cached store: drop rows whose UIDs are gone, update read
    /// flags on rows whose state changed, and insert headers for newly-arrived UIDs. All in one
    /// transaction.
    public func applyDiff(
        accountId: UUID,
        mailbox: String,
        deletedUIDs: Set<UInt32>,
        flagUpdates: [UInt32: Bool],
        insertedHeaders: [MessageHeader]
    ) throws {
        let id = accountId
        let mb = mailbox

        // Always fetch the full set when we have any work to do, so we can
        // both apply deletes/flag updates AND check for pre-existing UIDs
        // before inserting. Without the pre-check, a stale in-memory diff
        // (e.g. in-memory `headers` was missing a row that the cache still
        // had) would cause `newUIDs` to include a UID that's already in the
        // cache — inserting again would create the duplicate row that later
        // traps `Dictionary(uniqueKeysWithValues:)`.
        var existingUIDs: Set<UInt32> = []
        if !deletedUIDs.isEmpty || !flagUpdates.isEmpty || !insertedHeaders.isEmpty {
            let descriptor = FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.accountId == id && $0.mailboxName == mb }
            )
            let rows = try context.fetch(descriptor)
            for row in rows {
                if deletedUIDs.contains(row.uid) {
                    context.delete(row)
                } else if let newIsRead = flagUpdates[row.uid] {
                    row.isRead = newIsRead
                    existingUIDs.insert(row.uid)
                } else {
                    existingUIDs.insert(row.uid)
                }
            }
        }

        if !insertedHeaders.isEmpty {
            let now = Date()
            for header in insertedHeaders {
                // Skip inserts for UIDs already cached. The expected case is
                // a perfect diff (caller filtered), but we belt-and-suspender
                // here so a stale `cachedUIDs` snapshot can't poison the
                // store with a duplicate row.
                if let uid = header.uid, existingUIDs.contains(uid) {
                    continue
                }
                context.insert(CachedMessage(header, mailbox: mailbox, fetchedAt: now))
                if let uid = header.uid { existingUIDs.insert(uid) }
            }
        }

        try context.save()
        updateIntegrityMAC(accountId: accountId, mailbox: mailbox)
    }

    // MARK: UIDValidity persistence

    public func loadUIDValidity(accountId: UUID, mailbox: String) -> UInt64? {
        let key = Self.uidValidityKey(accountId: accountId, mailbox: mailbox)
        guard SharedDefaults.suite.object(forKey: key) != nil else { return nil }
        let raw = SharedDefaults.suite.integer(forKey: key)
        return raw == 0 ? nil : UInt64(raw)
    }

    public func setUIDValidity(_ value: UInt64, accountId: UUID, mailbox: String) {
        SharedDefaults.suite.set(
            Int(clamping: value),
            forKey: Self.uidValidityKey(accountId: accountId, mailbox: mailbox)
        )
    }

    public func clearUIDValidity(accountId: UUID, mailbox: String) {
        SharedDefaults.suite.removeObject(
            forKey: Self.uidValidityKey(accountId: accountId, mailbox: mailbox)
        )
    }

    private static func uidValidityKey(accountId: UUID, mailbox: String) -> String {
        "File13.uidValidity.\(accountId.uuidString).\(mailbox)"
    }

    /// Drop every persisted `UIDValidity`. Combined with deleting the SwiftData rows, the next
    /// refresh is forced to be a full slim fetch — used when we ship new header fields and need
    /// to backfill metadata that incremental sync wouldn't otherwise touch.
    public func clearAllUIDValidities() {
        let defaults = SharedDefaults.suite
        let prefix = "File13.uidValidity."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Drop persisted `UIDValidity` entries for a single account (every mailbox).
    public func clearUIDValidities(accountId: UUID) {
        let defaults = SharedDefaults.suite
        let prefix = "File13.uidValidity.\(accountId.uuidString)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Wipe every cached message across all accounts. Doesn't enumerate
    /// per-mailbox MACs to delete because we don't know which mailboxes
    /// exist post-purge — leaving them is harmless: the next load
    /// triggers a bootstrap-style MAC install once new headers arrive,
    /// overwriting any orphan.
    public func purgeAll() throws {
        try context.delete(model: CachedMessage.self)
        try context.save()
        Self.verifiedKeys.removeAll()
    }

    /// Run a one-time migration when the headers schema version we last persisted is older than
    /// the current code's expectation. Each bump clears UIDValidity + every cached row so the
    /// next refresh becomes a full slim fetch and rehydrates the cache with the new fields.
    public static func runSchemaMigrationIfNeeded(version: Int, cache: MessageCache) {
        let defaults = SharedDefaults.suite
        let stored = defaults.integer(forKey: "File13.headersSchemaVersion")
        guard stored < version else { return }
        cache.clearAllUIDValidities()
        try? cache.purgeAll()
        defaults.set(version, forKey: "File13.headersSchemaVersion")
    }

    /// Remove every cached message for an account (used when an account is removed).
    public func purge(accountId: UUID) throws {
        // Gather mailbox names before delete so we can also clean up the
        // per-mailbox MACs and verification cache entries — keeps Keychain
        // tidy when an account is removed.
        let id = accountId
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == id }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        let mailboxes = Set(rows.map { $0.mailboxName })
        try context.delete(model: CachedMessage.self, where: #Predicate { $0.accountId == id })
        try context.save()
        for mailbox in mailboxes {
            CachedHeadersIntegrity.deleteMAC(accountId: id, mailbox: mailbox)
            Self.verifiedKeys.removeValue(
                forKey: Self.verificationCacheKey(accountId: id, mailbox: mailbox)
            )
        }
    }
}

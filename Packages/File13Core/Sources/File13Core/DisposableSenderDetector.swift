import Foundation

/// Detects senders whose domain belongs to a disposable / throwaway email provider
/// (Mailinator, GuerrillaMail, 10MinuteMail, Yopmail, and ~5,400 others).
///
/// Backed by a vendored copy of the [disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains)
/// public-domain (CC0) blocklist, refreshed with each File13 release. The list is loaded
/// lazily on first use, kept in a `Set<String>` for O(1) lookup, and consulted purely locally —
/// no sender address ever leaves the device for this check.
///
/// Used at `MessageHeader.init(...)` time to memoize `isFromDisposableDomain` so per-render
/// reads (sender table, selection counts, rule evaluation) don't repeat the lookup.
public enum DisposableSenderDetector {
    /// Returns true when `address`'s domain (the part after `@`, case-insensitive) appears
    /// in the bundled blocklist. False for addresses with no `@`, an empty domain, or any
    /// domain not on the list.
    public static func isDisposable(address: String) -> Bool {
        guard let domain = domain(from: address) else { return false }
        return domains.contains(domain)
    }

    /// Returns true when `domain` (already lowercased, no `@`) appears in the bundled blocklist.
    /// Public so rule evaluation and tests can check raw domains without re-parsing addresses.
    public static func isDisposable(domain: String) -> Bool {
        domains.contains(domain.lowercased())
    }

    /// Number of domains currently loaded. Useful for tests and the `file13 doctor` report.
    public static var bundledDomainCount: Int { domains.count }

    /// Lower-cased domain extracted from the address, or nil when the address has no `@`
    /// or an empty local/domain part. Matches what we hash sender addresses with elsewhere
    /// (the lowercased form), so the same domain always classifies the same way.
    private static func domain(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domainStart = trimmed.index(after: at)
        guard domainStart < trimmed.endIndex else { return nil }
        let domain = trimmed[domainStart...].lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// Lazily-loaded set of blocklisted domains. ~5,400 entries today; the load is a single
    /// `String(contentsOf:)` + `split` + `Set(_:)` — tens of milliseconds at most on a cold
    /// start, then never again for the lifetime of the process.
    ///
    /// Falls back to an empty set if the resource is missing (which shouldn't happen in a
    /// shipped build, but the test bundle and SwiftPM module-loader oddities have surprised
    /// us before — an empty set means `isDisposable` returns false for every address, which
    /// is the safe default).
    private static let domains: Set<String> = loadDomains()

    private static func loadDomains() -> Set<String> {
        guard let url = Bundle.module.url(forResource: "disposable_email_blocklist.conf", withExtension: nil),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var set: Set<String> = []
        set.reserveCapacity(6_000)
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The upstream file is plain `domain\n`, no comments — but defend against future
            // schema changes by skipping anything that looks like a comment or is empty.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            set.insert(trimmed.lowercased())
        }
        return set
    }
}

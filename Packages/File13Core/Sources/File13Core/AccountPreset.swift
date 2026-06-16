import Foundation

/// Provider quick-select tiles for the Add Mailbox flow. Picking a preset
/// pre-fills the IMAP host / port and triggers the matching
/// `ProviderPasswordCalloutInfo` so users know whether they need an
/// app-specific password before they hit Connect. Cross-platform — the
/// platform-specific Add Mailbox sheets build their own picker UI on top.
public enum AccountPreset: String, CaseIterable, Identifiable, Sendable {
    case icloud, gmail, outlook, yahoo, aol, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .icloud:  "iCloud"
        case .gmail:   "Gmail"
        case .outlook: "Outlook"
        case .yahoo:   "Yahoo"
        case .aol:     "AOL"
        case .custom:  "Other"
        }
    }

    public var icon: String {
        switch self {
        case .icloud:  "icloud.fill"
        case .gmail:   "envelope.fill"
        case .outlook: "envelope.fill"
        case .yahoo:   "envelope.fill"
        case .aol:     "envelope.fill"
        case .custom:  "server.rack"
        }
    }

    /// IMAP host to pre-fill. `nil` means "leave alone" — the user is on the
    /// custom path and the email-driven `imap.<domain>` autofill should kick in.
    public var host: String? {
        switch self {
        case .icloud:  "imap.mail.me.com"
        case .gmail:   "imap.gmail.com"
        case .outlook: "outlook.office365.com"
        case .yahoo:   "imap.mail.yahoo.com"
        case .aol:     "imap.aol.com"
        case .custom:  nil
        }
    }

    public var port: Int { 993 }

    /// Reverse-lookup: which preset does this host most closely match? Used to
    /// keep the preset-picker highlight in sync with email-driven host
    /// autofill, so typing `foo@gmail.com` lights up the Gmail tile.
    public static func detect(host: String) -> AccountPreset {
        let lower = host.lowercased()
        if lower.hasSuffix("mail.me.com") { return .icloud }
        if lower.contains("gmail.com") || lower.contains("googlemail.com") { return .gmail }
        if lower.contains("outlook") || lower.contains("office365") || lower.contains("hotmail") || lower.contains("live.com") {
            return .outlook
        }
        if lower.contains("yahoo") || lower.contains("ymail") || lower.contains("rocketmail") {
            return .yahoo
        }
        if lower.contains("aol") || lower.contains("aim.com") || lower.contains("netscape.net") {
            return .aol
        }
        return .custom
    }

    /// Map an `AccountPreset` back to the `Account.Provider` value persisted in
    /// `Account`. `.custom` and unmatched hosts fall through to `.imap`.
    public var accountProvider: Account.Provider {
        switch self {
        case .icloud:  .icloud
        case .gmail:   .gmail
        case .outlook: .outlook
        case .yahoo:   .yahoo
        case .aol:     .aol
        case .custom:  .imap
        }
    }

    /// Yahoo's IMAP service handles all of its consumer domains —
    /// yahoo.com, ymail.com, rocketmail.com, and the per-country yahoo.<cc>
    /// variants (yahoo.co.uk, yahoo.fr, yahoo.de, …). They all funnel
    /// through `imap.mail.yahoo.com`.
    public static func isYahooDomain(_ domain: String) -> Bool {
        domain == "yahoo.com"
            || domain == "ymail.com"
            || domain == "rocketmail.com"
            || domain.hasPrefix("yahoo.")
    }

    /// AOL's IMAP service covers the AOL-branded consumer domains acquired
    /// over the years — aol.com, aim.com, love.com, ygm.com, games.com,
    /// wow.com, netscape.net — all routed through `imap.aol.com`.
    public static func isAOLDomain(_ domain: String) -> Bool {
        switch domain {
        case "aol.com", "aim.com", "love.com", "ygm.com",
             "games.com", "wow.com", "netscape.net":
            return true
        default:
            return false
        }
    }
}

/// Inline notice data shown when the IMAP host points at a provider known
/// to require app-specific passwords (or to need provider-specific setup).
/// Cross-platform — each platform builds its own View on top.
public struct ProviderPasswordCalloutInfo: Sendable, Equatable {
    public let title: String
    public let message: String
    public let linkLabel: String
    public let url: URL

    public init(title: String, message: String, linkLabel: String, url: URL) {
        self.title = title
        self.message = message
        self.linkLabel = linkLabel
        self.url = url
    }

    /// Pick the right callout for a given IMAP host, or nil for hosts we
    /// don't recognize (custom IMAP, generic providers).
    public static func forHost(_ host: String) -> ProviderPasswordCalloutInfo? {
        let lower = host.lowercased()
        if lower.hasSuffix("mail.me.com") {
            return ProviderPasswordCalloutInfo(
                title: "iCloud requires an app-specific password",
                message: "Your regular Apple ID password won't work. Generate one for File13 at the link below — your Apple ID must have two-factor authentication turned on.",
                linkLabel: "Generate an app-specific password",
                url: URL.verified("https://appleid.apple.com/account/manage")
            )
        }
        if lower.contains("gmail.com") {
            return ProviderPasswordCalloutInfo(
                title: "Gmail requires an app password",
                message: "Google no longer accepts your regular account password over IMAP. Generate a 16-character app password under your Google Account — 2-Step Verification must be on.",
                linkLabel: "Generate a Google app password",
                url: URL.verified("https://myaccount.google.com/apppasswords")
            )
        }
        if lower.contains("outlook") || lower.contains("office365") || lower.contains("hotmail") {
            return ProviderPasswordCalloutInfo(
                title: "Outlook IMAP is limited in 2025",
                message: "Microsoft retired password-based IMAP for personal accounts (outlook.com / hotmail.com / live.com) in September 2024 — those accounts now require OAuth, which File13 can't ship without Microsoft Publisher Verification. Work/school Microsoft 365 accounts may still allow IMAP if your tenant administrator hasn't disabled it; ask IT for an app password.",
                linkLabel: "Generate a Microsoft app password (if eligible)",
                url: URL.verified("https://account.microsoft.com/security")
            )
        }
        if lower.contains("yahoo") {
            return ProviderPasswordCalloutInfo(
                title: "Yahoo requires an app password",
                message: "Yahoo no longer accepts your regular account password over IMAP. Generate an app password under Yahoo Account Security — two-step verification must be on.",
                linkLabel: "Generate a Yahoo app password",
                url: URL.verified("https://login.yahoo.com/account/security/app-passwords")
            )
        }
        if lower.contains("aol") {
            return ProviderPasswordCalloutInfo(
                title: "AOL requires an app password",
                message: "AOL Mail runs on Yahoo's mail infrastructure and no longer accepts your regular AOL password over IMAP. Generate an app password under AOL Account Security — two-step verification must be on.",
                linkLabel: "Generate an AOL app password",
                url: URL.verified("https://login.aol.com/account/security/app-passwords")
            )
        }
        return nil
    }
}

/// Pure-function derivation of host / username / display name from an
/// email address. Used by both Add Mailbox sheets to autofill fields as
/// the user types. The view layer holds the `lastDerived*` state and
/// decides whether to overwrite a field — this helper is stateless.
public enum AccountEmailDerivation {
    public struct Derived: Sendable, Equatable {
        public let displayName: String?
        public let username: String
        public let host: String?
    }

    public static func derive(from email: String) -> Derived {
        let username = email
        guard let atIndex = email.firstIndex(of: "@") else {
            return Derived(displayName: nil, username: username, host: nil)
        }
        let domain = String(email[email.index(after: atIndex)...]).lowercased()
        guard !domain.isEmpty else {
            return Derived(displayName: nil, username: username, host: nil)
        }
        let host: String
        if domain == "icloud.com" || domain == "me.com" || domain == "mac.com" {
            host = "imap.mail.me.com"
        } else if AccountPreset.isYahooDomain(domain) {
            host = "imap.mail.yahoo.com"
        } else if AccountPreset.isAOLDomain(domain) {
            host = "imap.aol.com"
        } else {
            host = "imap.\(domain)"
        }
        return Derived(displayName: domain, username: username, host: host)
    }
}

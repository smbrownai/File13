import ArgumentParser
import Foundation

/// Top-level entry point for the `file13` CLI.
///
/// Headless companion to File13.app. Distributed independently of the GUI via
/// the `smbrownai/file13` Homebrew tap (`brew install smbrownai/file13/file13`)
/// — it is **not** embedded in the .app. Reads settings, accounts, rules,
/// replied-message tracking, sender categories, VIPs, and the Pro license tier
/// from the same App Group container the GUI writes to. IMAP passwords and AI
/// provider keys are CLI-private (see the `discussion` text below for why).
@main
struct File13: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file13",
        abstract: "Headless companion CLI for File13 — IMAP triage on metadata only.",
        discussion: """
        Shares state with File13.app through the App Group container at
        ~/Library/Group Containers/group.com.shawnbrown.file13. Settings,
        accounts (without passwords), rules, AI preferences, sender categories,
        VIPs, replied-message tracking, and the Pro license tier flow GUI → CLI
        automatically.

        Credentials do not cross. The GUI stores IMAP passwords and AI provider
        keys in a Keychain access group the CLI cannot claim (App Groups and
        keychain-access-groups are restricted entitlements that need an embedded
        provisioning profile, which bare Mach-O binaries can't carry). The first
        time you run a mail-touching command, re-add each mailbox with
        `file13 accounts add` and re-enter the AI API key (if any) — the CLI
        manages its own keychain entries in the default user keychain.

        Mail-touching commands (`refresh`, `mail delete/archive/move`,
        `senders list`) require exclusive access to the SwiftData container —
        they bail with exit 2 when File13.app is open. Settings, account,
        provider, and rule reads work alongside the GUI without conflict.

        Pro-gated: every leaf subcommand except `version` and `doctor` exits 4
        unless File13 Pro has been purchased in the GUI on this Mac
        (or shared via Family Sharing / Universal Purchase).
        """,
        version: file13Version,
        subcommands: [Version.self, Doctor.self, SettingsCommand.self, ProvidersCommand.self, AccountsCommand.self, RulesCommand.self, SendersCommand.self, RefreshCommand.self, MailCommand.self, ConfigCommand.self, AICommand.self],
        defaultSubcommand: nil
    )
}

let file13Version = "0.0.4"

import SwiftUI

/// Renders the long-form body for a given `HelpTopic`. Each topic's content
/// lives in its own `@ViewBuilder` so it's easy to scan and edit in
/// isolation; layout primitives (`HelpHeading`, `HelpParagraph`,
/// `HelpBullet`, `HelpCallout`, `HelpKey`) sit at the bottom of the file.
struct HelpContentView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: topic.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text(topic.title)
                        .font(.system(size: 28, weight: .bold))
                }
                .padding(.bottom, 4)

                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch topic {
        case .welcome:         welcome
        case .addAccount:      addAccount
        case .threeViews:      threeViews
        case .cullEmail:       cullEmail
        case .undoSafety:      undoSafety
        case .rules:           rules
        case .aiInsights:      aiInsights
        case .privacy:         privacy
        case .security:        security
        case .shortcuts:       shortcuts
        case .troubleshooting: troubleshooting
        }
    }

    // MARK: - Welcome

    @ViewBuilder private var welcome: some View {
        HelpParagraph("File13 helps you reclaim an overrun inbox quickly and safely. It connects to your IMAP mail account, groups messages by sender, subject, or date, and gives you bulk actions that let you delete, archive, move, or unsubscribe in a single sweep.")

        HelpHeading("What File13 is good at")
        HelpBullet("**Bulk triage.** See who sends you the most mail, how often you actually read it, and whether you've ever replied. Then act on a whole sender at once.")
        HelpBullet("**Unsubscribing for real.** One-click HTTPS unsubscribe where senders support it, with a clean mailto-handoff fallback for the rest.")
        HelpBullet("**Repeatable cleanup.** Save your triage decisions as rules that run automatically on a schedule.")
        HelpBullet("**Quiet AI assistance.** On-device by default, with optional support for OpenAI, Anthropic, Google, or Perplexity if you bring your own key.")

        HelpHeading("What File13 won't do")
        HelpBullet("Read or display the body of any email. File13 fetches headers only.")
        HelpBullet("Send mail. There is no SMTP integration. Unsubscribe replies are handed off to your default mail client.")
        HelpBullet("Talk to any server you didn't ask it to. The only outbound connections are to your mail server, the AI provider you configured (if any), and one-click unsubscribe URLs you choose to invoke.")

        HelpCallout(.tip, "If you're already comfortable with email triage, the fastest path is: add your account, open the **Senders** view, sort by **Count**, and start checking off the offenders at the top.")
    }

    // MARK: - Add Account

    @ViewBuilder private var addAccount: some View {
        HelpParagraph("To start, open **Settings → Accounts** and click **Add Account**, or use the welcome prompt the app shows on first launch. File13 supports any IMAP mail server.")

        HelpHeading("Most mail providers need an app-specific password")
        HelpParagraph("Major mail providers no longer accept your everyday account password for IMAP. Instead you generate a separate, single-purpose password just for File13. The provider tile in **Add Account** links directly to the page that creates one.")

        HelpBullet("**iCloud Mail.** Sign in at appleid.apple.com, then **Sign-In and Security → App-Specific Passwords**.")
        HelpBullet("**Gmail.** Turn on two-step verification, then visit Google's **App passwords** page.")
        HelpBullet("**Outlook / Hotmail / Live.** Microsoft retired basic-auth IMAP for personal accounts in September 2024. Outlook works in File13 only for work or school accounts where the administrator still permits IMAP app passwords.")
        HelpBullet("**Yahoo / AOL.** Yahoo Account Security → Generate app password. AOL routes through the same flow.")
        HelpBullet("**Other.** Any IMAP server works. You'll need the hostname, port (usually 993), and your IMAP password.")

        HelpHeading("What happens on first sync")
        HelpParagraph("File13 downloads headers for every message in your mailboxes. The first pass can take a few minutes for very large mailboxes; subsequent refreshes are seconds, because File13 only fetches what changed.")

        HelpCallout(.privacy, "Your password is stored in the macOS Keychain and is sent only to your mail server. It never reaches File13's developer or any third party.")

        HelpHeading("Multiple accounts")
        HelpParagraph("You can add more than one account on the **File13 Pro** tier. The free tier covers one mailbox on one Apple platform. The sidebar switches between a Unified view (all accounts combined) and per-account views.")
    }

    // MARK: - Three Views

    @ViewBuilder private var threeViews: some View {
        HelpParagraph("File13 offers three ways to look at your mail. They share the same underlying header cache, so switching between them is instant and your selection carries across.")

        HelpHeading("Senders view")
        HelpParagraph("The default. One row per sender, sorted by how much they've sent you. Columns show total count, unread count, read rate, last-received date, and whether they look like a newsletter or a transactional sender. This is the view most people spend the most time in.")

        HelpHeading("Subjects view")
        HelpParagraph("Messages grouped by normalized subject. Useful for cleaning out repetitive notification threads where the sender varies but the subject is the same.")

        HelpHeading("Dates view")
        HelpParagraph("Four buckets — recent week, recent month, this year, and older. Helpful when you want to archive or delete swaths of old mail without targeting any particular sender. Each bucket can be expanded to show a per-sender breakdown.")

        HelpCallout(.tip, "Click the **Newsletter** chip above the list to filter to senders that include `List-Unsubscribe` headers. That's usually the biggest category to triage first.")
    }

    // MARK: - Culling email

    @ViewBuilder private var cullEmail: some View {
        HelpParagraph("The core workflow: select messages or senders, then pick an action from the toolbar.")

        HelpHeading("Make a selection")
        HelpBullet("Click the checkbox on a sender row to select **every** message from that sender.")
        HelpBullet("Expand a sender to see individual messages and check them one at a time.")
        HelpBullet("Use the keyboard: arrow keys to move, space to toggle the focused row, **⌘A** to select everything visible, **⎋** (Escape) to clear.")

        HelpHeading("Bulk actions")
        HelpBullet("**Delete.** Moves to the Trash folder if soft-delete is on (the default), otherwise marks for permanent removal.")
        HelpBullet("**Archive.** Moves to your server's Archive folder. Detected automatically per account.")
        HelpBullet("**Move to Folder.** Pick a destination from the popover. Single-account scope only — Unified view doesn't know which account's folder you mean.")
        HelpBullet("**Unsubscribe.** For senders that ship a `List-Unsubscribe` header, File13 runs the one-click HTTPS endpoint (RFC 8058) when offered, falls back to opening the URL in your browser, or hands off a `mailto:` to your default mail client.")
        HelpBullet("**Create Rule.** Pre-fills a rule from the selection. See the **Rules** page.")

        HelpHeading("The Activity drawer")
        HelpParagraph("Pull up the drawer at the bottom of the window to see what your mail actually looks like — volume over time, top senders, hour-of-day distribution, plus AI-driven category breakdowns once you've run categorization. It's a low-pressure way to find what to triage next.")
    }

    // MARK: - Undo & Safety

    @ViewBuilder private var undoSafety: some View {
        HelpParagraph("Every bulk action is reversible for a few seconds. File13 mutates your local cache immediately so the UI feels snappy, but it waits before telling the server.")

        HelpHeading("The undo buffer")
        HelpParagraph("After you delete, archive, or move, a banner appears with a countdown. Click **Undo** any time before the countdown ends, or press **⌘Z**, and the action is rolled back as if it never happened. The default buffer is 30 seconds; adjust it in **Settings → Actions & Safety** between 5 and 60 seconds.")

        HelpHeading("Soft delete")
        HelpParagraph("Delete moves messages to your server's Trash folder by default. You can recover anything from there in any mail app for as long as the server keeps it. Turn this off in **Settings → Actions & Safety** if you want **Delete** to mean permanent removal — but soft delete is recommended.")

        HelpHeading("Confirm before delete")
        HelpParagraph("Optional confirmation dialog before any delete fires. On by default for selections over 100 messages.")

        HelpHeading("Dry Run mode")
        HelpParagraph("Toggle in **Settings → Actions & Safety**. With Dry Run on, actions log what they would have done without contacting the server. Helpful for testing a new rule against a real inbox.")

        HelpHeading("Transactional protection")
        HelpParagraph("File13 recognizes receipts, invoices, shipping confirmations, and order updates by subject patterns and refuses to delete them — both for manual selections and for rules. This protection is on by default and can be relaxed in **Settings → Actions & Safety**.")

        HelpHeading("VIP protection")
        HelpParagraph("Senders you reply to often are flagged as VIPs and protected from rule-driven deletions. You can review and edit your VIP list under **Settings → Rules → VIPs**, or pin/unpin a sender from the inspector.")

        HelpCallout(.warning, "Once the buffer expires, the action commits to your mail server. File13 can no longer undo it — recovery has to come from your mail provider's Trash or from a server-side backup.")
    }

    // MARK: - Rules

    @ViewBuilder private var rules: some View {
        HelpParagraph("A rule is a saved decision: \"every time mail matches **X**, do **Y**.\" Rules turn one-off triage into something you only have to do once.")

        HelpHeading("Building a rule")
        HelpBullet("Open **Settings → Rules**, or click **Create Rule** on the bulk action bar after making a selection — fields are pre-filled.")
        HelpBullet("**Conditions:** From / Subject / Older Than / Read or Unread. Combine any number with **AND** logic.")
        HelpBullet("**Action:** Delete, Archive, Move to Folder, or Unsubscribe.")
        HelpBullet("**Scope:** Current Mailbox (default), a specific named folder, or All Folders.")

        HelpHeading("Running rules")
        HelpParagraph("Each rule runs on its own schedule, picked under **Settings → Rules → Schedule**:")
        HelpBullet("**Manual** — runs only when you click **Run Rules Now** (⇧⌘R).")
        HelpBullet("**On Launch** — runs once when File13 starts.")
        HelpBullet("**Hourly** — at the top of every wall-clock hour the app is open.")
        HelpBullet("**Daily** — at 3 AM if the app is open.")

        HelpHeading("Suggestion engine")
        HelpParagraph("If you've configured AI, File13 can suggest rules based on what your inbox looks like — high-volume senders you don't read, newsletters you never click, etc. Suggestions appear under **Settings → Rules → Suggestions**. Dismiss the ones you don't like; the same suggestion won't reappear.")

        HelpCallout(.tip, "Rules respect transactional and VIP protections by default. A rule that says \"delete everything from `noreply@\\*`\" still won't delete an Amazon order confirmation or a sender you reply to often.")
    }

    // MARK: - AI Insights

    @ViewBuilder private var aiInsights: some View {
        HelpParagraph("File13 offers optional AI features for inbox triage. All of them work on **metadata only** — sender addresses, subjects, dates, list-headers, read/reply flags. Body content is never sent.")

        HelpHeading("What you can ask AI to do")
        HelpBullet("**Categorize senders** — assign each sender a category like Newsletter, Notification, Receipt, Social, Personal, etc. Feeds the Activity dashboard breakdowns.")
        HelpBullet("**Advise on a single sender** — \"what is this, how often do I read it, what should I do about it.\"")
        HelpBullet("**Suggest rules** — propose cleanup rules across your top senders or your whole mailbox.")

        HelpHeading("Picking a provider")
        HelpParagraph("Configure in **Settings → AI**. The default is **Apple Foundation Models** — Apple's on-device model, which runs on your Mac (or, for prompts that exceed the on-device model, on Apple's Private Cloud Compute infrastructure, which Apple has designed not to retain prompts). No API key needed.")

        HelpParagraph("If you'd prefer a larger model, File13 can also use OpenAI, Anthropic, Google, or Perplexity with your own API key. Each provider's row in **Settings → AI** lists exactly what fields are sent and links to that provider's privacy policy.")

        HelpCallout(.privacy, "Whichever provider you choose, File13 never sends message bodies, attachments, or recipient addresses (beyond yours and the sender's). Apple Foundation Models is the strongest privacy posture; third-party providers see your metadata under that provider's terms.")
    }

    // MARK: - Privacy

    @ViewBuilder private var privacy: some View {
        HelpParagraph("Privacy is the whole reason File13 exists. Most mail-triage tools route your mail through their own servers and read the body of every message. File13 doesn't.")

        HelpHeading("Headers only, never bodies")
        HelpParagraph("File13 fetches IMAP envelope data — sender, subject, date, flags, message-id, list-headers — and nothing else. There is no code path that downloads message bodies, attachments, or inline images. This is a load-bearing design choice, not a setting you can toggle.")

        HelpHeading("No developer servers")
        HelpParagraph("File13 has no backend. There is no \"File13 account.\" Nothing about your inbox is ever sent to the developer. The app is a direct client between your Mac and your mail server, plus optionally an AI provider you choose.")

        HelpHeading("Where data flows")
        HelpBullet("**Your mail server.** Standard IMAP over TLS.")
        HelpBullet("**Your AI provider, if configured.** Metadata only, never bodies. Apple's on-device model means the data stays on your Mac.")
        HelpBullet("**Unsubscribe targets you click.** One-click HTTPS POST to the sender's published endpoint, or a `mailto:` handed to your default mail client.")
        HelpBullet("That's the complete list. No analytics, no telemetry, no crash reporting beacons.")

        HelpHeading("No sending")
        HelpParagraph("File13 does not implement SMTP. It cannot send mail on your behalf under any circumstance. Unsubscribe replies that need a `mailto:` are handed off to your default mail client, which composes and sends them with your supervision.")

        HelpHeading("iCloud sync covers settings only")
        HelpParagraph("If you turn on **Sync settings with iCloud** in **Settings → General**, File13 mirrors a narrow allowlist of preferences across your Macs — your account list (without passwords), rules, AI preferences, triage state (categories, VIPs, dismissals), and UI choices. **Cached email headers are never synced.** Each Mac fetches its own headers directly from your mail server.")

        HelpCallout(.privacy, "If you want a full audit, the privacy claims on this page are documented in the project's `CLAUDE.md` privacy contract, which the codebase enforces by design.")
    }

    // MARK: - Security

    @ViewBuilder private var security: some View {
        HelpParagraph("File13 is sandboxed, signed, and stores credentials in the system Keychain. Here's what that means in practice.")

        HelpHeading("Where your password lives")
        HelpParagraph("Every IMAP password — including app-specific passwords — is written to the macOS Keychain, protected by your Mac's login credentials and Secure Enclave on supported hardware. File13 never writes the password to disk anywhere else and never sends it anywhere except your mail server during sign-in.")

        HelpHeading("iCloud Keychain sync (opt-in)")
        HelpParagraph("If you enable **Sync passwords with iCloud Keychain** in **Settings → General**, your IMAP passwords and AI API keys become synchronizable across your Apple devices via Apple's system-level iCloud Keychain. This is independent of the regular settings sync — you can enable one without the other. Without iCloud Keychain sync, each Mac stores its passwords device-only.")

        HelpHeading("App sandbox")
        HelpParagraph("File13 runs inside Apple's App Sandbox. It can talk to the network (for IMAP), read and write its own App Group container, and access its own Keychain entries. It has no access to other apps' data, to arbitrary parts of your filesystem, or to your contacts, calendar, photos, etc.")

        HelpHeading("The bundled CLI")
        HelpParagraph("File13 ships a `file13` command-line tool inside the app bundle. It's signed with the same developer identity as the app and shares the same Keychain access group, so it sees the mailboxes you've already added. Installing it via **Edit → Install File13 CLI…** requires File13 Pro.")

        HelpHeading("OAuth status")
        HelpParagraph("File13 includes scaffolding for OAuth sign-in but doesn't enable it for any provider today. Major providers gate IMAP OAuth behind verification requirements that aren't feasible for an indie app — Gmail requires an annual security audit, Microsoft requires a paid enterprise tenant. Every account today signs in with an app-specific password. The privacy and security properties are identical either way.")
    }

    // MARK: - Shortcuts

    @ViewBuilder private var shortcuts: some View {
        HelpParagraph("File13 is designed to be driven from the keyboard. The most useful shortcuts:")

        HelpShortcutGrid([
            ("Selection",
             [("Select all visible", "⌘", "A"),
              ("Clear selection", "⎋", nil),
              ("Toggle focused row", "Space", nil),
              ("Move focus", "↑ ↓", nil),
              ("Expand / collapse row", "→  ←", nil)]),
            ("Actions",
             [("Delete selection", "⌘", "⌫"),
              ("Undo last action", "⌘", "Z"),
              ("Refresh inbox", "⌘", "R"),
              ("Run rules now", "⇧⌘", "R")]),
            ("Windows",
             [("Settings", "⌘", ","),
              ("Help", "⌘", "?"),
              ("Close window", "⌘", "W")]),
        ])
    }

    // MARK: - Troubleshooting

    @ViewBuilder private var troubleshooting: some View {
        HelpHeading("Sign-in fails with \"authentication failed\"")
        HelpParagraph("Almost always means your provider needs an app-specific password instead of your regular account password. See the **Add Your Mail Account** page for provider-specific links.")

        HelpHeading("First sync is slow")
        HelpParagraph("Expected. The first pass fetches headers for every cached message. Subsequent refreshes only fetch what changed and finish in seconds. If a sync seems stuck, check the per-mailbox progress indicator in the sidebar — File13 fetches one mailbox at a time per account.")

        HelpHeading("An action didn't show up in another mail app")
        HelpParagraph("File13 buffers actions locally before committing to your mail server. If you check another mail app within the undo window (default 30 seconds), the change won't be visible yet. After the buffer expires, the server is updated and other clients catch up on their next sync.")

        HelpHeading("A rule didn't run on a message I thought it would match")
        HelpParagraph("Two likely causes. First, the message's sender is a VIP or the subject matched the transactional protection — both protect against rule deletions by default. Second, the rule's scope might not cover the folder the message lives in. Open **Settings → Rules**, click the rule, and verify both **Scope** and the protection toggles.")

        HelpHeading("Apple's on-device AI says it's unavailable")
        HelpParagraph("Apple Foundation Models requires Apple Intelligence to be enabled on your Mac and a supported device. Open System Settings → Apple Intelligence & Siri to enable it. If the model is still downloading after enabling, the **AI** settings tab will show a progress indicator until it's ready.")

        HelpHeading("The CLI says \"another File13 process is running\"")
        HelpParagraph("The GUI takes a lock on the shared data container so the CLI and GUI can't write concurrently. Quit the GUI to use the CLI, or vice versa.")
    }
}

// MARK: - Layout primitives

private struct HelpHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .padding(.top, 10)
    }
}

private struct HelpParagraph: View {
    let markdown: AttributedString
    init(_ text: String) {
        self.markdown = (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
    var body: some View {
        Text(markdown)
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HelpBullet: View {
    let markdown: AttributedString
    init(_ text: String) {
        self.markdown = (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.system(size: 14))
                .foregroundStyle(.tint)
            Text(markdown)
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
    }
}

private struct HelpCallout: View {
    enum Kind {
        case tip, privacy, warning

        var symbol: String {
            switch self {
            case .tip:     return "lightbulb.fill"
            case .privacy: return "hand.raised.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .tip:     return .accentColor
            case .privacy: return .green
            case .warning: return .orange
            }
        }
    }

    let kind: Kind
    let markdown: AttributedString

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.markdown = (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .frame(width: 18)
            Text(markdown)
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(kind.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(kind.tint.opacity(0.25))
        )
    }
}

private struct HelpShortcutGrid: View {
    /// Each tuple is (group title, [(label, modifier, key?)]).
    /// `modifier` carries the leading glyphs (⌘, ⇧⌘, ⎋, etc.). When `key`
    /// is `nil`, `modifier` is rendered as a single key cap.
    typealias Row = (label: String, modifier: String, key: String?)
    typealias Group = (title: String, rows: [Row])

    let groups: [Group]
    init(_ groups: [Group]) { self.groups = groups }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.label)
                                .font(.system(size: 14))
                            Spacer(minLength: 12)
                            if let key = row.key {
                                HelpKey(row.modifier)
                                HelpKey(key)
                            } else {
                                HelpKey(row.modifier)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HelpKey: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.separator)
            )
    }
}

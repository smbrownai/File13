# Security

The full threat model and privacy contract live in [CLAUDE.md](CLAUDE.md)
under "Privacy contract — load-bearing." Short version: metadata only,
no message bodies ever cross the network to the AI provider, no SMTP,
credentials stay in the Keychain, iCloud sync covers settings and not
mail.

This file tracks **outstanding security follow-ups** — work that's been
identified, scoped, and consciously deferred, with enough context that
someone (or some future Claude) can pick it up cold.

Item numbers are position-stable across commits (a completed item's
slot stays, the entry moves to the "Resolved" section below). That's
why the numbering has gaps — `#3` / `#4` / `#5` / `#8` / `#9` / `#11b`
are in "Resolved" rather than missing. The numbering is a reference
for past commits / PR descriptions, not a priority order.

## Reporting a vulnerability

If you find a security issue, email `shawn@smbrown.org` with details.
Please don't open a public GitHub issue for anything that looks
exploitable — give us a chance to fix it first.

## Outstanding follow-ups

### 1. Populate TLS SPKI pins for LLM providers

**Severity:** Informational under the typical threat model (a CA-issued
attacker certificate would still pass system trust). Real concern
against advanced adversaries with cert-authority cooperation.

**Where:** [`LLMURLSession.swift`](Packages/File13Core/Sources/File13Core/LLMURLSession.swift)
→ `LLMTLSPins.pinsByHost`. The pinning delegate is fully wired and
correct; the dictionary values are just empty sets right now, so the
delegate falls back to system ATS validation.

**What to do:**
1. For each provider — `api.anthropic.com`, `api.openai.com`,
   `generativelanguage.googleapis.com`, `api.perplexity.ai` — fetch the
   live cert chain and compute the SPKI SHA-256 hashes for the
   intermediate + leaf via the `openssl` recipe at the top of
   `LLMURLSession.swift`.
2. Populate **primary + at least one backup pin** per host. Pinning to
   the root makes CA rotation hard; pinning to the leaf alone breaks on
   Let's Encrypt-style 90-day rotations.
3. Run the full app's AI feature suite end-to-end against each provider
   in Release to confirm no false rejections.
4. Document the rotation playbook in this file before shipping — when a
   provider rotates and the pin set goes stale, the AI features 503 on
   every device until we ship a hotfix. Have a checked-in script that
   re-fetches and validates the pin set against the live chain.

**Why it's deferred:** Pinning is an operational commitment, not a
code change. Wrong pins == every user's AI features break with no
remediation path other than a forced app update. Worth getting right
before ship; not worth getting wrong in a hurry.

---

### 2. Restrict `AccountStore.applySyncedAccounts` to existing UUIDs

**Severity:** Defense in depth. The accounts-banner per-field diff
(landed in commit `587f9d4`) already exposes a host-flip to the user;
this would shrink the attack surface further by requiring a separate
confirmation path for *new* accounts vs. *modifications to existing
ones*.

**Where:** [`AccountStore.applySyncedAccounts(from:)`](Packages/File13Core/Sources/File13Core/AccountStore.swift)
in File13Core, and the wrapping
[`PendingAccountChangesBanner`](File13/Views/Settings/PendingAIChangesBanner.swift)
in the macOS app.

**Threat scenario:** An attacker who controls the user's iCloud KV
store today can inject a *brand-new* account record with a malicious
host. The user sees the banner, sees "added: …" lines, and may approve
if the displayName looks plausible. Splitting the path forces a higher
bar for genuinely-new accounts.

**What to do:**
1. In `applySyncedAccounts`, replace the full-list replacement with
   per-account merge: for each incoming UUID, only allow modifications
   to an existing local UUID (host/port/username changes go through the
   current banner). New UUIDs are quarantined as a separate
   `PendingNewAccounts` collection.
2. Add a sibling banner (`PendingNewAccountsBanner`) for the
   add-an-account path, with a stronger "this is a brand-new account,
   you almost certainly did not add this from another device" warning
   and a per-account toggle.
3. Removed accounts (local UUIDs missing from the incoming list)
   probably want the same treatment — a single deletion should be
   noticed.

**Why it's deferred:** It's a UX surface, not a code-shape change.
Worth doing alongside any larger settings-sync rework, and the existing
banner already surfaces enough of the change for the high-confidence
attack (host-flip) that the marginal value is small.

---

## Resolved

History of fixed security issues, newest first. Useful for
understanding *why* a given pattern in the codebase looks the way it
does.

- **2026-05-19 (commit `587f9d4`)** — `PendingAccountChangesBanner`
  surfaces per-account `host`/`port`/`username` diffs instead of just
  the account count; closes the silent host-hijack path through
  iCloud KV.
- **2026-05-19 (commit `587f9d4`)** — `KeychainStore.saveOAuthTokens` /
  `loadOAuthTokens` route the JSON payload through `Data` with
  `memset_s` zeroing instead of materializing as a non-zeroable Swift
  `String`. Closes a dormant memory-hygiene gap for OAuth tokens.
- **2026-05-19** — Added `PrivacyInfo.xcprivacy` to both macOS and iOS
  app targets. Declares `NSPrivacyAccessedAPICategoryUserDefaults`
  (reason `CA92.1`) and `NSPrivacyAccessedAPICategoryFileTimestamp`
  (reason `C617.1`), no tracking, no collected data types. Required
  for App Store / TestFlight submission.
- **2026-05-19** — `File13Core` and the CLI's `file13`
  executableTarget now build under Swift 6 strict-concurrency
  (`.swiftLanguageMode(.v6)`). Clean — no data-race or Sendable
  warnings in the whole tree. Catches future drift at compile time
  instead of in production.
- **2026-05-19** — `InspectorView.MessageList` and
  `InspectorView.ClusterMessageList` switched from eager `VStack` to
  `LazyVStack`. SwiftUI no longer allocates a `Row` struct for every
  message in a sender; only visible rows render. Removes the scaling
  cliff at ~5k messages per sender.
- **2026-05-19** — `FileBackedUserDefaults.persist()` no longer
  silently swallows write failures. Logs to the unified system log
  (Console.app / sysdiagnose) and posts
  `Notification.Name.fileBackedDefaultsWriteFailed`. `File13App`
  observes the notification and surfaces "Couldn't save settings — …"
  on the main banner. Closes a silent-data-loss path on disk-full.
- **2026-05-19** — Trap-surface audit. The single
  potentially-unsafe site (`actionsByRule[$0.id]!` in
  `RulesRunEngine.swift`) was migrated to `compactMap` so a future
  refactor that lets a rule slip through silently absents it from
  the report instead of crashing the run. Three fragile-but-safe
  force-unwrap patterns (`SidebarView.depth`, `CreateFolderSheet`,
  `iOSAISettingsView.ensureValidModel`) got invariant-documenting
  comments so future contributors don't refactor away the guard.
- **2026-05-19** — Empty `Localizable.xcstrings` added to both app
  targets. `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` and
  `SWIFT_EMIT_LOC_STRINGS = YES` are already on; the catalog gets
  populated by Xcode the next time someone opens it. Sets up the
  v2.x add-a-language path without changing v1.0 behavior.
- **2026-05-19** — Privacy-contract regression test. Three Swift
  Testing cases in
  [`PrivacyContractTests.swift`](File13Tests/PrivacyContractTests.swift)
  read `SwiftMailIMAPClient.swift` at test time, strip `//` comments,
  and assert (a) no body-fetching SwiftMail API names are called,
  (b) no `BODY[…]` / `RFC822.TEXT` / `BODYSTRUCTURE` tokens appear
  in non-comment code, (c) the slim-fetch path remains in use.
  Locks in the metadata-only invariant against future commits.
- **2026-05-19** — New `ConnectionState.offlineWithCache(String)`
  case distinguishes "connect failed, cached headers visible" from
  the previous misleading `.connected`-with-`lastError` state.
  `AccountSession.handleConnectError(hadCache: true)` now uses it;
  `SidebarView`'s glyph renders a gray `wifi.slash` instead of the
  green "active" treatment; `InboxStore.connectionState` aggregator
  surfaces it at the inbox level; iOS message list and connect-flow
  switches handle it. `EditAccountSheet.submit` treats it as an error
  (an edit that lands the session offline-with-cache means the new
  credentials don't actually work). Closes the audit's "offline cache
  invisible" finding more accurately than the original framing: the
  cache *was* showing; what was missing was the visual signal that
  the connection itself wasn't live.
- **2026-05-19** — Per-account context menu on the macOS sidebar with
  an "Edit Account…" / "Re-enter Password…" item. Label changes
  based on session state so users hitting a Gmail / Outlook /
  Yahoo app-password revocation (the most common credential repair
  scenario) see the right affordance without having to navigate to
  Settings → Accounts and without losing local triage state.
- **2026-05-19** — `AccountSession.lastFetchWasIncomplete` flag set
  when a mid-stream IMAP fetch fails (typically WiFi drop during
  sync). The currently-viewed mailbox row in the sidebar now renders
  a yellow warning glyph with a tooltip explaining "Last fetch
  ended early — count shown is partial. Refresh to load the rest."
  Without this, the user might delete / archive / run rules against
  what they think is the full inbox.
- **2026-05-19** — `MockInbox.generateScaled(targetCount:)` synthetic
  large-fixture generator + three perf-regression tests in
  `InboxStoreScaleTests.swift`: fixture-generation canary,
  `groupedBySender` < 500 ms on 50k headers, `headersById`
  Dictionary build < 100 ms. Locks in the aggregate-cache pattern
  documented in CLAUDE.md against future O(N²) regressions.
- **2026-05-19** — `NSApplicationDelegate.applicationShouldTerminate`
  hook in new `File13AppDelegate`. Cmd+Q during the 30s undo
  buffer of a Delete / Archive / Move now commits the pending
  action to the server before exit (UX call: silent commit,
  matching Mail.app / Finder; quit is a strong "I'm done" signal
  — if the user wanted to cancel they'd hit Undo, not Cmd+Q).
  Also calls `CloudKVSyncMirror.flush()` so iCloud KV dirty flags
  go out before the next launch, eliminating the multi-Mac sync
  lag on edit-then-quit. Returns `.terminateLater` while the
  async commit awaits; AppKit's ~10s grace window is plenty for
  an IMAP MOVE / EXPUNGE batch. Logs via the unified system log
  so post-quit diagnostics are visible in Console.app.

---

## Outstanding follow-ups, part 2 — pre-1.0 polish

A separate batch of pre-ship reviews (accessibility, error UX, App
Privacy Manifest) produced a few items that were too big to fold into
the same commit as the smaller fixes.

### 6. Dynamic Type coverage sweep (accessibility)

**Severity:** Low–Medium. A handful of fixed-point fonts
(`.font(.system(size: 11))`, `.font(.system(size: 32))` etc.) ignore
the user's Larger Text setting. Confined to chip labels, icon-sized
decorative glyphs, and a few InspectorView indicators.

**Where:** Grep `\.font(\.system(size:` across `File13/` and
`File13iOS/`. Several legitimate uses for non-text glyphs (icons
sized to align with adjacent text), but the chip-label sites should
migrate to semantic styles (`.caption2`, `.caption`, `.callout`).

**Why deferred:** Long tail of small touches; better as a focused
"Dynamic Type polish" branch than scattered into mixed commits.

### 7. SwiftData corrupt-cache recovery (error UX)

**Severity:** Low (rare). If the `MessageCache` SQLite file is
corrupt or the schema doesn't migrate, the macOS app's `ModelContainer`
init throws and there's no recovery path — the user has to manually
clear the cache from `~/Library/Containers/...`.

**Where:** [`File13App.swift`](File13/File13App.swift) +
[`MessageCache.swift`](Packages/File13Core/Sources/File13Core/MessageCache.swift).

**What to do:** Catch ModelContainer init failure, delete the
corrupted file, retry. Show a banner: "Rebuilt message cache — one
full refresh in progress" so the slowness is expected.

### 10. SwiftData schema versioning explicit

**Severity:** Low (today's safety, future footgun). The
`CachedMessage` model relies on additive-only changes for
lightweight migration; there's no `VersionedSchema` / 
`SchemaMigrationPlan`. A future commit that removes or retypes a
field will silently fail the SwiftData fetch and trigger a full
re-fetch on next launch — slow but not lossy. The constraint is
implicit and a future contributor wouldn't know.

**Where:** [`CachedMessage.swift`](Packages/File13Core/Sources/File13Core/CachedMessage.swift) +
[`MessageCache.swift`](Packages/File13Core/Sources/File13Core/MessageCache.swift).

**What to do:** Add a doc comment above `CachedMessage` documenting
the additive-only invariant. Optionally migrate to `VersionedSchema`
proactively so the migration plan is explicit for the first breaking
change.

### 11a. Hardcoded English plurals across views

**Severity:** Low (en-only v1.0). Eleven sites use the
`count == 1 ? "" : "s"` / `count == 1 ? "y" : "ies"` shape to
inflect English plurals. This pattern doesn't survive translation —
Polish has three plural forms, Russian has four, Arabic has six.
Inline-plural sites need to migrate to Foundation's
grammar-agreement syntax (`String(localized: "^[\(count) message](inflect: true)")`)
before any non-English language is added.

**Where:** Eleven sites across [InspectorView.swift](File13/Views/InspectorView.swift),
[ActivityView.swift](File13/Views/ActivityView.swift),
[SenderTable.swift](File13/Views/SenderTable.swift),
[UnsubscribeSheet.swift](File13/Views/UnsubscribeSheet.swift),
[ContentView.swift](File13/ContentView.swift),
[UndoBanner.swift](File13/Views/UndoBanner.swift). Grep:
`grep -rnE 'count == 1 \? "" : "s"|count == 1 \? "y" : "ies"' File13/`.

**What to do:** Replace inline `count == 1 ? "" : "s"` with
`String(localized: "^[\(count) message](inflect: true)")` or
`AttributedString(localized: ...)` for SwiftUI `Text(...)` use.
Three string-concatenation sites
(`SuggestionsSheet.swift`, `RulesSettingsView.swift`,
`HelpTopics.swift`) using `Text("…" + " → " + "…")` also need
migration to single localized format strings — the catalog can't
match a string built by `+`.

**Why deferred:** En-only v1.0 has no user-visible bug. Migration
is mechanical but cuts across many files; cleanest as a dedicated
i18n branch.


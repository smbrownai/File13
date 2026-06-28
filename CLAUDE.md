# File13 — agent map

A native macOS IMAP triage app. Connects to one or more accounts, fetches **headers
only** (never bodies), and surfaces engagement signals + AI assistance to help the user
delete, archive, unsubscribe, or rule-automate at scale.

## Build & test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project File13.xcodeproj -scheme File13 \
  -configuration Debug -destination 'platform=macOS' build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project File13.xcodeproj -scheme File13 \
  -configuration Debug -destination 'platform=macOS'
```

The unit-test target uses **Swift Testing** (`import Testing`, `@Test`, `#expect`).
UI tests use plain XCTest and only contain a launch-performance benchmark.

## Privacy contract — load-bearing

- **Metadata-only.** We send headers, sender addresses, subjects, list-* headers, dates,
  flags, and read state to the AI provider. We **never** read or send message bodies, and
  we don't have SMTP — the app cannot send mail. This is the whole privacy story; if you
  add a feature that crosses this line you've changed the product.
- The Privacy & Data settings tab was removed deliberately. There's no toggle to enable
  body downloads. Don't add one back.
- Apple Foundation Models is the default provider for the strongest privacy posture
  (on-device / Private Cloud Compute). Third-party providers (Anthropic, OpenAI, Google,
  Perplexity) all run with the user's own API key — see [`AI/`](File13/AI/).
- **iCloud sync (opt-in) covers settings only, never email data.** When the user enables
  "Sync settings with iCloud" in Settings → General, the GUI mirrors a narrow allowlist of
  `UserDefaults` keys to `NSUbiquitousKeyValueStore` — accounts list (without passwords),
  rules, AI preferences, triage state (categories / VIPs / dismissals / replied-message
  ids), UI preferences. The cached headers (`MessageCache`, SwiftData), UID validity, fetch
  progress, and Keychain credentials never cross *this* sync path. The allowlist lives
  in [`CloudKVSync.swift`](Packages/File13Core/Sources/File13Core/CloudKVSync.swift) —
  if you add a new store, decide *explicitly* whether its key belongs on that list.
  `MessageCache`'s `ModelConfiguration` is `init(url:)` only, never `init(... cloudKitDatabase:)`;
  do not add the second form.
- **CLI — distributed via Homebrew, not bundled.** The `file13` CLI
  ships as a standalone Apple Developer ID-signed + notarized binary
  via the `smbrownai/file13` Homebrew tap. **The MAS .app does not
  carry the CLI binary.** An earlier iteration bundled it inside
  `File13.app/Contents/Resources/file13`, but MAS validator code
  90296 requires `app-sandbox=true` on every embedded executable, and
  a sandbox-claiming binary launched from a Terminal symlink (outside
  its host app bundle) gets SIGTRAPed by the OS at startup. The split
  was the only way to make both surfaces work.
  Users surface the install instructions via **Edit → Install File13
  CLI…**, which presents
  [`InstallCLIView`](File13/Views/InstallCLIView.swift) — a sheet
  with a copy-paste `brew install smbrownai/file13/file13` command
  and a note that mailbox passwords must be re-added via `file13
  accounts add` (the only cross-bundle state that doesn't transfer).
  Release automation lives at
  [`.github/workflows/release-cli.yml`](.github/workflows/release-cli.yml),
  triggered by `cli-v<semver>` tag pushes. See
  [`.github/RELEASE-CLI.md`](.github/RELEASE-CLI.md) for the secrets
  setup and the manual tap-update step.
  The standalone CLI binary is signed with **no restricted
  entitlements** — see
  [`cli/file13.entitlements`](cli/file13.entitlements) for the
  full reasoning. App Groups and keychain access groups are restricted
  entitlements that require an embedded provisioning profile; bare
  Mach-O binaries can't carry one, so amfid refuses to launch them
  with `Error Code=-413 "No matching profile found"`. The CLI works
  around this:
    - **App Group container**
      (`~/Library/Group Containers/group.com.shawnbrown.File13/`) is
      reachable as a plain filesystem path. Any user-owned process can
      read/write the directory tree without needing the entitlement,
      so settings, accounts, rules, replied-message tracking, and the
      `File13.license.cachedTier` license cache all flow GUI → CLI
      automatically.
      `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
      still resolves the path even without the entitlement.
    - **Keychain entries** are the one thing that can't cross. The
      CLI manages its own entries in the default user keychain (no
      access group); the GUI's entries live in the
      `YRB6VBTSRV.com.shawnbrown.File13` access group. Re-add
      accounts on the CLI side via `file13 accounts add` to enter
      passwords separately. The InstallCLIView calls this out so
      users know to expect it.
  License gating still works end-to-end:
  `CLILicenseReader.requirePro()` reads `File13.license.cachedTier`
  from App Group `UserDefaults`, which the GUI's `LicenseStore` writes
  after a StoreKit purchase. Free users get the same "version + doctor
  only" gating as before — install is unrestricted (Homebrew is open),
  but every other subcommand exits 4 without a Pro purchase recorded
  in the cache.
- **IAP — File13 Pro, $14.99 one-time, Mac App Store only.** Single
  non-consumable IAP at `com.shawnbrown.file13.pro` with Universal
  Purchase + Family Sharing enabled. Free tier = 1 mailbox on any
  number of Apple platforms (Universal Purchase, free). Pro adds two
  things: unlimited mailboxes, and the bundled `file13` CLI in its
  entirety. There is no platform gate.
  [`LicenseStore`](Packages/File13Core/Sources/File13Core/LicenseStore.swift)
  is the source of truth. On bootstrap it reads
  `Transaction.currentEntitlements` from StoreKit, fetches the
  locale-formatted `displayPrice` via `Product.products(for:)`, and
  starts `Transaction.updates` observation. `tier` is cached in App
  Group `UserDefaults` under `File13.license.cachedTier` so the CLI
  can read it without StoreKit.
  Single paywall surface — [`PaywallSheet`](File13/Views/PaywallSheet.swift)
  (always dismissible), launched from `AddAccountSheet.submit` when
  `!canAddAccount(currentCount:)`, from the Settings "Upgrade to Pro"
  button, or from an iOS install entry point. The sheet button reads
  `license.displayPrice` — never hard-code the price in a view; the
  string comes from StoreKit so local currency works out of the box.
  **CLI is fully Pro-gated.** Every leaf subcommand calls
  `try CLILicenseReader.requirePro()` at the top of its `run()` and
  exits 4 on `.free`. Exemptions: `file13 version` and `file13
  doctor`, so non-Pro users can still confirm install and provider
  availability before purchasing. The reader pulls `tier` from the
  shared `UserDefaults` the GUI writes after a StoreKit purchase, so
  the GUI is the only path that mutates license state.
  **Debug builds short-circuit** `tier = .pro` in
  `LicenseStore.bootstrap()` (`#if DEBUG`) so developers don't ferry
  sandbox Apple IDs around. To see the paywall in dev: build Release.
  Threat-model leak intentionally accepted: a determined user can poke
  `UserDefaults` to fake Pro — the price point and one-time nature
  make piracy uneconomic.
  *Still needed before shipping IAP end-to-end:* create the IAP product
  in App Store Connect (id, type non-consumable, $14.99, Family Sharing
  on, Universal Purchase enabled at app level), wire `File13.storekit`
  to the scheme (Edit Scheme → Run → Options → StoreKit Configuration).
- **OAuth — scaffolding only, no providers wired (2026-05-11).** Every
  candidate hit a distribution-time wall: Gmail's `mail.google.com/` scope
  requires an annual CASA security audit (~$15k+/year); Microsoft's
  Publisher Verification requires a paid work/school tenant to enroll in
  the Cloud Partner Program; Microsoft also retired basic-auth IMAP for
  personal `outlook.com` / `hotmail.com` / `live.com` accounts in
  September 2024, so even the app-password fallback is mostly dead there.
  iCloud has no IMAP OAuth at all (Apple requires app-specific passwords).
  Yahoo / AOL's third-party OAuth program is effectively closed.
  Every account today authenticates with a password (or app-specific
  password) via `AccountCredentials.auth = .password(...)`.
  **The scaffolding stayed**: `AccountAuth` enum, XOAUTH2 routing in
  `SwiftMailIMAPClient`, [`OAuth2Client` + `OAuthFlow`](Packages/File13Core/Sources/File13Core/OAuth.swift),
  `KeychainStore.OAuthTokens` and its iCloud-Keychain migrator,
  `AccountStore.addOAuth`, and the async `credentials(for:)` (refresh-on-
  expiry) are all intentionally still in place. To re-enable OAuth for a
  new provider: add a case to `Account.AuthKind`, add a config to
  `OAuthProviderCatalog`, register a redirect URI scheme in
  `File13/Info.plist`'s `CFBundleURLTypes`, and add the sign-in UI to
  [`AddAccountSheet`](File13/Views/AddAccountSheet.swift) (git history
  has the previous Gmail/Microsoft wiring as reference).
- **iCloud Keychain sync (separately opt-in) covers credentials only.** "Sync passwords
  with iCloud Keychain" in Settings → General toggles `KeychainStore.iCloudSyncEnabled`,
  which makes IMAP passwords and AI API keys synchronizable via Apple's system-level
  iCloud Keychain (synced items use `kSecAttrAccessibleWhenUnlocked`; device-only items
  use `…WhenUnlockedThisDeviceOnly`). This is a per-device preference — it's *not* in the
  `CloudKVSync` allowlist on purpose. Flipping the toggle triggers
  `iCloudKeychainSyncMigrator` (wired in `File13App.init`), which delete-and-re-adds
  every existing keychain item with the new flag — `kSecAttrSynchronizable` is part of
  the item's primary key and can't be flipped via `SecItemUpdate`. Reads/deletes always
  use `kSecAttrSynchronizableAny` so they work regardless of mode. **Don't add a new
  keychain call site that hard-codes `kSecAttrSynchronizable`** — route it through
  `KeychainStore`'s `saveItem` / `loadItem` / `deleteItem` so the toggle is respected.

## Top-level architecture

- **`@Observable @MainActor` stores** own all mutable state. Views read them via
  `@Bindable`. The store is the single source of truth; views are dumb projections.
- Views are organized by responsibility under [`Views/`](File13/Views/), with
  [`Views/Settings/`](File13/Views/Settings/) holding the settings tabs.
- The IMAP layer is in [`Mail/`](File13/Mail/) — `IMAPClientProtocol` abstracts a
  vendored SwiftMail client. `AccountSession` wraps one connection's lifecycle (connect,
  refresh, mailbox switch, etc.). `InboxStore` aggregates across sessions.
- Cached headers are persisted via SwiftData ([`Store/MessageCache.swift`](File13/Store/MessageCache.swift),
  `CachedMessage.swift`). Other stores use UserDefaults JSON.

### Key stores and their persistence

| Store | File | Persistence | Notes |
|-------|------|-------------|-------|
| `InboxStore` | `Store/InboxStore.swift` | none (rebuilt) | Aggregate cache + selection model + scheduled refresh |
| `AccountStore` | `Store/AccountStore.swift` | UserDefaults (accounts) + Keychain (passwords) | |
| `SettingsStore` | `Store/SettingsStore.swift` | UserDefaults | All app preferences |
| `RuleStore` | `Store/RuleStore.swift` | UserDefaults | User-defined cleanup rules |
| `SenderCategoryStore` | `Store/SenderCategoryStore.swift` | UserDefaults | AI-assigned categories per sender |
| `VIPStore` | `Store/VIPStore.swift` | UserDefaults | `auto + pinned − excluded` VIP list |
| `RepliedMessagesStore` | `Store/RepliedMessagesStore.swift` | UserDefaults | Per-account `Set<rawMessageId>` of replied-to messages |
| `SuggestionDismissalStore` | `Store/SuggestionDismissalStore.swift` | UserDefaults | Persistent suggestion dismissals (fingerprint-keyed) |
| `MessageCache` | `Store/MessageCache.swift` | SwiftData | Cached `MessageHeader`s per account/mailbox |

`InboxStore` takes references to the others via init and threads them through where
needed. `File13App` owns the canonical `@State` instances and passes them in.

## Performance — read this before refactoring InboxStore

`InboxStore` has a single big aggregate cache (`_aggregateFP` fingerprint + `_*Cache`
fields, all `@ObservationIgnored`). On every read of `senders`, `subjectClusters`,
`headersById`, `transactionalIds`, etc., `ensureAggregateCache()` compares the current
fingerprint (per-session `headersVersion`, plus filters) against the cached one and
rebuilds if and only if it changed.

Why: SwiftUI re-runs view bodies on every `@Observable` mutation. Without the cache,
every checkbox click would re-group every header in the inbox several times. With it,
heavy work happens once per real header change.

The selection model is **single Set**: `selectedMessageIds: Set<String>`. There used to
be a parallel `selectedSenderIds` set; that's been collapsed because it caused O(N×M)
rebuilds. **Don't reintroduce it.** Sender-row checks materialize the sender's message
ids into the set.

`MessageHeader.isLikelyTransactional` is **memoized at init** (one substring scan, not
36 per read). If you change the heuristic, update both `TransactionalDetector.matches`
and the init in [`Models/Mail.swift`](File13/Models/Mail.swift).

`MessageHeader.isFromDisposableDomain` is **memoized at init** the same way (one
`Set.contains` against ~5,400 domains, not once per row body). Backed by
[`DisposableSenderDetector`](Packages/File13Core/Sources/File13Core/DisposableSenderDetector.swift),
which lazily loads the bundled blocklist resource on first call. The blocklist is the
CC0 [disposable-email-domains/disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains)
dataset, vendored under
[`Packages/File13Core/Sources/File13Core/Resources/disposable_email_blocklist.conf`](Packages/File13Core/Sources/File13Core/Resources/disposable_email_blocklist.conf).
Refresh with [`scripts/update-disposable-domains.sh`](scripts/update-disposable-domains.sh)
before each release. The check runs entirely on-device; nothing about the sender is
sent off-device for this. Exposed as a rule condition (`senderDomainIsDisposable`) but
deliberately **not** a protection toggle — users opt in by writing a rule.

## AI subsystem

- [`AI/LLMProvider.swift`](File13/AI/LLMProvider.swift) — protocol, error types, and
  the `ProviderAvailability` enum. All providers conform.
- Provider implementations: `AppleFoundationModelsProvider` uses `@Generable` for
  structured output; `Anthropic`, `OpenAI`, `Google`, `Perplexity` use plain
  `generate(systemInstructions:userPrompt:)` and the call sites parse JSON from the
  response (see `extractJSONObject` in `SenderAdvisor`/`SenderCategorizer`/`RuleSuggester`).
- `LLMProviderFactory.make(kind:settings:)` dispatches based on the user's selected
  provider in `SettingsStore`.

### AI feature pipeline

1. **Per-sender triage** — `SenderAdvisor` (one sender → one advice).
2. **Sender categorization** — `SenderCategorizer` (batches of ~25 senders → category each).
3. **Rule suggestions** — `RuleSuggester`. Two paths:
   - **Bulk** (`suggest(senders:…)`) — picks a mix of high-volume + low-engagement senders,
     filters VIPs out of the prompt pool entirely (defense in depth).
   - **Per-sender** (`suggest(forSender:…)`) — drills into one sender with more context.
   Both feed the model `replies=N` and a `VIP` signal so the system prompt's "never
   propose destructive actions on VIPs / replied-to senders" rule has data to lean on.
4. **VIP detection** — `VIPDetector` is pure-heuristic, not LLM. Reply-path
   (≥ 2 replies) wins; read-rate fallback (≥ 90% / ≥ 5 messages) for senders without
   reply data. Excluded categories (news, promotional, notifications, social) and
   newsletter signals disqualify regardless.

### How the AI features compose at runtime

```
headers ──► (categorize) ──► SenderCategoryStore
        ──► (refresh sent) ─► RepliedMessagesStore  ──► AccountSession.repliedMessageIds
        ──► (detect VIPs)  ─► VIPStore  ──► (effective)
                                          │
                                          ▼
                            RuleSuggester sees: read rate, replies, VIP flag, category
                                          │
                                          ▼
                            InboxStore.runRules: skips VIPs (when setting on), evaluates
                                                 per-rule conditions including category
```

## UI structure

`ContentView` hosts a `NavigationSplitView` with:
- **Sidebar** — mailboxes (`SidebarView`).
- **Detail** (the `VSplitView`):
  - Top: banners, the chosen list view (`SenderListView` / `SubjectListView` /
    `DateListView`), then `BulkActionBar` at the bottom.
  - Bottom (when toggled from the toolbar): `ActivityView` — the AI dashboard.
- **Inspector** (right side, toggleable): `InspectorView` — dispatches on
  `inspectedSenderId` or `inspectedSubjectClusterId` to show `SenderInspector` /
  `ClusterInspector`. Mutually exclusive: tapping either type clears the other.

The activity drawer is `VSplitView`-based on purpose — pure-SwiftUI drag handles
ghosted on resize for this subtree (Charts + materials + ScrollView). NSSplitView
handles drag-resize natively. **Don't replace VSplitView with a SwiftUI custom
divider.** See the long discussion in commit history if tempted.

## Conventions

- All persistent stores use a `File13.<feature>.v1` UserDefaults key. Bump the
  version suffix on incompatible schema changes; prefer additive migrations otherwise.
- Run-actions (`startDelete`, `archiveSelection`, `moveSelection`) are
  optimistic + buffered. They mutate local headers immediately and schedule a Task
  that commits to the server after `settings.undoBufferSeconds`. Pending action lives
  on `InboxStore.pendingAction`; `undoPendingAction()` rolls back from the snapshot
  stored in `PendingAction.PerAccount.snapshotHeaders`.
- VIP and transactional protections are evaluated **inside `InboxStore.runRules`**, not
  inside `RuleEvaluator.matches`, so manual selections are unaffected (the user is
  explicit). Both protections are settings-toggle gated.
- Suggestion dismissal is fingerprint-based (conditions + outcome canonicalized to a
  string). Two suggestions with the same intent collapse to the same fingerprint even
  if the LLM writes different titles or rationales.
- Reply detection is **manual and opt-in**. Sent-folder fetches are heavy; we don't run
  them automatically.

## Gotchas

- `@Observable` macro doesn't always cooperate with property observers (`didSet`).
  `AccountSession` uses explicit `setHeaders` / `mutateHeaders` helpers instead of
  relying on a `didSet` to bump `headersVersion` — preserve that pattern.
- `RuleEvaluator.matches` takes a `categoryFor: (String) -> SenderCategory?` closure.
  Callers should snapshot the category map once before a tight loop, not call into the
  observable store per-message.
- `SenderCategorizer.categorize` is `@MainActor`. The progress callback runs on the
  main actor — do **not** wrap it in `Task { @MainActor in … }` (a previous bug: the
  queued task ran after the surrounding `defer` reset, leaving the spinner stuck).
  See `runCategorization` in `ActivityView`.
- `VSplitView`'s height changes go through AppKit, not SwiftUI's diff. That means
  the bottom drawer's height can change without re-evaluating `ContentView`'s body.
  Don't add `@State` drawer height in `ContentView` — it will trigger the entire
  ContentView body re-render per drag pixel.

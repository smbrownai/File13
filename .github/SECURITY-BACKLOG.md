# Security audit backlog

Internal tracking of findings from the codebase security/privacy audit
(2026-06-30). **Not published** — keep out of `docs/` (that directory syncs
to the public site). The public vuln-reporting policy lives in
[`SECURITY.md`](../SECURITY.md).

Audit scope: full codebase, five adversary-focused passes — privacy/AI data
flow, credentials/Keychain, network/TLS/SSRF, the iCloud-compromise sync
threat model, and untrusted-input parsing/injection/CLI. **No Critical or
High findings.** The core guarantees (headers-only, no SMTP, metadata-only
AI, credential isolation, sync gating) all held.

## Fixed (2026-06-30)

| ID | Sev | What | Fix |
|----|-----|------|-----|
| **M1** | Medium | `File13.rulesSchedule` synced last-writer-wins, ungated — an iCloud-compromise could flip `manual`→`hourly`/`onLaunch` and auto-fire a victim's existing destructive rules with no confirmation. | Added `rulesSchedule` to `SyncedSensitiveKeys` (`ruleKeys`); routes through `PendingRuleChangesBanner`; `RuleStore.applySyncedSchedule`. |
| **L1** | Low | One-click unsubscribe redirect guard checked scheme but not host — sender could `302` the no-cred POST to an arbitrary HTTPS host (SSRF primitive). | `HTTPSOnlyRedirectGuard` now also requires the redirect host == original host. |
| **L2** | Low | `KeychainStore.migrateItem` materialized secrets as a non-zeroable `String` on iCloud-Keychain toggle. | Load via `loadItemData` (Data) + `defer { zero(&data) }`. |

## Backlog (Low — not yet fixed)

### L3 — Ungated sync of `preferredBrowserBundleId` / `preferredMailClientBundleId`
- **Where:** `CloudKVSync.swift` allowlist; consumed by `UnsubscribeService` → `NSWorkspace.open(_, withApplicationAt:)`.
- **Risk:** an iCloud-compromise can redirect the victim's unsubscribe/open clicks to a *different already-installed* app. Bounded — resolves only to installed apps, opens the legitimate URL, no arbitrary execution or data leak.
- **Options:** add both keys to `SyncedSensitiveKeys` (own subset + banner), or accept as defense-in-depth-only. Leaning *accept* given the tight bound; revisit if the open-handler surface grows.

### L4 — `dismissedSuggestions.v1` union-merge is ungated
- **Where:** `CloudKVMerge.swift` (union merge).
- **Risk:** injected dismissal fingerprints silently suppress advisory AI suggestions (e.g. a "this rule looks dangerous" prompt). Union-only — can add dismissals, never delete data; impact is suppressing advisory UI, not executing an action.
- **Options:** accept (low impact, union semantics), or cap/gate. Leaning *accept*.

### L5 — `.web` / `.mailto` open lacks a scheme re-check at the `NSWorkspace` sink
- **Where:** `UnsubscribeService.swift` `perform(_:)` / `openExternally`.
- **Risk:** currently safe — `UnsubscribeParser` only ever emits http/https/mailto, so the sink never sees `file:`/`javascript:`. The guarantee just lives one layer up from the sink.
- **Fix (hardening):** assert `url.scheme ∈ {http, https, mailto}` at the dispatch boundary so a future hand-constructed mechanism can't bypass the parser.

### L6 — Vendored SwiftMail `IMAPLogger` would log FETCH header metadata at `.trace`
- **Where:** `Vendor/SwiftMail/.../IMAPLogger.swift`.
- **Risk:** dormant — File13 never calls `LoggingSystem.bootstrap`, and swift-log defaults to a no-op `.info` handler, so `.trace` never fires. LOGIN/AUTH are redacted regardless, and no bodies are ever fetched. Latent only if someone later enables trace logging.
- **Action:** keep dormant; if diagnostic logging is ever added, gate it below `.trace` or strip the inbound-response buffering.

## Accepted / by-design (informational)

- **Google API key in the `?key=` query string** (`GoogleProvider`). Google's *required* auth scheme for the `generativelanguage` endpoint; sent over TLS directly to Google. Other providers use headers. Unavoidable; no action.
- **Prompt injection from sender names/subjects.** Mitigated, not eliminated — fenced + marker-stripped untrusted fields, a system clause, and crucially the destructive scope is **recomputed locally** (not trusted from the model) with VIP/transactional protection and **mandatory manual accept**. No auto-apply path. Inherent LLM best-effort; monitor.
- **Unsubscribe deanonymization** (the sender learns you acted, via per-recipient tokens). Inherent to unsubscribing; disclosed in the unsubscribe sheet UI.
- **`DisplaySanitizer` lets C1 control bytes (U+0080–U+009F) through.** Negligible — UTF-8 C1 don't form bare-ESC ANSI escapes; BiDi/homograph chars *are* stripped. Optional: also strip C1.
- **Synchronizable Keychain items use `kSecAttrAccessibleWhenUnlocked`** (not `…ThisDeviceOnly`). Structurally required — `kSecAttrSynchronizable` is incompatible with `…ThisDeviceOnly`. The default-off posture is the device-only one; this only applies when the user opts into iCloud Keychain sync.
- **CLI keeps its own default-keychain entries** (no access group), isolated from the GUI's access-group items. Apple-enforced boundary; the shared App Group container holds only non-secret config. By design.
- **Cache integrity HMAC** authenticates `uid|isRead|messageId|senderAddress` but not `subject`/`senderName`/`List-*`. Accepted: the only adversary who could rewrite those is a sibling App-Group binary (same user, same Team ID) — outside the email-content adversary model. Documented in `CachedHeadersIntegrity.swift`.

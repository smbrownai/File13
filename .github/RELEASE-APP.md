# Releasing File13 to the App Store

The GUI app ships through the **Mac App Store** (and iOS App Store — same
bundle id, Universal Purchase). Unlike the [`file13`
CLI](RELEASE-CLI.md), which is Developer ID-signed + notarized and
distributed via Homebrew, the App Store build is signed with an **Apple
Distribution** identity and uploaded to App Store Connect — Apple handles
notarization on its side, so there is no separate `notarytool` step.

This is a manual checklist, not an automated workflow. Apple's review
gates the release; nothing here is safe to fully script.

## Project facts (don't re-derive these)

| Thing | Value |
|---|---|
| Team ID | `YRB6VBTSRV` |
| macOS bundle id | `com.shawnbrown.file13` |
| iOS bundle id | `com.shawnbrown.file13` (same → Universal Purchase) |
| IAP product id | `com.shawnbrown.file13.pro` |
| IAP type / price | Non-Consumable / $14.99 (one-time) |
| Marketing version | `1.0` (`MARKETING_VERSION`) |
| Build number | `1` (`CURRENT_PROJECT_VERSION`) — bump per upload |
| App category | Productivity (`public.app-category.productivity`) |
| Privacy manifests | `File13/PrivacyInfo.xcprivacy`, `File13iOS/PrivacyInfo.xcprivacy` (present, declare no data collection) |
| Privacy Policy URL | published `docs/privacy.html` (smbrownai `next` site → `/file13/`) |
| Support URL | published `docs/support.html` |

## 0. One-time account prerequisites

- [ ] Apple Developer Program membership active for team `YRB6VBTSRV`.
- [ ] All **Agreements, Tax, and Banking** sections in App Store Connect
      are in "Active" state — **paid apps and IAPs will not go live** until
      the Paid Applications agreement is signed and banking/tax is complete.
      This is the single most common thing that silently blocks a paid
      release.
- [ ] Xcode signed into the Apple ID for the team
      (Xcode → Settings → Accounts), so it can generate distribution
      certs/profiles. This fixes the local
      `No profiles for 'com.shawnbrown.file13'` build error.

## 1. Certificates & provisioning (one-time, then reuse)

Easiest path is **automatic signing** — with the account added in Xcode,
let it manage the Distribution certificate and "Mac App Store" profile.
If you sign manually:

- [ ] **Apple Distribution** certificate in your keychain.
- [ ] **Mac App Store** provisioning profile for `com.shawnbrown.file13`,
      and the **iOS App Store** profile for the same id.
- [ ] Each profile must carry the app's entitlements: App Group
      `group.com.shawnbrown.file13`, keychain access groups
      (`…file13` + `…file13.shared`), and the iCloud KVS identifier. These
      are defined in `File13/File13.entitlements` /
      `File13iOS/File13-iOS.entitlements`. The App Group, the App ID's
      iCloud (key-value) capability, and the keychain groups must all be
      registered on the App ID in the Developer portal or the profile
      won't include them.

> The standalone CLI is **not** part of this build — the MAS `.app` does
> not embed it (MAS validator code 90296). Don't add an "Embed CLI" phase.

## 2. App Store Connect — app record

- [ ] Create the app record if it doesn't exist: **My Apps → +** →
      New App. Platform: macOS **and** iOS (one record, both platforms →
      Universal Purchase). Bundle id `com.shawnbrown.file13`. Primary
      language, SKU, name **File13**.
- [ ] Set **Category** = Productivity.
- [ ] Add **Privacy Policy URL** and **Support URL** (the published
      `privacy.html` / `support.html`).
- [ ] **App Privacy** questionnaire: the privacy manifests declare
      `NSPrivacyTracking=false` and **no** collected data types. Answer
      consistently — File13 collects no data *for itself*; email metadata
      goes to the user's chosen AI provider under the user's own API key
      (or on-device via Apple Foundation Models). If you declare any data
      type, it must reconcile with the `PrivacyInfo.xcprivacy` files or
      review will flag the mismatch.
- [ ] **Pricing and Availability**: the app itself is **free** (free tier
      = 1 mailbox); revenue is the IAP. Set territories.

## 3. App Store Connect — the In-App Purchase

- [ ] **Features → In-App Purchases → +** → **Non-Consumable**.
- [ ] Product ID **exactly** `com.shawnbrown.file13.pro` (must match
      `LicenseStore` / `File13.storekit`). A typo here = paywall that can
      never complete a purchase.
- [ ] Reference name: `File13 Pro`. Price: **$14.99** tier.
- [ ] **Family Sharing: ON** (the app advertises it).
- [ ] Localized display name + description, and a **review screenshot**
      (required — a shot of `PaywallSheet`).
- [ ] ⚠️ **First-time gotcha:** a brand-new IAP must be submitted **with**
      the app's first version — attach it to the version under
      "In-App Purchases" before submitting. It cannot be reviewed
      standalone before the app's first release.

## 4. Pre-archive code checks

- [x] **Export compliance.** Done — `ITSAppUsesNonExemptEncryption` =
      `false` is set in both `File13/Info.plist` and
      `File13iOS/Info.plist` (the app uses only standard, exempt HTTPS/TLS
      + Keychain), so App Store Connect won't prompt on upload. Revisit
      only if you add custom/non-exempt crypto.
- [ ] Confirm **Release** config: `LicenseStore.bootstrap()` only
      short-circuits `tier = .pro` under `#if DEBUG`, so a Release archive
      enforces the paywall. Build Release once and verify the paywall
      actually appears when adding a 2nd mailbox.
- [ ] Bump `CURRENT_PROJECT_VERSION` if re-uploading the same
      `MARKETING_VERSION` (App Store Connect rejects duplicate build
      numbers).
- [ ] (Optional, for local IAP testing) wire `File13.storekit` into the
      Run scheme — Edit Scheme → Run → Options → StoreKit Configuration —
      or use a Sandbox tester account. Not needed for the shipped build;
      the archive uses the real ASC product.

## 5. Archive & upload

Via Xcode (recommended for the first release):

- [ ] Select destination **Any Mac (Apple Silicon, Intel)**, scheme
      **File13**, Release.
- [ ] **Product → Archive**.
- [ ] In the **Organizer**: **Validate App** first (catches entitlement /
      profile / icon problems before upload), then **Distribute App →
      App Store Connect → Upload**.
- [ ] Repeat for the **iOS** scheme (`File13-iOS`, destination
      "Any iOS Device") if shipping iOS in this release.

Or via command line (build number/signing must already be correct):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project File13.xcodeproj -scheme File13 \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/File13.xcarchive archive

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -exportArchive -archivePath build/File13.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
# then upload build/export/*.pkg with Transporter or `xcrun altool`/notarytool-free App Store upload
```

## 6. Submit for review

- [ ] Create the **version** (1.0) under the app record.
- [ ] Upload **screenshots** (required sizes for macOS and, if shipping,
      iOS), description, keywords, what's-new, promotional text.
- [ ] Attach build (the one you just uploaded; allow ~15–30 min for
      processing) and the **IAP** (first-submission rule, §3).
- [ ] **App Review notes**: this is critical for File13 — reviewers need a
      way to exercise an IMAP app. Provide either a **demo IMAP account**
      (host / app-specific password) or clear steps, and explain the
      **metadata-only, bring-your-own-API-key** model so review doesn't
      flag the AI calls. Note the app has no SMTP and cannot send mail.
- [ ] Submit. Respond fast to any reviewer message — IMAP/AI apps often
      draw a clarifying question.

## 7. After approval

- [ ] Release (manual or automatic per your version settings).
- [ ] Tag the release in git and cut the matching **CLI** release if the
      versions move together (see [RELEASE-CLI.md](RELEASE-CLI.md)).
- [ ] `scripts/publish-docs.sh` to sync `docs/` (privacy/support pages) to
      the live site if anything changed.

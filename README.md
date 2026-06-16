# File13

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A native macOS (and iOS) IMAP triage app that helps you clean up an overflowing
inbox at scale. File13 connects to one or more mailboxes, fetches **headers
only**, and surfaces engagement signals — who you actually read, who you've
replied to, what's transactional, what's a newsletter — alongside optional AI
assistance to categorize senders, detect VIPs, and suggest cleanup rules. From
there you delete, archive, unsubscribe, or rule-automate in bulk. It doesn't
replace your email app; it gives you control over it.

## Privacy contract

File13 is metadata-only by design:

- Fetches **headers only** — never message bodies.
- Sends headers, sender addresses, subjects, `List-*` headers, dates, flags, and
  read state to the configured AI provider. Nothing else.
- Has no SMTP. The app cannot send mail.
- Defaults to Apple Foundation Models (on-device / Private Cloud Compute).
  Third-party providers (Anthropic, OpenAI, Google, Perplexity) run with the
  user's own API key.
- Optional iCloud sync covers settings only — never email data.
- Optional iCloud Keychain sync covers IMAP and AI credentials only.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project File13.xcodeproj -scheme File13 \
  -configuration Debug -destination 'platform=macOS' build
```

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project File13.xcodeproj -scheme File13 \
  -configuration Debug -destination 'platform=macOS'
```

Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`). UI tests
use XCTest and contain a launch-performance benchmark.

## Layout

- `File13/` — app target (Views, Stores, Mail, AI subsystem).
- `Packages/File13Core/` — shared core library.
- `cli/` — `file13` command-line tool, bundled inside the .app and installed
  via **Edit → Install File13 CLI…**.
- `Vendor/` — vendored dependencies (SwiftMail).
- `scripts/` — build-phase helpers (CLI embedding, signing).

See [`CLAUDE.md`](CLAUDE.md) for architecture notes, store responsibilities,
and the AI pipeline.

## App Store

TBD.

## Support

Questions or bug reports? Email [dev@snxt.ai](mailto:dev@snxt.ai).

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Shawn M. Brown.

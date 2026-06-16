# Releasing the `file13` CLI

The CLI ships as a standalone Apple Developer ID-signed + notarized
binary distributed via Homebrew. Releases are automated by
[`.github/workflows/release-cli.yml`](workflows/release-cli.yml) and
triggered by tag pushes named `cli-v<semver>`.

## One-time setup (repo admin)

Add the following **GitHub Actions repo secrets** (Settings → Secrets
and variables → Actions → New repository secret):

| Secret | Value | How to get it |
|---|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` of your **Developer ID Application** certificate | Export from Keychain Access → `security export -k login.keychain -t identities -f pkcs12 -o file13.p12`, then `base64 -i file13.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Password you set when exporting the `.p12` | Anything you choose at export time |
| `APPLE_ID` | The Apple ID email tied to your Developer Program account | The address you sign into developer.apple.com with |
| `APPLE_TEAM_ID` | `YRB6VBTSRV` | developer.apple.com → Membership |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization | [appleid.apple.com](https://appleid.apple.com) → Sign-in and Security → App-Specific Passwords → "Generate" |
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT with `Contents: Read and write` scoped to `smbrownai/homebrew-file13` only | github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → "Generate new token." Resource owner: your account. Repository access: "Only select repositories" → pick `homebrew-file13`. Permissions: Contents → Read and write. Expiry: 1 year (then renew). |

`GITHUB_TOKEN` is provided automatically and is not used by this workflow — the source repo is private and the release assets need to live on the public tap repo (Homebrew downloads anonymously via curl, so private-repo asset URLs 404). Cross-repo writes can't be authorized via `GITHUB_TOKEN`, hence the PAT.

## Cutting a release

1. **Bump the version** in `cli/Sources/file13/File13.swift` (search
   for `file13Version`). The release script checks that the binary
   self-reports the same version it was asked to build, so they have to
   match.
2. **Commit and merge** the version bump to `main`.
3. **Tag the merge commit** with `cli-v<semver>` and push:
   ```sh
   git tag cli-v0.2.0
   git push origin cli-v0.2.0
   ```
4. **Watch the Action.** It builds, signs, notarizes (takes 1–5 min on
   Apple's side), and creates a release in the **public tap repo**
   ([`smbrownai/homebrew-file13`](https://github.com/smbrownai/homebrew-file13))
   with the `.zip` attached. The release body contains the formula
   stanza you'll paste in step 5.
5. **Update the Homebrew tap formula.** In `smbrownai/homebrew-file13`,
   edit `Formula/file13.rb` and paste the `url`/`sha256`/`version`
   block from the release body over the matching lines (also bump the
   top-level `version "..."` near the formula's `desc`/`homepage`
   block). Commit and push. Users get the new version via
   `brew update && brew upgrade file13`.

## Why a separate tag namespace?

GUI releases are MAS-distributed and tagged on the app's own cadence
(via App Store Connect, not git tags). CLI releases are independent
because they ship over a different channel and don't need to ship in
lockstep — for instance, a CLI-only bugfix shouldn't require a new
App Store submission, and a GUI-only feature shouldn't bump the CLI
version. The `cli-v*` prefix keeps the two namespaces separate so a
git-tag-driven release workflow doesn't fire on every GUI tag.

## Local dry run

To verify the script works without cutting an actual release:

```sh
export DEVELOPER_ID="Developer ID Application: Shawn Brown (YRB6VBTSRV)"
# One-time, locally:
xcrun notarytool store-credentials file13-notary \
  --apple-id you@example.com \
  --team-id YRB6VBTSRV \
  --password <app-specific-password>

cli/Scripts/release.sh 0.2.0-dryrun
```

The script will build, sign, submit to notary, and print the formula
stanza. It does **not** upload anywhere — that's the workflow's job.

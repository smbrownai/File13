# Homebrew formula for the file13 CLI.
#
# Lives in a tap repo `homebrew-file13` on GitHub:
#   https://github.com/smbrownai/homebrew-file13/blob/main/Formula/file13.rb
#
# After each `cli/Scripts/release.sh <version>` run, copy the updated
# `url`/`sha256`/`version` block printed at the end of the script over the
# matching lines below, commit, and push to the tap. Users get the new
# version with `brew update && brew upgrade file13`.
#
# This is a *binary* formula (not source-built) because:
#   - the binary needs Apple Developer ID code signing for entitlements to
#     work, and Homebrew can't sign on the user's machine
#   - building from source pulls swift-nio + 8 other deps, slow and heavy
#   - users on macOS 26+ can grab the prebuilt arm64 binary directly

class File13 < Formula
  desc        "Headless companion CLI for File13 — IMAP triage on metadata only"
  homepage    "https://github.com/smbrownai/file13"
  version     "0.0.1-dev"
  license     "MIT" # adjust to match your project's actual license

  # Apple Silicon only — the GUI app is macOS 26+ which requires Apple Silicon.
  on_macos do
    on_arm do
      url    "https://github.com/smbrownai/file13/releases/download/v0.0.1-dev/file13-0.0.1-dev-arm64-macos.zip"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  depends_on macos: :tahoe # macOS 26 (Tahoe). Adjust if name differs by the time you ship.

  def install
    bin.install "file13"
  end

  test do
    # `file13 version` prints the embedded version. We assert the formula's
    # `version` matches what the binary self-reports.
    assert_match version.to_s, shell_output("#{bin}/file13 version")
  end

  def caveats
    <<~EOS
      The CLI shares state with the File13 macOS app via an App Group
      container (`group.com.shawnbrown.file13`) and a Keychain Access Group
      (`com.shawnbrown.file13.shared`). It will only see the GUI's accounts,
      settings, rules, and AI provider keys when:

        - the GUI app is installed and has been launched at least once, AND
        - both binaries are signed with the same Apple Developer Team ID
          (the prebuilt CLI ships with Team ID YRB6VBTSRV).

      Run `file13 doctor` after install to verify the App Group container
      is reachable. If it reports "entitlement likely missing", the prebuilt
      binary's signature didn't survive download (extremely rare — usually
      means the .zip was repacked en route).

      Mail-touching commands (refresh, mail delete/archive/move, rules run)
      bail with exit 2 when File13.app is open. Settings/account/provider
      reads work alongside the GUI without conflict.

      For a headless cleanup schedule:
        file13 rules schedule install --interval hourly

      See `file13 --help` for the full surface.
    EOS
  end
end

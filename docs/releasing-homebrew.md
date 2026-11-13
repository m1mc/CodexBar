---
summary: "Homebrew Cask release steps for CodexBar (Sparkle-disabled builds)."
read_when:
  - Publishing a CodexBar release via Homebrew
  - Updating the Homebrew tap cask definition
---

# CodexBar Homebrew Release Playbook

Homebrew is for the UI app via Cask. CodexBar disables Sparkle and reads the owning prefix's `Caskroom/codexbar/.metadata/INSTALL_RECEIPT.json` to confirm the app was installed from the `m1mc/codexbar` tap, whose cask lives in this repository at `Casks/codexbar.rb`. Those installs retain daily checks, notifications, and one-click updates, and users are only prompted once that cask is bumped. Receipts from `homebrew/cask` or `steipete/tap` are rejected: those casks ship upstream builds.

Automatic checks also submit a silent macOS notification when a newer version of the owning cask is found. Clicking it opens Settings → About to review and install the update. A successfully submitted version is remembered locally across restarts; newer versions can notify again. Denied permissions or failed submissions remain retryable on a later check. Manual checks show their result in About without an extra notification. Starting installation or disabling automatic checks invalidates pending update notices. System notification settings still control whether a banner is displayed.

## In-app updates
- Automatic checks read the installed cask's feed on launch and daily; turning them off still permits manual checks in About. Queued automatic checks recheck this preference before reading the feed, and launching with checks disabled removes notices from earlier launches. Checking never installs anything.
- Detection follows the `Caskroom/codexbar/<version>/CodexBar.app` artifact link under `/opt/homebrew` or `/usr/local`, or a legacy app inside its cask directory. An unrelated copy of the app does not inherit Homebrew ownership. If multiple prefixes claim the same app, Sparkle remains disabled and the helper refuses to choose an owner; resolve the duplicate installation in Terminal.
- Clicking **Update to …** runs the owning prefix's `bin/brew update`, then `bin/brew upgrade --cask m1mc/codexbar/codexbar`, directly with fixed arguments. Refreshing first avoids Homebrew's auto-update interval leaving the local tap behind the offered version. The app shows progress and disables duplicate installs. No shell evaluates the cask version or command arguments.
- If `brew update` exits nonzero, the helper continues only when `brew info --json=v2 --cask <owning-cask>` confirms one enabled CodexBar cask from the receipt’s tap at or above the offered version. Verification and upgrade suppress automatic refreshes for those child processes, so one request refreshes only once. Failed verification or installation retains both failure diagnostics in About.
- The helper sets `NONINTERACTIVE=1`, `HOMEBREW_NO_SUDO=1`, and `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`. A permissions failure is shown in About; the app does not request elevated privileges. It relaunches only after a successful command and an on-disk version at least as new as the offered update.
- Missing brew, network errors, and failed or incomplete upgrades appear in About. When the receipt identifies a supported cask, its qualified upgrade command is selectable and copyable. Missing, malformed, or unsupported receipts fail without choosing another tap or running an upgrade; nested historical receipts are ignored. If the local tap is stale, run `brew update`, then the displayed upgrade command. A tap version older than the installed app is never offered as an update.
- Homebrew remains responsible for both the cask receipt and the app bundle; Sparkle does not install updates for these apps.

## Prereqs
- Homebrew installed.
- The tap points at this repository: `brew tap m1mc/codexbar https://github.com/m1mc/CodexBar`.

## 1) Tag the release
Push a `vX.Y.Z` tag (or dispatch `.github/workflows/multiplatform-release.yml` with an existing tag). The workflow stamps `X.Y.Z` into the app's `CFBundleShortVersionString`, so the installed bundle and the cask agree on the version, and publishes `CodexBar-macOS.dmg` plus the CLI tarballs to the GitHub Release.

## 2) Let the workflow update the cask
After publishing, the same workflow runs `Scripts/update_distribution_manifests.py` on `main`:
- `Casks/codexbar.rb` gets the tag version and the DMG checksum.
- `Formula/codexbar.rb` is updated only when every CLI tarball it references was published.

It commits `chore(distribution): update formula and cask checksums for release vX.Y.Z` to `main`. It never moves the cask to an older version. Installed apps pick the new version up on their next check.

If the push fails, run the script locally against the downloaded release assets and commit the result.

## 3) Verify install
```sh
brew update
brew upgrade --cask m1mc/codexbar/codexbar
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/CodexBar.app/Contents/Info.plist
open -a CodexBar
```

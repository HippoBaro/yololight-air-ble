# One-command macOS releases

From a reviewed, committed checkout on `main`:

```sh
python3 macos/release.py --publish
```

This runs tests, builds the app, packages it, generates the checksum and Homebrew
cask, tags the exact source revision, publishes a GitHub Release, and commits and
pushes **only the generated cask** after verifying the uploaded assets.

**Free ad-hoc signing is the default. No Apple membership, certificate, or
notarization credentials are needed.** The resulting app is not notarized.
Homebrew quarantine remains enabled; macOS may require explicit per-app approval
on first launch, and managed Macs may prohibit that approval. The script never
disables Gatekeeper, removes quarantine, or silently approves the app.

## Prerequisites and first release

- An Apple Silicon Mac running natively, with Swift 6 or newer and Apple's
  command-line tools. Initial releases are arm64-only, for macOS 14 or newer.
- Python 3.11 or newer for this script, not for the installed app.
- Git, a configured Git commit identity, and permission to push to the repository.
- For `--publish`, [GitHub CLI](https://cli.github.com/) authenticated to GitHub:

  ```sh
  gh auth login --hostname github.com
  ```

- The `origin` fetch **and push** URLs must refer to
  `HippoBaro/yololight-air-ble`, whose public default branch must be `main`.
  HTTPS and SSH remotes are supported. Git push authentication must also work.
  Branch protections requiring pull requests may block the final cask push;
  the script does not bypass protections or force-push.

Before the first run, review and commit the app, tooling, documentation, and
`.gitignore`. **Untracked or modified source files are refused**, not automatically
staged. This avoids publishing arbitrary work and ensures that the release tag
contains the source actually built. Source changes made during a run also stop it.

Set the version in `macos/Support/Info.plist` before committing:

- `CFBundleShortVersionString`: numeric `major.minor.patch`, initially `0.1.0`.
- `CFBundleVersion`: positive integer build number, initially `1`.

For each subsequent release, increase both and commit your reviewed changes.
The script derives filenames and tag `v<version>` from this metadata. It does not
choose a version or commit arbitrary source changes on your behalf.

## Commands

### Prepare locally, without publishing

```sh
python3 macos/release.py
```

Runs offline release tests and Swift tests, then builds, verifies the ad-hoc
signature and arm64 architecture, packages the app, and generates the cask. It
uses an isolated bundle under ignored `dist/`, leaving your running local app
alone. It does not contact GitHub, create a tag, commit, push, or launch the app.

For version `0.1.0`, outputs are:

```text
dist/YoloLight-Air-0.1.0-arm64.zip
dist/YoloLight-Air-0.1.0-arm64.zip.sha256
dist/YoloLight-Air-0.1.0-arm64.release.json
Casks/yololight-air.rb
```

The ignored manifest records the source commit, version/build, signing mode, and
checksum so retries can validate and reuse the exact same archive. Keep it with
the ZIP and checksum locally; it is not uploaded. Generated casks use a pinned
checksum, never `sha256 :no_check`.

### Publish everything

```sh
python3 macos/release.py --publish
```

This flag **explicitly authorizes public GitHub publication and Git writes**.
It prepares artifacts if needed, or validates/reuses the existing ones, then:

1. Checks authentication, repository, branch, and local/remote tag targets. A
   behind/diverged branch or a tag pointing to different source is rejected.
2. Pushes the packaged source revision to `main` if needed. It creates and pushes
   an annotated `v<version>` tag at that exact source commit, without moving any
   existing tag or pushing unrelated tags.
3. Creates a **draft** GitHub Release. Release notes explicitly disclose the
   ad-hoc/unnotarized status. An existing compatible draft can be resumed.
4. Uploads the ZIP and checksum, downloads both, and verifies their contents
   against the prepared checksums. Existing assets are verified, not overwritten.
5. Publishes the draft as a stable release, then downloads/verifies the assets
   again. Published releases are never overwritten or deleted.
6. Rechecks the checkout, commits only `Casks/yololight-air.rb` if necessary, and
   pushes that commit to `main`. The cask therefore never advertises a release
   before its assets have been published and verified.

The archive includes the BSD license. It contains no Python runtime, saved light
identities, or scan captures. A first-launch check on a clean Mac is still needed
to assess the actual Gatekeeper and Bluetooth-permission experience.

## Resume after an interruption

Fix the reported error, then run **the same command again**:

```sh
python3 macos/release.py --publish
```

The script revalidates local artifacts instead of rebuilding them, resumes
missing draft uploads, verifies existing remote assets, and avoids duplicate
cask commits. If the final push failed, the already-created local cask commit can
be pushed by the next run. GitHub publication is not an atomic transaction:
a tag, draft, published release, or local cask commit may remain after failure.
Nothing is automatically deleted to roll back those remote actions.

Do not alter prepared archives, their checksums/manifest, or the generated cask.
Do not replace a published version; use a new version for changed source or a
different signing mode. If preparation fails before a usable manifest exists,
review and remove only the **unpublished** partial outputs before retrying.
Preserve the manifest for a completed release if you want to recheck/resume it.

Run only one release process per checkout at a time. The script refuses file
collisions and non-fast-forward pushes, but does not lock out another editor or
maintainer. Reconcile conflicting source history normally; no force-push is used.

## Optional paid Developer ID signing

This is **not required** for the default workflow. If desired later, supply both
options to sign/notarize instead of using ad-hoc signing:

```sh
python3 macos/release.py --publish \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile yololight-air
```

This requires a Developer ID Application certificate/private key in your keychain
and a profile created interactively with
`xcrun notarytool store-credentials yololight-air`. Never commit keys or passwords.
The script enables hardened runtime, requires Apple's explicit `Accepted`
notarization result, staples/validates the ticket, and assesses Gatekeeper before
packaging the final ZIP. It never silently falls back to ad-hoc signing after a
notarization failure. Repeat both options when resuming a notarized release.

## Validation

```sh
python3 -B -m unittest discover -s macos -p 'test_release*.py'
```

Tests simulate Apple services and GitHub. Separate Git tests use disposable
repositories with synthetic content/identities, never the app's repository.
Coverage includes signing modes, version/architecture checks, clean-checkout
requirements, final ZIP checksums, interrupted uploads, conflicting tags,
repository/branch guards, and cask-only commit/push ordering.

The release command also runs the Swift tests with the toolchain's testing-plugin
path. Set `YOLOLIGHT_UI_TESTS=1` to include the simulated-light GUI test in a
logged-in macOS session. These tests do not control real lights. The separate
Python BLE controller tests can be run with
`.venv/bin/python -B -m unittest -q test_yololight.py`.

References: [GitHub releases](https://cli.github.com/manual/gh_release_create),
[Homebrew taps](https://docs.brew.sh/Taps),
[Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

# Homebrew tap

This app repository also hosts its Homebrew tap. No separate `homebrew-*`
repository is needed.

## Install

**The first release and generated `Casks/yololight-air.rb` must be published
before these commands can install the app.** Until then, use the
[source build](../macos/README.md#build).

Requires an Apple Silicon Mac running macOS 14 (Sonoma) or newer:

```sh
brew tap HippoBaro/yololight-air-ble \
  https://github.com/HippoBaro/yololight-air-ble.git
brew install --cask HippoBaro/yololight-air-ble/yololight-air
```

The explicit repository URL is required on first tap because this repository
is not named `homebrew-yololight-air-ble`. The cask downloads a prebuilt app from
this repository's GitHub Releases; users do not need Swift or Python.

Open **YoloLight Air** from Applications, then use its menu-bar lightbulb. Allow
Bluetooth access if macOS requests it. Releases use **free ad-hoc signing by
default and are not notarized**. macOS may block first launch; users who trust the
app can use the per-app **System Settings → Privacy & Security → Open Anyway**
option where available. Managed Macs may prohibit this exception. Homebrew does
not bypass Gatekeeper or Bluetooth permission prompts, and the cask does not
remove quarantine or automatically approve the app.

For a later release:

```sh
brew update
brew upgrade --cask HippoBaro/yololight-air-ble/yololight-air
```

Quit the app before upgrading it. To remove it:

```sh
brew uninstall --cask HippoBaro/yololight-air-ble/yololight-air
```

## Maintain

The cask template lives at [`macos/Support/yololight-air.rb.in`](../macos/Support/yololight-air.rb.in).
It is deliberately outside the loadable `Casks/*.rb` files: there is no fake
checksum or `sha256 :no_check` entry advertising an unreleased binary.

From a clean, committed `main` checkout, one command handles the release:

```sh
python3 macos/release.py 0.1.1 --publish
```

Replace `0.1.1` with the next version. It updates and commits only the app's
version/build metadata, tests/builds the app, packages it, generates
`Casks/yololight-air.rb` with the final ZIP's checksum, publishes the GitHub
Release, verifies downloads, then commits/pushes only the cask to the default
branch. No paid Apple account is required. The explicit `--publish` flag
authorizes remote writes and the cask commit; omit it to prepare without
publishing. A newer version argument still creates a local metadata-only commit.
Omit the version too to use already-committed metadata without any commits.

See the [release procedure](../macos/RELEASING.md) for prerequisites, safety checks,
retries, and optional Developer ID signing/notarization. Never overwrite a
published release or weaken Gatekeeper to make a download launch.

References: [tap layout](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap),
[custom repository URLs](https://docs.brew.sh/Taps),
[Cask Cookbook](https://docs.brew.sh/Cask-Cookbook).

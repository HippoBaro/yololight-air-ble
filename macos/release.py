#!/usr/bin/env python3
"""Build, package, and optionally publish YoloLight Air and its Homebrew cask.

Free ad-hoc signing is the default. --publish explicitly authorizes GitHub
publication, tag/source pushes, and a commit/push of ONLY the generated cask.
Requires a clean, committed checkout; never commits arbitrary source changes.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


if sys.version_info < (3, 11):
    raise SystemExit("Release tooling requires Python 3.11 or newer.")


APP_NAME = "YoloLight Air.app"
CASK_NAME = "yololight-air.rb"
CASK_PATH = f"Casks/{CASK_NAME}"
REPOSITORY = "HippoBaro/yololight-air-ble"
BRANCH = "main"
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def command(*args: str | Path, capture: bool = False) -> str:
    result = subprocess.run(
        [str(arg) for arg in args], check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    return result.stdout or ""


def git(root: Path, *args: str) -> str:
    return command("git", "-C", root, *args, capture=True).rstrip("\n")


def ancestor(root: Path, older: str, newer: str) -> bool:
    try:
        git(root, "merge-base", "--is-ancestor", older, newer)
        return True
    except subprocess.CalledProcessError as error:
        if error.returncode == 1:
            return False
        raise


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def read_metadata(path: Path) -> dict:
    with path.open("rb") as source:
        metadata = plistlib.load(source)
    if not isinstance(metadata, dict):
        raise ValueError("Info.plist must contain a dictionary.")
    version = metadata.get("CFBundleShortVersionString", "")
    if not isinstance(version, str) or not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("CFBundleShortVersionString must be a numeric major.minor.patch version.")
    build = metadata.get("CFBundleVersion", "")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive integer.")
    expected = {
        "CFBundleIdentifier": "dev.hippobaro.YoloLightAir",
        "CFBundleExecutable": "YoloLightMenu",
        "LSMinimumSystemVersion": "14.0",
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(f"Unexpected {key}; update the release tooling/cask requirements first.")
    return metadata


def render_cask(template: str, version: str, checksum: str) -> str:
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Invalid release version.")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("A real SHA-256 checksum is required.")
    for token, value in (("@VERSION@", version), ("@SHA256@", checksum)):
        if template.count(token) != 1:
            raise ValueError(f"Cask template must contain exactly one {token}.")
        template = template.replace(token, value)
    if re.search(r"@[A-Z_]+@", template):
        raise ValueError("Unresolved cask template token.")
    return template


def ensure_new_version(cask: Path, version: str) -> None:
    if not cask.exists():
        return
    match = re.search(r'^  version "(' + VERSION_PATTERN + r')"$', cask.read_text(), re.MULTILINE)
    if not match:
        raise ValueError("Cannot read the existing cask version; review it before releasing.")
    current = tuple(map(int, match[1].split(".")))
    if tuple(map(int, version.split("."))) <= current:
        raise ValueError("Increase the app version before replacing an existing release cask.")


def check_checkout(root: Path, source: str | None = None, cask_text: str | None = None) -> str:
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root.resolve():
        raise ValueError("Run from the app's own Git checkout.")
    head = git(root, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("A committed source revision is required.")
    for line in git(root, "status", "--porcelain", "--untracked-files=all").splitlines():
        if cask_text is None or line[3:] != CASK_PATH:
            raise ValueError("Review and commit source changes first; the release requires a clean checkout.")
    if cask_text is not None and (root / CASK_PATH).read_text() != cask_text:
        raise ValueError("The generated cask was changed. Restore it before resuming this release.")
    if source is not None:
        if not ancestor(root, source, head) or git(
            root, "diff", "--name-only", source, "HEAD", "--", ".", f":(exclude){CASK_PATH}"
        ):
            raise ValueError("The source changed since packaging. Use a new version, not stale artifacts.")
    return head


def artifact_paths(root: Path, version: str) -> tuple[Path, Path, Path]:
    archive = root / "dist" / f"YoloLight-Air-{version}-arm64.zip"
    return archive, archive.with_suffix(".zip.sha256"), archive.with_suffix(".release.json")


def load_prepared(root: Path, metadata: dict, mode: str | None = None) -> dict:
    version = metadata["CFBundleShortVersionString"]
    archive, checksum_file, manifest = artifact_paths(root, version)
    state = json.loads(manifest.read_text())
    if (not isinstance(state, dict) or state.get("schema") != 1
            or state.get("version") != version or state.get("build") != metadata["CFBundleVersion"]
            or state.get("signing") not in ("ad-hoc", "notarized")
            or not re.fullmatch(r"[0-9a-f]{40}", str(state.get("source_commit", "")))
            or not re.fullmatch(r"[0-9a-f]{64}", str(state.get("sha256", "")))):
        raise ValueError("Invalid release manifest; do not reuse these artifacts.")
    if mode is not None and state["signing"] != mode:
        raise ValueError("Existing artifacts use a different signing mode; use a new release version.")
    if (digest(archive) != state["sha256"]
            or checksum_file.read_text() != f'{state["sha256"]}  {archive.name}\n'):
        raise ValueError("Release artifacts failed checksum validation; nothing will be uploaded.")
    template = (root / "macos/Support/yololight-air.rb.in").read_text()
    check_checkout(root, state["source_commit"], render_cask(template, version, state["sha256"]))
    return state


def run_tests(root: Path) -> None:
    print("Running offline release and Swift tests…", flush=True)
    command(sys.executable, "-B", "-m", "unittest", "discover", "-s", root / "macos", "-p", "test_release*.py")
    swiftc = Path(command("xcrun", "--find", "swiftc", capture=True).strip())
    plugins = swiftc.parent / "../lib/swift/host/plugins/testing"
    command("swift", "test", "--package-path", root / "macos", "--disable-xctest",
            "-Xswiftc", "-plugin-path", "-Xswiftc", plugins)


def prepare_release(root: Path, identity: str | None = None, notary_profile: str | None = None) -> Path:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Release packaging currently requires an Apple Silicon Mac (not Rosetta).")
    notarized = identity is not None or notary_profile is not None
    if notarized:
        if not identity or not identity.startswith("Developer ID Application: "):
            raise ValueError("Use a Developer ID Application signing identity, not ad-hoc signing.")
        if not notary_profile or not notary_profile.strip():
            raise ValueError("A notarytool keychain profile is required.")
    mode = "notarized" if notarized else "ad-hoc"
    metadata = read_metadata(root / "macos/Support/Info.plist")
    version = metadata["CFBundleShortVersionString"]
    cask = root / CASK_PATH
    template = (root / "macos/Support/yololight-air.rb.in").read_text()
    archive, checksum_file, manifest = artifact_paths(root, version)
    if manifest.exists():
        load_prepared(root, metadata, mode)
        print(f"Reusing verified {mode} artifacts: {archive}")
        return archive
    if archive.exists() or checksum_file.exists():
        raise ValueError("Release artifacts already exist without a manifest. Never replace a published version.")
    ensure_new_version(cask, version)
    tools = ["git", "swift", "codesign", "ditto", "lipo", "xcrun", "plutil"]
    if notarized:
        tools += ["security", "spctl"]
    for tool in tools:
        if shutil.which(tool) is None:
            raise ValueError(f"Required tool not found: {tool}")
    source_commit = check_checkout(root)
    if notarized:
        for tool in ("notarytool", "stapler"):
            command("xcrun", "--find", tool, capture=True)
        identities = command("security", "find-identity", "-v", "-p", "codesigning", capture=True)
        if f'"{identity}"' not in identities:
            raise ValueError("The requested signing identity and private key are not available in the keychain.")
    run_tests(root)
    archive.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".yololight-release-", dir=archive.parent) as temporary:
        staging = Path(temporary)
        app = staging / APP_NAME
        print(f"Building {version} ({mode}) in an isolated bundle…", flush=True)
        command(root / "macos/build-app.sh", app)
        if read_metadata(app / "Contents/Info.plist") != metadata:
            raise ValueError("Built app metadata differs from the release metadata.")
        architectures = command("lipo", "-archs", app / "Contents/MacOS/YoloLightMenu", capture=True)
        if architectures.split() != ["arm64"]:
            raise ValueError("The built app must contain exactly the arm64 architecture advertised by the cask.")
        if notarized:
            command("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, app)
            command("codesign", "--verify", "--deep", "--strict", app)
            submission = staging / "submission.zip"
            command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission)
            print("Submitting to Apple for notarization…", flush=True)
            result = json.loads(command(
                "xcrun", "notarytool", "submit", submission, "--keychain-profile", notary_profile,
                "--wait", "--output-format", "json", capture=True,
            ))
            if not isinstance(result, dict) or result.get("status") != "Accepted":
                submission_id = result.get("id", "unknown") if isinstance(result, dict) else "unknown"
                raise ValueError(f"Notarization was not accepted. Inspect notarytool log for submission {submission_id}.")
            command("xcrun", "stapler", "staple", app)
            command("xcrun", "stapler", "validate", app)
            command("spctl", "--assess", "--type", "execute", "--verbose=2", app)
        # In free mode build-app.sh already applied the ad-hoc signature. This
        # validates integrity, NOT publisher identity or Gatekeeper approval.
        command("codesign", "--verify", "--deep", "--strict", app)
        packaged = staging / archive.name
        command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, packaged)
        checksum = digest(packaged)
        # Refuse source edits made while tests/build/signing were running.
        if check_checkout(root) != source_commit:
            raise ValueError("HEAD changed during the build; no release artifacts were saved.")
        state = dict(schema=1, version=version, build=metadata["CFBundleVersion"],
                     source_commit=source_commit, signing=mode, sha256=checksum)
        staged_checksum = staging / checksum_file.name
        staged_checksum.write_text(f"{checksum}  {archive.name}\n")
        staged_manifest = staging / manifest.name
        staged_manifest.write_text(json.dumps(state, indent=2) + "\n")
        staged_cask = staging / CASK_NAME
        staged_cask.write_text(render_cask(template, version, checksum))
        cask.parent.mkdir(exist_ok=True)
        created = []
        try:
            for source, destination in ((packaged, archive), (staged_checksum, checksum_file),
                                        (staged_manifest, manifest)):
                os.link(source, destination)
                created.append(destination)
            os.replace(staged_cask, cask)
        except OSError:
            for path in created:
                path.unlink()
            raise
    print(f"\nPrepared: {archive}\nChecksum: {checksum_file}\nCask: {cask}")
    return archive


def gh(*args: str | Path, capture: bool = False) -> str:
    return command("gh", "release", *args, "--repo", f"github.com/{REPOSITORY}", capture=capture)


def verify_download(tag: str, expected: Path, checksum: str) -> None:
    with tempfile.TemporaryDirectory(prefix=".download-", dir=expected.parent) as temporary:
        gh("download", tag, "--pattern", expected.name, "--dir", temporary)
        if digest(Path(temporary) / expected.name) != checksum:
            raise ValueError(f"Remote asset {expected.name} differs from the prepared release. Never overwrite it.")


def publish_release(root: Path) -> None:
    metadata = read_metadata(root / "macos/Support/Info.plist")
    state = load_prepared(root, metadata)
    version, source = state["version"], state["source_commit"]
    archive, checksum_file, _ = artifact_paths(root, version)
    tag = f"v{version}"
    if shutil.which("gh") is None:
        raise ValueError("Install GitHub CLI and run gh auth login before publishing.")
    if git(root, "branch", "--show-current") != BRANCH:
        raise ValueError(f"Publish from {BRANCH}; detached HEADs and other branches are refused.")
    allowed_origins = (f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}",
                       f"ssh://git@github.com/{REPOSITORY}")
    origin = git(root, "remote", "get-url", "origin").removesuffix(".git")
    push_urls = git(root, "remote", "get-url", "--push", "--all", "origin").splitlines()
    if (origin.lower() not in [url.lower() for url in allowed_origins] or len(push_urls) != 1
            or push_urls[0].removesuffix(".git").lower() not in [url.lower() for url in allowed_origins]):
        raise ValueError("origin fetch/push URLs must match the repository advertised by the cask.")
    command("gh", "auth", "status", "--hostname", "github.com", capture=True)
    repo = json.loads(command("gh", "api", f"repos/{REPOSITORY}", "--hostname", "github.com", capture=True))
    if not isinstance(repo, dict) or repo.get("private") is not False or repo.get("default_branch") != BRANCH:
        raise ValueError(f"Publishing requires the expected public repository with default branch {BRANCH}.")
    git(root, "fetch", "--no-tags", "origin", BRANCH)
    remote_head = git(root, "rev-parse", "FETCH_HEAD")
    if not ancestor(root, remote_head, "HEAD"):
        raise ValueError("Local main is behind or diverged from origin. Reconcile it before publishing.")

    # Both local and remote tags must identify the exact packaged source.
    local_tag = git(root, "tag", "--list", tag)
    if local_tag and git(root, "rev-parse", f"refs/tags/{tag}^{{commit}}") != source:
        raise ValueError("The local release tag points to different source; use a new version.")
    remote_tags = dict(line.split()[::-1] for line in git(
        root, "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"
    ).splitlines())
    remote_tag = remote_tags.get(f"refs/tags/{tag}^{{}}", remote_tags.get(f"refs/tags/{tag}"))
    if remote_tag is not None and remote_tag != source:
        raise ValueError("The remote release tag points to different source; it will not be moved.")
    # Pagination avoids interpreting network/auth failures or a short list as
    # 'release absent'. A matching draft can safely resume after interruption.
    existing = command(
        "gh", "api", f"repos/{REPOSITORY}/releases?per_page=100", "--hostname", "github.com",
        "--paginate", "--jq", f'.[] | select(.tag_name == "{tag}") | {{draft, prerelease}}', capture=True,
    ).strip()
    release = json.loads(existing) if existing else None
    if release is not None and (not isinstance(release, dict)
                                or not isinstance(release.get("draft"), bool) or release.get("prerelease")):
        raise ValueError("The existing release is not a supported stable release/draft.")

    # Push SOURCE only here, never a cask-only commit left by a previous attempt.
    # The cask must not reach main until the release assets are published/verified.
    if not ancestor(root, source, remote_head):
        if not ancestor(root, remote_head, source):
            raise ValueError("Cannot advance main to the packaged source without rewriting history.")
        git(root, "push", "--no-follow-tags", "origin", f"{source}:refs/heads/{BRANCH}")
    if not remote_tag:
        if not local_tag:
            git(root, "tag", "-a", tag, source, "-m", f"YoloLight Air {version}")
        git(root, "push", "--no-follow-tags", "origin", f"refs/tags/{tag}")
    if release is None:
        notes = "Apple Silicon; macOS 14 or newer. "
        notes += ("Ad-hoc signed, NOT notarized. macOS may require explicit per-app approval on first launch."
                  if state["signing"] == "ad-hoc" else "Developer ID signed and notarized.")
        gh("create", tag, "--draft", "--verify-tag", "--title", f"YoloLight Air {version}", "--notes", notes)
        release = {"draft": True}
    assets = set(gh("view", tag, "--json", "assets", "--jq", ".assets[].name", capture=True).splitlines())
    expected_hashes = {
        archive: state["sha256"],
        checksum_file: hashlib.sha256(f'{state["sha256"]}  {archive.name}\n'.encode()).hexdigest(),
    }
    for asset, expected_hash in expected_hashes.items():
        if digest(asset) != expected_hash:
            raise ValueError("A local artifact changed during publication; refusing to upload it.")
        if asset.name not in assets:
            if not release["draft"]:
                raise ValueError("A published release is missing an expected asset. Use a new version.")
            gh("upload", tag, asset)  # Deliberately no --clobber.
        verify_download(tag, asset, expected_hash)
    load_prepared(root, metadata)
    if release["draft"]:
        gh("edit", tag, "--draft=false", "--latest", "--verify-tag")
    published = json.loads(gh("view", tag, "--json", "isDraft,isPrerelease", capture=True))
    if (not isinstance(published, dict) or published.get("isDraft") is not False
            or published.get("isPrerelease") is not False):
        raise ValueError("The release is not publicly published as stable; the cask was not pushed.")
    for asset, expected_hash in expected_hashes.items():
        verify_download(tag, asset, expected_hash)

    # Recheck after network operations; never stage/commit unrelated user edits.
    load_prepared(root, metadata)
    if git(root, "status", "--porcelain", "--", CASK_PATH):
        git(root, "add", "--", CASK_PATH)
        git(root, "commit", "--only", "-m", f"Update YoloLight Air cask to {version}", "--", CASK_PATH)
    load_prepared(root, metadata)
    if git(root, "show", f"HEAD:{CASK_PATH}") != (root / CASK_PATH).read_text().rstrip("\n"):
        raise ValueError("The committed cask differs from the verified artifact; refusing to push.")
    git(root, "push", "--no-follow-tags", "origin", f"HEAD:refs/heads/{BRANCH}")
    print(f"\nPublished: https://github.com/{REPOSITORY}/releases/tag/{tag}")
    print(f"Homebrew cask committed and pushed to {BRANCH}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true", help="Publish to GitHub, push the tag/source, and commit/push the cask")
    parser.add_argument("--identity", help="Optional Developer ID Application identity (requires --notary-profile)")
    parser.add_argument("--notary-profile", help="Optional notarytool profile (requires --identity)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        prepare_release(root, args.identity, args.notary_profile)
        if args.publish:
            publish_release(root)
        else:
            print("Nothing was published or committed. Run again with --publish to publish these same artifacts.")
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        parser.exit(1, f"Release failed: {detail}\nExisting local/remote artifacts were not overwritten. Fix the issue and rerun to resume.\n")


if __name__ == "__main__":
    main()

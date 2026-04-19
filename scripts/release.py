#!/usr/bin/env python3
"""
Create a GitHub release for shebangsy from pre-built zip artifacts.

What this is
    A small release helper used by ``just release``. It assumes cross-platform
    zip bundles already exist under ``dist/`` (from ``scripts/build-cross.sh``).

Steps performed (normal invocation)
    1. Resolve the git repository root and ensure you are not in a detached HEAD.
    2. Read ``git remote`` for the current branch, parse owner/repo (and optional
       GitHub Enterprise host) for the ``gh`` CLI via ``GH_REPO`` / ``GH_HOST``.
    3. Resolve the release version: either use the given semver string, or bump
       ``patch`` / ``minor`` / ``major`` from the latest GitHub release tag
       (or seed ``0.0.1`` / ``0.1.0`` / ``1.0.0`` if none exist).
    4. Require ``dist/shebangsy-<version>-*.zip`` files to be present.
    5. Promote ``## [Unreleased]`` in ``CHANGELOG.md`` to ``## [<version>] - <date>``,
       insert a fresh empty ``## [Unreleased]``, refresh the reference-link footer
       (``[Unreleased]``, version compare URLs, Keep a Changelog / Semver links),
       then ``git add`` / ``git commit`` and ``git push`` the current branch.
    6. Create an annotated git tag ``<version>`` with message
       ``shebangsy <version>``, force-push it to ``origin``, then run
       ``gh release create`` with those zips and ``--generate-notes``.

Also supports ``--print-version`` to print the resolved version only (no git/gh
side effects beyond parsing the remote), for scripting.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

CHANGELOG_FILENAME = "CHANGELOG.md"
RELEASE_ASSET_PREFIX = "shebangsy"


def script_dir() -> Path:
    """Return the directory containing this script (``scripts/``)."""
    return Path(__file__).resolve().parent


def repo_root() -> Path:
    """Return the absolute path to the git repository root (from ``scripts/``)."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=script_dir(),
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(result.stdout.strip())


def die(message: str) -> None:
    """Print ``message`` to stderr with a ``release.py:`` prefix and exit with code 1."""
    print(f"release.py: {message}", file=sys.stderr)
    sys.exit(1)


def configure_github_repo() -> None:
    """
    Parse the current branch's upstream remote URL and set ``GH_REPO`` (and
    ``GH_HOST`` when not github.com) in the environment for ``gh``.

    Uses the tracked remote for the current branch, defaulting to ``origin``.
    """
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=script_dir(),
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not branch:
        die("detached HEAD; checkout a branch first")

    remote = subprocess.run(
        ["git", "config", "--get", f"branch.{branch}.remote"],
        cwd=script_dir(),
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not remote:
        remote = "origin"

    url_result = subprocess.run(
        ["git", "remote", "get-url", remote],
        cwd=script_dir(),
        capture_output=True,
        text=True,
    )
    if url_result.returncode != 0:
        die(f"could not read URL for remote '{remote}'")

    url = url_result.stdout.strip().removesuffix(".git")
    gh_host: str | None
    gh_repo: str
    m_ssh = re.match(r"^git@([^:]+):(.+)$", url)
    if m_ssh:
        gh_host = m_ssh.group(1)
        gh_repo = m_ssh.group(2)
    elif url.startswith("http://") or url.startswith("https://"):
        rest = url.split("://", 1)[1]
        if "@" in rest:
            rest = rest.split("@", 1)[1]
        parts = rest.split("/", 1)
        gh_host = parts[0]
        gh_repo = parts[1] if len(parts) > 1 else ""
        gh_repo = gh_repo.split("?", 1)[0]
    else:
        die(f"cannot parse GitHub owner/repo from remote '{remote}': {url}")

    if not gh_repo:
        die(f"cannot parse GitHub owner/repo from remote '{remote}': {url}")

    if gh_host in ("github.com", "ssh.github.com"):
        os.environ.pop("GH_HOST", None)
        os.environ["GH_REPO"] = gh_repo
    else:
        os.environ["GH_HOST"] = gh_host
        os.environ["GH_REPO"] = gh_repo


def gh_latest_release_tag(repo: str) -> str | None:
    """Return ``tag_name`` from GitHub's latest release, or ``None`` if none / ``gh`` fails."""
    try:
        proc = subprocess.run(
            ["gh", "api", f"repos/{repo}/releases/latest", "--jq", ".tag_name"],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            tag = proc.stdout.strip()
            return tag if tag else None
    except FileNotFoundError:
        pass
    return None


def resolve_version(ver_raw: str) -> str:
    """
    Return a concrete version string.

    If ``ver_raw`` is ``patch``, ``minor``, or ``major``, compute the next
    semver from the latest GitHub release (via ``gh api``), preserving a leading
    ``v`` on the tag when present. If there is no latest release, seed
    ``0.0.1``, ``0.1.0``, or ``1.0.0`` respectively.

    Otherwise ``ver_raw`` is returned unchanged (expected to be an explicit tag
    / version string).
    """
    if ver_raw not in ("patch", "minor", "major"):
        return ver_raw

    bump = ver_raw
    repo = os.environ.get("GH_REPO", "")
    latest = gh_latest_release_tag(repo) or ""

    if not latest:
        defaults = {"patch": "0.0.1", "minor": "0.1.0", "major": "1.0.0"}
        return defaults[bump]

    prefix = "v" if latest.startswith("v") else ""
    body = latest[1:] if latest.startswith("v") else latest
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", body)
    if not m:
        die(f"latest release tag '{latest}' is not semver")

    major_s, minor_s, patch_s = m.group(1), m.group(2), m.group(3)
    major, minor, patch = int(major_s), int(minor_s), int(patch_s)
    if bump == "patch":
        return f"{prefix}{major}.{minor}.{patch + 1}"
    if bump == "minor":
        return f"{prefix}{major}.{minor + 1}.0"
    return f"{prefix}{major + 1}.0.0"


def parse_reference_links(footer: str) -> dict[str, str]:
    """Parse markdown reference-style link definitions into a map ``label -> URL``."""
    out: dict[str, str] = {}
    for line in footer.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^\[([^\]]+)\]: (.+)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def version_sort_key(label: str) -> tuple[int, ...]:
    """Sort key for semver-like release labels (optional leading ``v``)."""
    s = label.lstrip("v")
    parts = s.split(".")
    nums: list[int] = []
    for p in parts[:3]:
        try:
            nums.append(int(p))
        except ValueError:
            nums.append(0)
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)


def format_changelog_footer(links: dict[str, str]) -> str:
    """
    Emit reference definitions: ``[Unreleased]`` and version compares first
    (newest versions first), then ``keep-a-changelog`` and ``semver``.
    """
    doc_order = ("keep-a-changelog", "semver")
    release = {k: v for k, v in links.items() if k not in doc_order}
    lines: list[str] = []
    if "Unreleased" in release:
        lines.append(f"[Unreleased]: {release.pop('Unreleased')}")
    for k in sorted(release.keys(), key=version_sort_key, reverse=True):
        lines.append(f"[{k}]: {release[k]}")
    for k in doc_order:
        if k in links:
            lines.append(f"[{k}]: {links[k]}")
    return "\n".join(lines) + "\n"


def merge_changelog_footer_links(
    old_footer: str,
    repo: str,
    version: str,
    prev_tag: str | None,
) -> str:
    """
    Merge new ``[Unreleased]`` and ``[<version>]`` GitHub URLs into the existing
    footer map, preserving other release links and doc links.
    """
    links = parse_reference_links(old_footer)
    base = f"https://github.com/{repo}"
    links["Unreleased"] = f"{base}/compare/{version}...HEAD"
    if prev_tag:
        links[version] = f"{base}/compare/{prev_tag}...{version}"
    else:
        links[version] = f"{base}/releases/tag/{version}"
    return format_changelog_footer(links)


def split_changelog_for_promote(text: str) -> tuple[str, str, str, str]:
    """
    Split ``CHANGELOG.md`` into preamble (before ``## [Unreleased]``), notes
    under Unreleased, optional older ``## […]`` sections, and the reference-link
    footer block.
    """
    marker = "## [Unreleased]"
    idx = text.find(marker)
    if idx < 0:
        die(f"{CHANGELOG_FILENAME}: missing ## [Unreleased] section")

    preamble = text[:idx]
    rest = text[idx + len(marker) :].lstrip("\n")

    m_hist = re.search(r"^## \[", rest, re.MULTILINE)
    m_footer = re.search(r"^\[[^\]]+\]: https?://", rest, re.MULTILINE)
    positions: list[int] = []
    if m_hist:
        positions.append(m_hist.start())
    if m_footer:
        positions.append(m_footer.start())
    if not positions:
        die(
            f"{CHANGELOG_FILENAME}: could not find older sections or "
            "reference-link footer after [Unreleased]"
        )
    end_unreleased = min(positions)
    unreleased_body = rest[:end_unreleased].rstrip()
    tail = rest[end_unreleased:].lstrip("\n")

    m_f = re.search(r"^\[[^\]]+\]: https?://", tail, re.MULTILINE)
    if not m_f:
        die(f"{CHANGELOG_FILENAME}: missing reference-link footer")
    middle = tail[: m_f.start()].rstrip()
    old_footer = tail[m_f.start() :].strip()
    return preamble, unreleased_body, middle, old_footer


def promote_changelog(path: Path, version: str, repo: str, prev_tag: str | None) -> None:
    """
    Rewrite ``CHANGELOG.md``: fresh empty ``## [Unreleased]``, a new
    ``## [version] - date`` with the former unreleased notes, preserved older
    release sections, and an updated reference-link footer.
    """
    text = path.read_text(encoding="utf-8")
    preamble, unreleased_body, middle, old_footer = split_changelog_for_promote(text)
    today = date.today().isoformat()
    new_footer = merge_changelog_footer_links(old_footer, repo, version, prev_tag)
    middle_block = f"{middle}\n\n" if middle else ""
    new_text = (
        f"{preamble.rstrip()}\n\n"
        "## [Unreleased]\n\n"
        f"## [{version}] - {today}\n\n"
        f"{unreleased_body}\n\n"
        f"{middle_block}"
        f"{new_footer}"
    )
    path.write_text(new_text, encoding="utf-8", newline="\n")


def git_commit_changelog(root: Path, version: str) -> None:
    """Stage ``CHANGELOG.md`` and create a release preparation commit."""
    subprocess.run(
        ["git", "add", CHANGELOG_FILENAME],
        cwd=root,
        check=True,
    )
    subprocess.run(
        ["git", "commit", "-m", f"chore(release): {version}"],
        cwd=root,
        check=True,
    )


def git_push_current_branch(root: Path) -> None:
    """Push the current branch to ``origin`` so the changelog commit exists upstream."""
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    if not branch:
        die("detached HEAD; cannot push changelog commit")
    subprocess.run(["git", "push", "origin", branch], cwd=root, check=True)


def git_annotated_release_tag_add(tag: str) -> None:
    """Create an annotated tag for ``tag`` and force-push it to ``origin``."""
    root = repo_root()
    msg = f"shebangsy {tag}"
    subprocess.run(
        ["git", "tag", "-af", tag, "-m", msg],
        cwd=root,
        check=True,
    )
    subprocess.run(
        ["git", "push", "--force", "origin", tag],
        cwd=root,
        check=True,
    )


def print_help() -> None:
    """Print usage for this script to stdout."""
    print(
        "Usage: release.py <version | patch | minor | major>\n"
        "       release.py --print-version <version | patch | minor | major>"
    )


def main() -> None:
    """
    Entry point: handle help, ``--print-version``, or a full release (changelog,
    commit, push, tag + ``gh release create``).
    """
    argv = sys.argv[1:]
    if len(argv) == 0 or argv[0] in ("-h", "--help"):
        print_help()
        return

    root = repo_root()
    os.chdir(root)
    configure_github_repo()

    if argv[0] == "--print-version":
        if len(argv) < 2:
            die(
                "usage: release.py --print-version "
                "<version | patch | minor | major>"
            )
        print(resolve_version(argv[1]))
        return

    version = resolve_version(argv[0])
    repo = os.environ.get("GH_REPO", "")

    dist_dir = root / "dist"
    if not dist_dir.is_dir():
        die(
            f"missing dist dir {dist_dir}; run scripts/build-cross.sh {version} first"
        )

    pattern = f"{RELEASE_ASSET_PREFIX}-{version}-*.zip"
    assets = sorted(dist_dir.glob(pattern))
    if not assets:
        die(f"no zips matching {dist_dir}/{pattern}")

    prev_tag = gh_latest_release_tag(repo)
    changelog_path = root / CHANGELOG_FILENAME
    if not changelog_path.is_file():
        die(f"missing {changelog_path}")
    promote_changelog(changelog_path, version, repo, prev_tag)
    git_commit_changelog(root, version)
    git_push_current_branch(root)
    git_annotated_release_tag_add(version)
    subprocess.run(
        ["gh", "release", "create", version]
        + [str(p) for p in assets]
        + ["--generate-notes"],
        cwd=root,
        check=True,
    )


if __name__ == "__main__":
    main()

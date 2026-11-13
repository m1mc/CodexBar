#!/usr/bin/env python3
"""Point the fork's Homebrew cask and formula at a published m1mc/CodexBar release.

Usage: update_distribution_manifests.py <version> <assets-dir> [repo-root]

The cask is required (the GUI updater reads it); the formula is updated only when every
CLI archive it references is present, so a partial release never ships a broken checksum.
"""

import hashlib
import re
import sys
from pathlib import Path

VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+)*(?:[-.][A-Za-z0-9]+)*")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def version_key(version: str) -> tuple:
    # Numeric parts compare numerically; a prerelease suffix sorts before its final release.
    core, _, suffix = version.partition("-")
    numbers = tuple(int(part) for part in re.findall(r"[0-9]+", core))
    return numbers, suffix == "", suffix


def current_version(source: str) -> str:
    match = re.search(r'(?m)^\s*version\s+"([^"]*)"', source)
    if not match:
        raise SystemExit("expected exactly one version line")
    return match.group(1)


def set_version(source: str, version: str) -> str:
    updated, count = re.subn(r'(?m)^(\s*version\s+)"[^"]*"', rf'\g<1>"{version}"', source)
    if count != 1:
        raise SystemExit("expected exactly one version line")
    return updated


def update_cask(path: Path, version: str, assets: Path) -> None:
    dmg = assets / "CodexBar-macOS.dmg"
    if not dmg.is_file():
        raise SystemExit(f"missing release asset: {dmg.name}")
    source = set_version(path.read_text(), version)
    source, count = re.subn(r'(?m)^(\s*sha256\s+)"[0-9a-f]{64}"', rf'\g<1>"{sha256(dmg)}"', source)
    if count != 1:
        raise SystemExit("expected exactly one cask sha256 line")
    path.write_text(source)


def update_formula(path: Path, version: str, assets: Path) -> bool:
    source = path.read_text()
    archives = re.findall(r'url "[^"]*/(CodexBarCLI-[A-Za-z0-9_.-]+\.tar\.gz)"', source)
    missing = [name for name in archives if not (assets / name).is_file()]
    if not archives or missing:
        print(f"skipping formula; missing CLI archives: {', '.join(missing) or 'none referenced'}", file=sys.stderr)
        return False
    source = set_version(source, version)
    for name in archives:
        pattern = rf'(url "[^"]*/{re.escape(name)}"\s*\n\s*sha256\s+)"[0-9a-f]{{64}}"'
        source, count = re.subn(pattern, rf'\g<1>"{sha256(assets / name)}"', source)
        if count != 1:
            raise SystemExit(f"expected one sha256 line after {name}")
    path.write_text(source)
    return True


def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    version = sys.argv[1].removeprefix("v")
    if not VERSION_PATTERN.fullmatch(version):
        raise SystemExit(f"invalid version: {sys.argv[1]}")
    assets = Path(sys.argv[2])
    root = Path(sys.argv[3]) if len(sys.argv) == 4 else Path(__file__).resolve().parent.parent
    published = current_version((root / "Casks/codexbar.rb").read_text())
    if version_key(version) < version_key(published):
        print(f"cask already points at {published}; not downgrading to {version}", file=sys.stderr)
        return
    update_cask(root / "Casks/codexbar.rb", version, assets)
    update_formula(root / "Formula/codexbar.rb", version, assets)


if __name__ == "__main__":
    main()

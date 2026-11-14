#!/usr/bin/env python3
"""Package the Linux desktop app as a Debian package for Debian/Ubuntu.

Arch-based systems (including Omarchy) use pacman and the release archive;
a .deb is not a native Arch package.
"""
import argparse
import importlib.util
import json
import platform
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

DEPENDS = ", ".join([
    "libc6",
    "libqt6core6t64 | libqt6core6",
    "libqt6gui6t64 | libqt6gui6",
    "libqt6quick6t64 | libqt6quick6",
    "libqt6svg6",
    "qt6-wayland",
    "qml6-module-qtquick",
    "qml6-module-qtquick-controls",
    "qml6-module-qtquick-layouts",
    "qml6-module-qtquick-templates",
    "qml6-module-qtquick-window",
    "qml6-module-qtqml-workerscript",
])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=REPO / '.local/linux-build/codexbar-linux')
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=REPO / '.local/packages')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9][a-zA-Z0-9._-]{0,79}', args.version):
        parser.error('Version must start with a digit and contain only letters, numbers, dots, underscores and hyphens')
    if not args.binary.is_file():
        parser.error('Build the desktop app first, or supply --binary')
    architecture = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    if architecture is None:
        parser.error('Supported architectures: x86_64 and aarch64')
    args.output.mkdir(parents=True, exist_ok=True)
    name = f'CodexBarDesktop-v{args.version}-linux-{architecture}'
    destination = args.output / f'{name}.deb'

    spec = importlib.util.spec_from_file_location('acknowledgements', REPO / 'Scripts/acknowledgements.py')
    notices = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(notices)
    entries = json.loads((REPO / notices.RESOURCE).read_text())
    notices.check(REPO, entries)

    with tempfile.TemporaryDirectory(prefix='codexbar-deb-') as temporary:
        root = Path(temporary)
        stage = root / 'stage'
        (stage / 'DEBIAN').mkdir(parents=True)
        (stage / 'usr/bin').mkdir(parents=True)
        (stage / 'usr/share/applications').mkdir(parents=True)
        (stage / 'usr/share/icons/hicolor/scalable/apps').mkdir(parents=True)
        (stage / 'usr/share/doc/codexbar-desktop').mkdir(parents=True)

        shutil.copy2(args.binary, stage / 'usr/bin/codexbar-linux')
        (stage / 'usr/bin/codexbar-linux').chmod(0o755)
        shutil.copy2(REPO / 'Integrations/Linux/icon.svg',
                     stage / 'usr/share/icons/hicolor/scalable/apps/codexbar.svg')
        shutil.copy2(REPO / 'Integrations/Linux/README.md',
                     stage / 'usr/share/doc/codexbar-desktop/README.md')
        shutil.copy2(REPO / 'LICENSE',
                     stage / 'usr/share/doc/codexbar-desktop/LICENSE')

        desktop = """[Desktop Entry]
Name=CodexBar
Comment=Menu bar usage monitor for AI coding assistants
Exec=codexbar-linux
Icon=codexbar
Type=Application
Categories=Utility;System;
Terminal=false
"""
        (stage / 'usr/share/applications/codexbar.desktop').write_text(desktop, encoding='utf-8')
        (stage / 'usr/share/doc/codexbar-desktop/THIRD_PARTY_NOTICES').write_text(
            notices.render(entries), encoding='utf-8')

        control = f"""Package: codexbar-desktop
Version: {args.version}
Section: utils
Priority: optional
Architecture: {architecture}
Maintainer: CodexBar <noreply@codexbar.app>
Depends: {DEPENDS}
Description: Qt desktop companion for the CodexBar CLI
 CodexBar Desktop displays AI provider usage and spend windows for Wayland and X11.
 It requires the separate codexbar CLI for provider fetching and authentication.
"""
        (stage / 'DEBIAN/control').write_text(control, encoding='utf-8')

        subprocess.run([
            'dpkg-deb', '--root-owner-group', '--build', str(stage), str(destination),
        ], check=True)
    print(destination)


if __name__ == '__main__':
    main()

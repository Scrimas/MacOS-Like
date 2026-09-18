#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the README's before/after images, screenshots/light.png and dark.png.

Each image has two rows: the icon an app gets from MacTahoe as it ships, and
the one it gets from MacOS-Like. Icons are looked up and drawn by Qt, the way
KDE Plasma does it. GTK draws SVGs with librsvg instead, which honours a few
things QtSvg ignores (mix-blend-mode, for one), so a GNOME desktop can differ.

Run it after ./setup.sh. Apps missing from either theme on this machine are
skipped with a note, so another user's images may come out shorter.

Needs PyQt6 (Arch: python-pyqt6, Debian: python3-pyqt6, Fedora: python3-pyqt6).

Usage:  python3 screenshots/render.py [--out DIR]
"""
import argparse
import os
import sys

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
os.environ.setdefault('QT_LOGGING_RULES', 'qt.svg*=false')

from PyQt6.QtCore import QRect, QRectF, QSize, Qt  # noqa: E402
from PyQt6.QtGui import QColor, QFont, QGuiApplication, QIcon, QImage, QPainter  # noqa: E402

# MacTahoe covers nearly every well-known app, so this is a mixed dock:
# familiar MacTahoe apps, which only gain the common shadow and outline (or a
# white tile instead of a graphite one: Kitty, VS Code), alternate with
# uncovered ones, whose bare logos break the look in the first row and sit on
# matching tiles in the second.
LIGHT_APPS = [
    'firefox',
    'account-google',       # uncovered
    'kitty',                # graphite tile
    'R',
    'spotify',
    'proton-pass',          # uncovered
    'visual-studio-code',   # graphite tile
    'claude-desktop',       # uncovered
    'discord',
    'obsidian',
]
# MacTahoe-dark reuses the light tiles; MacOS-Like-Dark darkens the white ones
# (coloured tiles such as Spotify's stay as they are, so they'd show nothing).
# Finder comes first because its dark version is drawn separately (step 5c).
DARK_APPS = [
    'file-manager',
    'firefox',
    'thunderbird',
    'gimp',
    'inkscape',
    'blender',
    'slack',
    'microsoft-edge',
]

S, GAP, PAD, CAP, RADIUS = 128, 28, 44, 58, 36
PALETTE = {'light': ('#f5f5f7', '#1d1d1f'), 'dark': ('#1c1c1e', '#f5f5f7')}


def search_paths():
    """Icon and pixmap directories in the same order setup.sh searches them."""
    home = os.path.expanduser('~')
    data_home = os.environ.get('XDG_DATA_HOME') or os.path.join(home, '.local/share')
    data_dirs = (os.environ.get('XDG_DATA_DIRS') or '/usr/local/share:/usr/share').split(':')
    dirs = [data_home, os.path.join(data_home, 'flatpak/exports/share'), *data_dirs,
            '/var/lib/flatpak/exports/share', '/usr/local/share', '/usr/share']
    dirs = list(dict.fromkeys(d for d in dirs if d))
    icons = [os.path.join(home, '.icons')] + [os.path.join(d, 'icons') for d in dirs]
    pixmaps = [os.path.join(d, 'pixmaps') for d in dirs]
    return [p for p in icons if os.path.isdir(p)], [p for p in pixmaps if os.path.isdir(p)]


def pixmap(theme, name):
    """`name` drawn at S px as `theme` resolves it (following Inherits), or None.
    Drawn right away: a theme QIcon re-resolves whenever the current theme
    changes, so keeping the QIcon around would paint the wrong theme later."""
    QIcon.setThemeName(theme)
    icon = QIcon.fromTheme(name)
    if icon.isNull():
        return None
    return icon.pixmap(QSize(S, S))


def draw(painter, pm, x, y):
    """Fit `pm` into the S x S cell at (x, y). Qt never scales a bitmap icon up,
    but a launcher showing it this large would, so small ones are stretched
    here too. Sizes are taken device-independent: the pixmap can come back at
    2x on a HiDPI session."""
    size = pm.deviceIndependentSize()
    k = S / max(size.width(), size.height())
    w, h = size.width() * k, size.height() * k
    painter.drawPixmap(QRectF(x + (S - w) / 2, y + (S - h) / 2, w, h), pm, QRectF(pm.rect()))


def render(before, after, mode, names, out):
    icons = []
    for n in names:
        pair = pixmap(before, n), pixmap(after, n)
        if None in pair:
            print(f'  skipped {n}: not found in {before if pair[0] is None else after}')
            continue
        icons.append(pair)
    if not icons:
        print(f'  {out}: none of the apps are installed, nothing written')
        return

    w = 2 * PAD + len(icons) * S + (len(icons) - 1) * GAP
    h = 2 * PAD + 2 * (CAP + S) + GAP
    img = QImage(w, h, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    panel, text = PALETTE[mode]

    p = QPainter(img)
    p.setRenderHints(QPainter.RenderHint.Antialiasing
                     | QPainter.RenderHint.SmoothPixmapTransform
                     | QPainter.RenderHint.TextAntialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QColor(panel))
    p.drawRoundedRect(0, 0, w, h, RADIUS, RADIUS)
    font = QFont('Noto Sans')
    font.setPixelSize(26)
    font.setWeight(QFont.Weight.Bold)
    p.setFont(font)
    p.setPen(QColor(text))

    y = PAD
    for row, label in enumerate((before, after)):
        p.drawText(QRect(PAD, y, w - 2 * PAD, CAP), Qt.AlignmentFlag.AlignLeft, label)
        y += CAP
        for i, pair in enumerate(icons):
            draw(p, pair[row], PAD + i * (S + GAP), y)
        y += S + GAP
    p.end()

    if not img.save(out):
        sys.exit(f'could not write {out}')
    print(f'Wrote {out} ({len(icons)} apps)')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--out', default=os.path.dirname(os.path.abspath(__file__)),
                    help='output directory (default: next to this script)')
    args = ap.parse_args()

    app = QGuiApplication([sys.argv[0]])  # noqa: F841 -- must outlive the painting
    icons, pixmaps = search_paths()
    QIcon.setThemeSearchPaths(icons)
    QIcon.setFallbackSearchPaths(pixmaps)

    for theme in ('MacTahoe', 'MacTahoe-dark', 'MacOS-Like-Light', 'MacOS-Like-Dark'):
        if not any(os.path.isfile(os.path.join(d, theme, 'index.theme')) for d in icons):
            sys.exit(f'{theme} is not installed. Run ./setup.sh first.')

    os.makedirs(args.out, exist_ok=True)
    render('MacTahoe', 'MacOS-Like-Light', 'light', LIGHT_APPS,
           os.path.join(args.out, 'light.png'))
    render('MacTahoe-dark', 'MacOS-Like-Dark', 'dark', DARK_APPS,
           os.path.join(args.out, 'dark.png'))


if __name__ == '__main__':
    main()

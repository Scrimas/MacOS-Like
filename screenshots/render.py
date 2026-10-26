#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the README's images: screenshots/preview.png and social-preview.jpg.

preview.png has three cards: well-known apps in MacOS-Like-Light, the same
apps in MacOS-Like-Dark, and apps MacTahoe has no artwork for, each shown as
its own icon and as the tile the two themes made of it. That card shows only
apps installed here, and is left out when none of them is. social-preview.jpg
is the repository's banner (2560 x 1280, GitHub's 2:1): a tilted wall of dark
icons behind the name.

Icons are looked up and drawn by Qt, the way KDE Plasma does it. GTK draws
SVGs with librsvg instead, which honours a few things QtSvg ignores
(mix-blend-mode, for one), so a GNOME desktop can differ.

Run it after ./setup.sh. Needs PyQt6 (Arch: python-pyqt6, Debian:
python3-pyqt6, Fedora: python3-pyqt6).

Usage:  python3 screenshots/render.py [--out DIR]
"""
import argparse
import glob
import math
import os
import sys

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
os.environ.setdefault('QT_LOGGING_RULES', 'qt.svg*=false')

from PyQt6.QtCore import QPointF, QRectF, QSize, Qt  # noqa: E402
from PyQt6.QtGui import (QBrush, QColor, QFont, QFontMetricsF, QGuiApplication, QIcon,  # noqa: E402
                         QImage, QLinearGradient, QPainter, QPainterPath, QRadialGradient)

# Covered by MacTahoe, so every machine renders the same: white tiles, graphite
# ones turned white in Light (Kitty, VS Code), and brand colours.
APPS = [
    'file-manager', 'firefox', 'google-chrome', 'thunderbird', 'kitty',
    'visual-studio-code', 'github-desktop', 'spotify', 'discord', 'telegram',
    'whatsapp', 'slack', 'steam', 'minecraft', 'gimp',
]
# Not covered by MacTahoe: their tiles are made from the app's own icon, so
# these only show up where the apps are installed.
OWN = [
    'craft-photocraft', 'craft-vectorcraft', 'craft-designcraft', 'craft-effectcraft',
    'craft-filmcraft', 'craft-lightcraft', 'craft-pdfcraft', 'claude-desktop', 'proton-pass',
]
# The social preview's wall, in reading order (repeats once it runs out).
WALL = [
    'telegram', 'visual-studio-code', 'microsoft-edge', 'libreoffice-writer', 'discord',
    'file-manager', 'opera', 'spotify', 'dropbox', 'intellij-idea', 'android-studio', 'obs',
    'libreoffice-impress', 'slack', 'kitty', 'vim', 'R', 'skype', 'thunderbird', 'Zoom',
    'brave-browser', 'rhythmbox', 'vivaldi', 'signal-desktop', 'krita', 'firefox', 'vlc',
    'steam', 'figma-linux', 'tidal-hifi', '1password', 'netflix', 'blender', 'teams', 'gimp',
    'obsidian', 'github-desktop', 'libreoffice-calc', 'whatsapp', 'google-chrome', 'minecraft',
    'notion', 'docker', 'inkscape', 'org.gnome.Calendar', 'org.gnome.Weather', 'shotwell',
    'org.gnome.Calculator', 'audacity', 'bitwarden', 'pycharm', 'deezer', 'org.gnome.Maps',
    'kdenlive', 'sublime-text', 'element-desktop', 'calibre', 'preferences-system', 'postman',
    'darktable', 'zotero', 'nextcloud', 'org.gnome.clocks', 'handbrake', 'webstorm', 'anki',
    'qbittorrent', 'retroarch', 'zed', 'virtualbox', 'chromium', 'gitkraken', 'foliate',
    'org.gnome.Software', 'dbeaver',
]

FONT = 'Noto Sans'
INK, PAPER, MUTED = QColor('#1d1d1f'), QColor('#f5f5f7'), QColor('#6e6e73')


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


class Icons:
    """Draws an app's icon as a theme has it, or None. Only a file of that very
    name inside the theme counts: for a name the theme lacks, Qt falls back to
    a shorter name ('notion-app' -> 'notion') and even to the desktop's current
    theme, so a light image could show a dark icon."""

    def __init__(self, icons, pixmaps):
        self.icons, self.pixmaps = icons, pixmaps

    def has(self, theme, name):
        pat = glob.escape(name) + '.*'
        return any(glob.glob(os.path.join(root, theme, '*', '*', pat)) for root in self.icons)

    def get(self, theme, name, px):
        """`name` drawn `px` pixels wide. Drawn right away: a theme QIcon
        re-resolves whenever the current theme changes."""
        if self.has(theme, name):
            QIcon.setThemeName(theme)
            return QIcon.fromTheme(name).pixmap(QSize(px, px))
        if theme == 'hicolor':  # the app's own icon may be a bare pixmap instead
            for d in self.pixmaps:
                for ext in ('svg', 'png'):
                    path = os.path.join(d, f'{name}.{ext}')
                    if os.path.isfile(path):
                        return QIcon(path).pixmap(QSize(px, px))
        return None


def draw(p, pm, x, y, s):
    """Fit `pm` into the s x s cell at (x, y). Qt never scales a bitmap icon up,
    but a launcher showing it this large would, so small ones are stretched
    here too. Sizes are taken device-independent: the pixmap can come back at
    2x on a HiDPI session."""
    size = pm.deviceIndependentSize()
    k = s / max(size.width(), size.height())
    w, h = size.width() * k, size.height() * k
    p.drawPixmap(QRectF(x + (s - w) / 2, y + (s - h) / 2, w, h), pm, QRectF(pm.rect()))


def font(px, weight=QFont.Weight.Bold, spacing=0.0):
    f = QFont(FONT)
    f.setPixelSize(round(px))
    f.setWeight(weight)
    if spacing:
        f.setLetterSpacing(QFont.SpacingType.PercentageSpacing, 100 + spacing)
    return f


def painter(img):
    p = QPainter(img)
    p.setRenderHints(QPainter.RenderHint.Antialiasing
                     | QPainter.RenderHint.SmoothPixmapTransform
                     | QPainter.RenderHint.TextAntialiasing)
    return p


def card(p, rect, top, bottom, radius=22):
    g = QLinearGradient(rect.topLeft(), rect.bottomRight())
    g.setColorAt(0, QColor(top))
    g.setColorAt(1, QColor(bottom))
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(g))
    p.drawRoundedRect(rect, radius, radius)


# ---- preview.png --------------------------------------------------------------
# Laid out in points on a 1280-wide canvas, saved at SCALE.
W, SCALE, PAD = 1280, 1.5, 14
CARD_PAD, TITLE, ICON, COLS, ROW_GAP = 28, 52, 88, 5, 20
OWN_ICON, OWN_GAP, LABEL_W = 72, 22, 132


def preview(icons, out):
    apps = []
    for n in APPS:
        if icons.has('MacOS-Like-Light', n) and icons.has('MacOS-Like-Dark', n):
            apps.append(n)
        else:
            print(f'  skipped {n}: not in both themes')
    own =[n for n in OWN
           if icons.has('MacOS-Like-Light', n) and icons.has('MacOS-Like-Dark', n)
           and icons.get('hicolor', n, 16) is not None]
    if not apps:
        sys.exit('none of the apps are in both themes')

    half = (W - 3 * PAD) / 2
    rows = math.ceil(len(apps) / COLS)
    top_h = CARD_PAD + TITLE + rows * ICON + (rows - 1) * ROW_GAP + CARD_PAD
    # the Dark row sits in a dark band at the bottom: CARD_PAD above, in and below it
    own_h = CARD_PAD + TITLE + 3 * OWN_ICON + OWN_GAP + 3 * CARD_PAD if own else 0
    h = PAD + top_h + PAD + (own_h + PAD if own else 0)

    img = QImage(round(W * SCALE), round(h * SCALE), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    p = painter(img)
    p.scale(SCALE, SCALE)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QColor('#c9cdd6'))
    p.drawRoundedRect(QRectF(0, 0, W, h), 18, 18)
    px = round(ICON * SCALE * 2)  # oversampled: drawn smooth, never upscaled

    for i, (theme, top, bottom, ink) in enumerate((
            ('MacOS-Like-Light', '#ffffff', '#eef1f6', INK),
            ('MacOS-Like-Dark', '#262930', '#111216', PAPER))):
        x = PAD + i * (half + PAD)
        card(p, QRectF(x, PAD, half, top_h), top, bottom)
        p.setFont(font(18))
        p.setPen(ink)
        p.drawText(QRectF(x + CARD_PAD, PAD + CARD_PAD, half, TITLE), Qt.AlignmentFlag.AlignTop, theme)
        cell = (half - 2 * CARD_PAD) / COLS
        for k, n in enumerate(apps):
            r, c = divmod(k, COLS)
            draw(p, icons.get(theme, n, px), x + CARD_PAD + c * cell + (cell - ICON) / 2,
                 PAD + CARD_PAD + TITLE + r * (ICON + ROW_GAP), ICON)

    if own:
        y = PAD + top_h + PAD
        rect = QRectF(PAD, y, W - 2 * PAD, own_h)
        card(p, rect, '#f4efe9', '#e7ecf6')
        band = y + CARD_PAD + TITLE + 2 * OWN_ICON + OWN_GAP + CARD_PAD
        clip = QPainterPath()
        clip.addRoundedRect(rect, 22, 22)
        p.save()
        p.setClipPath(clip)
        card(p, QRectF(PAD, band, W - 2 * PAD, y + own_h - band), '#262930', '#111216', 0)
        p.restore()
        p.setFont(font(18))
        p.setPen(INK)
        p.drawText(QRectF(PAD + CARD_PAD, y + CARD_PAD, W, TITLE), Qt.AlignmentFlag.AlignTop,
                   'Every other app gets a matching tile, made from its own icon')
        step = OWN_ICON + OWN_GAP
        x0 = (W - LABEL_W - len(own) * step + OWN_GAP) / 2
        opx = round(OWN_ICON * SCALE * 2)
        for theme, label, ry, ink in (
                ('hicolor', 'App icon', y + CARD_PAD + TITLE, MUTED),
                ('MacOS-Like-Light', 'Light', y + CARD_PAD + TITLE + OWN_ICON + OWN_GAP, MUTED),
                ('MacOS-Like-Dark', 'Dark', band + CARD_PAD, QColor('#a1a1a6'))):
            p.setFont(font(13, QFont.Weight.DemiBold, 8))
            p.setPen(ink)
            p.drawText(QRectF(x0, ry, LABEL_W, OWN_ICON), Qt.AlignmentFlag.AlignVCenter, label.upper())
            for k, n in enumerate(own):
                draw(p, icons.get(theme, n, opx), x0 + LABEL_W + k * step, ry, OWN_ICON)
    p.end()
    save(img, out, f'{len(apps)} apps, {len(own)} of their own')


# ---- social-preview.jpg -------------------------------------------------------
SW, SH, BG = 2560, 1280, QColor('#0d0d0f')
S_ICON, S_PITCH, S_TILT = 196, 262, -13


def social(icons, out):
    wall = [n for n in WALL if icons.has('MacOS-Like-Dark', n)]
    if not wall:
        sys.exit('none of the social preview apps are in MacOS-Like-Dark')
    img = QImage(SW, SH, QImage.Format.Format_RGB32)
    img.fill(BG)
    p = painter(img)
    cos, sin = math.cos(math.radians(S_TILT)), math.sin(math.radians(S_TILT))
    reach = math.hypot(SW, SH) / 2 / S_PITCH + 1
    k = 0
    for j in range(-math.ceil(reach), math.ceil(reach) + 1):
        for i in range(-math.ceil(reach), math.ceil(reach) + 1):
            # half-pitch offset: the wall isn't centred on an icon
            gx, gy = (i + 0.5) * S_PITCH, (j + 0.5) * S_PITCH
            cx, cy = SW / 2 + gx * cos - gy * sin, SH / 2 + gx * sin + gy * cos
            if not (-S_ICON < cx < SW + S_ICON and -S_ICON < cy < SH + S_ICON):
                continue
            pm = icons.get('MacOS-Like-Dark', wall[k % len(wall)], S_ICON)
            k += 1
            p.save()
            p.translate(cx, cy)
            p.rotate(S_TILT)
            draw(p, pm, -S_ICON / 2, -S_ICON / 2, S_ICON)
            p.restore()

    # Fade the wall behind the text: an elliptic pool of background colour.
    p.save()
    p.translate(SW / 2, SH / 2)
    p.scale(1, 0.46)
    g = QRadialGradient(QPointF(0, 0), 1050)
    for at, a in ((0, 0.9), (0.5, 0.82), (0.8, 0.35), (1, 0)):
        c = QColor(BG)
        c.setAlphaF(a)
        g.setColorAt(at, c)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(g))
    p.drawEllipse(QPointF(0, 0), 1050, 1050)
    p.restore()

    title = font(100, QFont.Weight.Bold, -2)
    title.setPixelSize(round(100 * 1250 / QFontMetricsF(title).horizontalAdvance('MacOS-Like')))
    text(p, 'MacOS-Like', title, PAPER, SH * 0.455)
    text(p, 'Icon themes for Linux', font(66, QFont.Weight.Normal), QColor('#dcdce0'), SH * 0.6)
    p.end()
    save(img, out, f'{k} icons')


def text(p, s, f, color, cy):
    """`s` centred horizontally, its capitals centred on `cy`."""
    m = QFontMetricsF(f)
    path = QPainterPath()
    path.addText(QPointF((SW - m.horizontalAdvance(s)) / 2, cy + m.capHeight() / 2), f, s)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(color)
    p.drawPath(path)


def save(img, out, what):
    if not img.save(out, quality=92 if out.endswith('.jpg') else -1):
        sys.exit(f'could not write {out}')
    print(f'Wrote {out} ({what})')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--out', default=os.path.dirname(os.path.abspath(__file__)),
                    help='output directory (default: next to this script)')
    args = ap.parse_args()

    app = QGuiApplication([sys.argv[0]])  # noqa: F841 -- must outlive the painting
    icons, pixmaps = search_paths()
    QIcon.setThemeSearchPaths(icons)
    QIcon.setFallbackSearchPaths(pixmaps)
    finder = Icons(icons, pixmaps)
    for theme in ('MacOS-Like-Light', 'MacOS-Like-Dark'):
        if not any(os.path.isfile(os.path.join(d, theme, 'index.theme')) for d in icons):
            sys.exit(f'{theme} is not installed. Run ./setup.sh first.')

    os.makedirs(args.out, exist_ok=True)
    preview(finder, os.path.join(args.out, 'preview.png'))
    social(finder, os.path.join(args.out, 'social-preview.jpg'))


if __name__ == '__main__':
    main()

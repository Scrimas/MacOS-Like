#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
recolor_folders.py — tint the macOS folder icons with a fixed colour or the
current matugen palette.

Edits MacOS-Like-Light / MacOS-Like-Dark in place. Only files under
places/scalable/ that use the macOS folder blue ramp are touched; app icons,
mimetypes, actions, devices and status icons are left completely alone.

A pristine copy of every touched file is kept in BASELINE_DIR on first run, and
every later run recolors *from that baseline* — so repeated runs never compound
and the original blue is always recoverable (--restore).

The tint is the newest of TINT_FILE (written by --color and by matugen's
template) and the legacy Quickshell tint file, so whichever was set last wins.
setup.sh re-applies it after every rebuild.

Usage:
    recolor_folders.py                  # recolor from the last tint set
    recolor_folders.py --color '#ffb690'
    recolor_folders.py --setup          # matugen only: install as post-hook + template
    recolor_folders.py --recapture      # also prune baseline entries the theme dropped
    recolor_folders.py --restore        # put the original blue icons back
    recolor_folders.py --preview        # also write a before/after PNG
"""
import argparse
import colorsys
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HOME = os.path.expanduser("~")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")
STATE_HOME = os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")

# ── Tuning ───────────────────────────────────────────────────────────────────
TINT_KEY = "primary"      # matugen role driving the hue
SAT_BLEND = 0.5           # 0 = keep the folder's own saturation, 1 = adopt the tint's
LIGHT_SHIFT = 0.0         # + brightens the whole folder, - darkens it

THEMES = ["MacOS-Like-Light", "MacOS-Like-Dark"]
SCOPE = os.path.join("places", "scalable")

# The macOS folder ramp. These seven only ever appear on folder artwork inside
# places/; #5294e2 is deliberately excluded (generic Breeze blue, used by
# actions/, devices/ and status/ icons too).
RAMP = ["#88ccf2", "#7cc1ea", "#67b1de", "#56a1d3", "#83d4fb", "#60c0f0", "#46a2d7"]

# ── Paths ────────────────────────────────────────────────────────────────────
ICONS_DIR = os.path.join(DATA_HOME, "icons")
STATE_DIR = os.path.join(STATE_HOME, "folder-icons")
BASELINE_DIR = os.path.join(STATE_DIR, "baseline")
TINT_FILE = os.path.join(STATE_DIR, "tint.txt")
# Quickshell setups (end-4's dots) had matugen write the tint here, next to
# their full palette; both are still read so those configs keep working.
LEGACY_DIR = os.path.join(STATE_HOME, "quickshell/user/generated")
LEGACY_TINT_FILE = os.path.join(LEGACY_DIR, "folder-tint.txt")
COLORS_JSON = os.path.join(LEGACY_DIR, "colors.json")

MATUGEN_CONFIG = os.path.join(CONFIG_HOME, "matugen/config.toml")
TEMPLATE_DIR = os.path.join(CONFIG_HOME, "matugen/templates/folder-icons")
TEMPLATE_FILE = os.path.join(TEMPLATE_DIR, "tint.txt")
SELF = os.path.join(CONFIG_HOME, "matugen/post-hook-scripts/recolor_folders.py")

HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


# ── Colour maths ─────────────────────────────────────────────────────────────
def hex_to_hls(h):
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return colorsys.rgb_to_hls(r, g, b)


def hls_to_hex(h, l, s):
    r, g, b = colorsys.hls_to_rgb(h, min(1.0, max(0.0, l)), min(1.0, max(0.0, s)))
    return "#%02x%02x%02x" % tuple(round(c * 255) for c in (r, g, b))


def build_map(tint):
    """Rotate the ramp onto the tint's hue, keeping each shade's own lightness."""
    th, _, ts = hex_to_hls(tint)
    out = {}
    for src in RAMP:
        _, l, s = hex_to_hls(src)
        out[src] = hls_to_hex(th, l + LIGHT_SHIFT, s + (ts - s) * SAT_BLEND)
    return out


# ── Tint discovery ───────────────────────────────────────────────────────────
def resolve_tint(explicit):
    """(tint, origin), or (None, None) when no tint has ever been set.

    An explicit --color wins and is saved to TINT_FILE, so the next rebuild
    re-applies it. Otherwise the newer of the two tint files wins: a --color
    run and matugen's template overwrite each other, the latest one counts."""
    if explicit is not None:
        if not HEX_RE.match(explicit):
            sys.exit(f"error: --color expects #rrggbb, got {explicit!r}")
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(TINT_FILE, "w") as f:
            f.write(explicit.lower() + "\n")
        return explicit.lower(), "--color"
    files = sorted((p for p in (TINT_FILE, LEGACY_TINT_FILE) if os.path.isfile(p)),
                   key=os.path.getmtime, reverse=True)
    candidates = [(_read_file(p), p) for p in files]
    candidates.append((_read_json_key(COLORS_JSON, TINT_KEY), COLORS_JSON))
    for value, origin in candidates:
        if value and HEX_RE.match(value):
            return value.lower(), origin
    return None, None


def _read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def _read_json_key(path, key):
    try:
        with open(path) as f:
            return json.load(f).get(key)
    except (OSError, ValueError):
        return None


# ── Baseline ─────────────────────────────────────────────────────────────────
def theme_targets(theme):
    """Real .svg files under <theme>/places/scalable (symlinks follow their target)."""
    root = os.path.join(ICONS_DIR, theme, SCOPE)
    if not os.path.isdir(root):
        return []
    return sorted(
        f for f in os.listdir(root)
        if f.endswith(".svg") and not os.path.islink(os.path.join(root, f))
    )


def capture(theme, force=False):
    """Refresh the baseline from disk, then return its file list.

    A file that still contains ramp colours has not been tinted yet, so it is
    always safe to (re)capture it. That is what makes this self-healing: step 0
    of setup.sh rsyncs MacTahoe back over both themes on every build, and
    the next run simply re-adopts those pristine files as the new baseline —
    picking up any folder artwork MacTahoe has added or changed in the meantime.

    The store is never emptied, so an already-tinted theme can never erase it.
    """
    store = os.path.join(BASELINE_DIR, theme)
    os.makedirs(store, exist_ok=True)
    before = set(f for f in os.listdir(store) if f.endswith(".svg"))

    root = os.path.join(ICONS_DIR, theme, SCOPE)
    live = theme_targets(theme)
    for name in live:
        path = os.path.join(root, name)
        with open(path) as f:
            body = f.read()
        if any(c in body.lower() for c in RAMP):
            shutil.copy2(path, os.path.join(store, name))

    if force:
        # only --recapture prunes: drop entries whose theme file is gone entirely
        for name in before - set(live):
            os.remove(os.path.join(store, name))
            print(f"  {theme}: dropped stale baseline entry {name}")

    names = sorted(f for f in os.listdir(store) if f.endswith(".svg"))
    added = len(set(names) - before)
    if added:
        print(f"  {theme}: baseline +{added} file(s) ({len(names)} total)")
    return names


# ── Apply ────────────────────────────────────────────────────────────────────
def recolor_theme(theme, cmap, force=False):
    store = os.path.join(BASELINE_DIR, theme)
    root = os.path.join(ICONS_DIR, theme, SCOPE)
    names = capture(theme, force=force)
    if not names:
        print(f"  {theme}: nothing to do")
        return 0

    for name in names:
        with open(os.path.join(store, name)) as f:
            body = f.read()
        for src, dst in cmap.items():
            body = re.sub(re.escape(src), dst, body, flags=re.IGNORECASE)
        with open(os.path.join(root, name), "w") as f:
            f.write(body)
    return len(names)


def restore_theme(theme):
    store = os.path.join(BASELINE_DIR, theme)
    root = os.path.join(ICONS_DIR, theme, SCOPE)
    if not os.path.isdir(store):
        print(f"  {theme}: no baseline, nothing to restore")
        return 0
    names = [f for f in os.listdir(store) if f.endswith(".svg")]
    for name in names:
        shutil.copy2(os.path.join(store, name), os.path.join(root, name))
    return len(names)


def refresh_caches():
    for theme in THEMES:
        cache = os.path.join(ICONS_DIR, theme, "icon-theme.cache")
        if os.path.exists(cache):
            os.remove(cache)
    if shutil.which("kbuildsycoca6"):
        subprocess.run(["kbuildsycoca6", "--noincremental"], capture_output=True)
    # GTK reads this cache; setup.sh rebuilds it in its own last step, but
    # the folder tint is applied after that, so refresh both themes here too.
    for theme in THEMES:
        for tool in ("gtk4-update-icon-cache", "gtk-update-icon-cache"):
            if shutil.which(tool):
                subprocess.run([tool, "-q", "-f", os.path.join(ICONS_DIR, theme)],
                               capture_output=True)
                break
    # nudge Plasma into re-reading the icon theme
    if shutil.which("plasma-changeicons"):
        current = _current_icon_theme()
        if current:
            subprocess.run(["plasma-changeicons", current], capture_output=True)


def _current_icon_theme():
    try:
        with open(os.path.join(CONFIG_HOME, "kdeglobals")) as f:
            block = False
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    block = line == "[Icons]"
                elif block and line.startswith("Theme="):
                    return line.split("=", 1)[1]
    except OSError:
        pass
    return None


# ── matugen integration (--setup only) ──────────────────────────────────────
def setup():
    """Install this script as matugen's post-hook, create the template that feeds
    it the palette colour and register both in config.toml. Idempotent."""
    if not os.path.exists(MATUGEN_CONFIG):
        sys.exit(f"error: {MATUGEN_CONFIG} not found. --setup is for matugen users; "
                 "without matugen, pick a colour with --color '#rrggbb'.")
    here = os.path.realpath(__file__)
    if here != os.path.realpath(SELF):
        os.makedirs(os.path.dirname(SELF), exist_ok=True)
        shutil.copy2(here, SELF)
        print(f"  installed {SELF}")
    os.makedirs(TEMPLATE_DIR, exist_ok=True)
    wanted = "{{colors.%s.default.hex}}\n" % TINT_KEY
    if _read_file(TEMPLATE_FILE) != wanted.strip():
        with open(TEMPLATE_FILE, "w") as f:
            f.write(wanted)
        print(f"  wrote {TEMPLATE_FILE}")

    with open(MATUGEN_CONFIG) as f:
        conf = f.read()
    if "[templates.folder_icons]" in conf:
        return
    shutil.copy2(MATUGEN_CONFIG, MATUGEN_CONFIG + ".bak-folder-icons")
    block = (
        "\n# Tints the macOS folder icons in MacOS-Like-{Light,Dark} with the current palette.\n"
        "# The post-hook reads this template's own output, so the colour is always fresh.\n"
        "[templates.folder_icons]\n"
        f"input_path = '{TEMPLATE_FILE.replace(HOME, '~')}'\n"
        f"output_path = '{TINT_FILE.replace(HOME, '~')}'\n"
        f"post_hook = 'python3 {SELF.replace(HOME, '~')}'\n"
    )
    with open(MATUGEN_CONFIG, "a") as f:
        f.write(block)
    print(f"  registered [templates.folder_icons] in {MATUGEN_CONFIG}")
    print("  the folders take the palette colour from the next matugen run")


# ── Preview ──────────────────────────────────────────────────────────────────
def preview(out_path):
    if not shutil.which("rsvg-convert") or not shutil.which("magick"):
        print("  ! rsvg-convert/magick missing, skipping preview")
        return None
    theme = THEMES[1]
    pairs = [("folder.svg", "folder"), ("folder-open.svg", "open"),
             ("user-home.svg", "home"), ("folder-download.svg", "download")]
    with tempfile.TemporaryDirectory(prefix="folder-preview-") as tmp:
        tiles = []
        for stage, root in (("before", os.path.join(BASELINE_DIR, theme)),
                            ("after", os.path.join(ICONS_DIR, theme, SCOPE))):
            for svg, label in pairs:
                src = os.path.join(root, svg)
                if not os.path.exists(src):
                    continue
                png = os.path.join(tmp, f"{stage}-{label}.png")
                subprocess.run(["rsvg-convert", "-w", "160", "-h", "160", src, "-o", png],
                               capture_output=True)
                tiles.append(png)
        if not tiles:
            return None
        subprocess.run(["magick", "montage", *tiles, "-tile", f"{len(tiles)//2}x2",
                        "-geometry", "+8+8", "-background", "#1a120e", out_path],
                       capture_output=True)
    return out_path if os.path.exists(out_path) else None


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--color", help="tint colour as #rrggbb (saved; the latest tint wins)")
    ap.add_argument("--setup", action="store_true",
                    help="matugen only: install as post-hook and register the template")
    ap.add_argument("--recapture", action="store_true",
                    help="also prune baseline entries whose theme file no longer exists")
    ap.add_argument("--restore", action="store_true",
                    help="restore the original blue icons and forget a --color tint")
    ap.add_argument("--preview", metavar="PNG", nargs="?",
                    const=os.path.join(tempfile.gettempdir(), "folder-preview.png"),
                    help="also render a before/after montage")
    ap.add_argument("--if-set", action="store_true",
                    help="do nothing when no tint has been set (used by setup.sh)")
    args = ap.parse_args()

    if args.setup:
        print("[setup] wiring up matugen")
        setup()
        return

    if args.restore:
        print("[restore] reverting to the original blue folders")
        for theme in THEMES:
            n = restore_theme(theme)
            print(f"  {theme}: {n} file(s)")
        # without this, the next setup.sh rebuild would tint them again
        if os.path.exists(TINT_FILE):
            os.remove(TINT_FILE)
        refresh_caches()
        return

    tint, origin = resolve_tint(args.color)
    if tint is None:
        if args.if_set:
            print("[tint] none set, folders keep MacTahoe's blue")
            return
        sys.exit(f"error: no tint set. Pass --color '#rrggbb', or run --setup to follow "
                 f"matugen (looked in {TINT_FILE}, {LEGACY_TINT_FILE}, {COLORS_JSON})")
    cmap = build_map(tint)
    print(f"[tint] {tint} (from {origin})")
    for src, dst in cmap.items():
        print(f"  {src} -> {dst}")

    total = 0
    for theme in THEMES:
        n = recolor_theme(theme, cmap, force=args.recapture)
        print(f"  {theme}: {n} file(s) recoloured")
        total += n

    refresh_caches()
    print(f"[done] {total} folder icon(s) tinted")

    if args.preview:
        out = preview(args.preview)
        if out:
            print(f"[preview] {out}")


if __name__ == "__main__":
    main()

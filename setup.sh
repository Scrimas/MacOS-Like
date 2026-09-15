#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# setup.sh — generate the MacOS-Like-Light / MacOS-Like-Dark icon themes.
#
# Scans all installed .desktop files, finds app icons that MacTahoe does NOT
# cover, and composites each app's own artwork onto a macOS Tahoe squircle
# tile (geometry matched to MacTahoe: margin 4/64, radius 13/64, top-lit
# gradient, drop shadow).
#
# Three source-art classes are handled differently:
#   1. full-bleed square art  -> becomes the squircle itself (clipped)
#   2. solid disc/blob badge  -> its own background is bled out to the squircle
#   3. shaped / transparent   -> centered glyph on a Tahoe tile
#      logo                      (white tile in the light theme, near-black
#                                glass in dark -- see DARK_TILE_* below)
#
# Both themes are self-contained: the whole MacTahoe tree is mirrored into each
# one (dark overlaid from MacTahoe-dark), so they render without MacTahoe
# installed and only fall back to a parent theme (breeze-plus, breeze, Papirus
# or Adwaita, whichever is installed) for what MacTahoe never had.
#
# Input:  MacTahoe (or the --source variant) from ~/.icons, ~/.local/share/icons
#         or any $XDG_DATA_DIRS/icons -- a user or a system-wide install.
# Output: $XDG_DATA_HOME/icons/MacOS-Like-{Light,Dark} (default ~/.local/share/icons)
#
# Rerunnable: already-generated icons are skipped. Use --force to regenerate.
#
# Usage:  setup.sh [--force] [--dry-run] [--source NAME|DIR]
#                  [--inherits-light LIST] [--inherits-dark LIST]

set -euo pipefail

USAGE="usage: setup.sh [--force] [--dry-run] [--source NAME|DIR]
                [--inherits-light LIST] [--inherits-dark LIST]"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
THEME_LIGHT="$DATA_HOME/icons/MacOS-Like-Light"
THEME_DARK="$DATA_HOME/icons/MacOS-Like-Dark"
SIZES=(16 22 24 32 48 64 96 128 256 512)

# Dark-theme tile: near-black "glass" rather than a mid grey, matching Tahoe's
# dark appearance -- a very dark neutral ramp plus a white sheen down the top of
# the squircle. Defined once here and passed into both the Pillow pass (step 5)
# and the SVG re-tint (step 5b) so the raster and vector icons agree.
DARK_TILE_TOP="#2c2c2f"     # top of the tile gradient
DARK_TILE_BOT="#1c1c1e"     # bottom
DARK_TILE_HL="0.10"         # white sheen opacity at the top edge, fading to 0
DARK_TILE_HL_SPAN="0.55"    # fraction of the tile height the sheen covers
DARK_TILE_RIM="0.35"        # corner rim glow: 1px inset stroke on the squircle,
                            # lit from the top-left and bottom-right corners.
                            # Matches the rim MacTahoe already bakes into a few
                            # icons (Finder, Obsidian); 0 disables it.

# Apps whose icon should come from a specific file rather than from MacTahoe or
# from the usual source-art search. The file is run through the same tile wrap as
# every other app, so the result is a macOS-shaped icon carrying that artwork.
# One "icon-name=/path/to/source.svg-or-png" per line; blank lines and lines
# starting with # are skipped, and a leading ~/ is expanded.
OVERRIDES_FILE="$CONFIG_HOME/macos-like/overrides.conf"

FORCE=0
DRYRUN=0
SOURCE=MacTahoe
INHERITS_LIGHT=""
INHERITS_DARK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRYRUN=1 ;;
    --source) SOURCE="${2:?--source needs a theme name or directory}"; shift ;;
    --inherits-light) INHERITS_LIGHT="${2:?--inherits-light needs a list}"; shift ;;
    --inherits-dark) INHERITS_DARK="${2:?--inherits-dark needs a list}"; shift ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done

# --- Dependencies -------------------------------------------------------------
# Checked up front: a tool that turns out to be missing mid-run would stop the
# build halfway through. --dry-run only reports them.
missing=()
command -v python3 >/dev/null 2>&1 || missing+=("python3")
python3 -c 'import PIL' 2>/dev/null \
  || missing+=("Pillow        (Arch: python-pillow  Debian/Ubuntu: python3-pil   Fedora: python3-pillow)")
command -v rsvg-convert >/dev/null 2>&1 \
  || missing+=("rsvg-convert  (Arch: librsvg        Debian/Ubuntu: librsvg2-bin  Fedora: librsvg2-tools)")
command -v rsync >/dev/null 2>&1 || missing+=("rsync")
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'missing dependency: %s\n' "${missing[@]}" >&2
  [ "$DRYRUN" -eq 1 ] || exit 1
fi

# --- Search paths -------------------------------------------------------------
# XDG data dirs in spec order, plus the usual system and Flatpak roots even when
# $XDG_DATA_DIRS leaves them out. They are searched for the MacTahoe source, the
# parent theme, .desktop files and source artwork alike.
IFS=: read -ra xdg_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
DATA_DIRS=()
declare -A seen=()
for d in "$DATA_HOME" "$DATA_HOME/flatpak/exports/share" "${xdg_dirs[@]}" \
         /var/lib/flatpak/exports/share /usr/local/share /usr/share; do
  [ -n "$d" ] && [ -z "${seen[$d]:-}" ] || continue
  seen[$d]=1
  DATA_DIRS+=("$d")
done
ICON_BASES=("$HOME/.icons")
for d in "${DATA_DIRS[@]}"; do ICON_BASES+=("$d/icons"); done

# Directory of an installed icon theme: first match in lookup order.
theme_dir() {
  local b
  for b in "${ICON_BASES[@]}"; do
    [ -f "$b/$1/index.theme" ] && { echo "$b/$1"; return 0; }
  done
  return 1
}

# --- Source theme -------------------------------------------------------------
# A name is looked up like any icon theme (user install first); anything with a
# slash is taken as the theme directory itself.
MACTAHOE_URL="https://github.com/vinceliuice/MacTahoe-icon-theme"

resolve_source() {
  MACTAHOE=""
  if [[ "$SOURCE" == */* ]]; then
    MACTAHOE="${SOURCE%/}"
  else
    MACTAHOE="$(theme_dir "$SOURCE")" || MACTAHOE=""
  fi
  [ -n "$MACTAHOE" ] && [ -f "$MACTAHOE/index.theme" ] && [ -d "$MACTAHOE/apps/scalable" ]
}

# Download upstream MacTahoe and run its own installer into the user's icon dir
# (no root needed); $1 is its colour variant (default, nord, ...). A subshell,
# so the temp dir goes with it; every step is checked because the caller's `||`
# switches set -e off in here.
install_mactahoe() (
  url="$MACTAHOE_URL/archive/refs/heads/main.tar.gz"
  if command -v curl >/dev/null 2>&1; then fetch=(curl -fsSL "$url")
  elif command -v wget >/dev/null 2>&1; then fetch=(wget -qO- "$url")
  else echo "Installing MacTahoe needs curl or wget." >&2; exit 1
  fi
  tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading $url ..."
  "${fetch[@]}" | tar -xz -C "$tmp" --strip-components=1 || exit 1
  # As the AUR package does: install.sh ends every theme with a bare
  # gtk-update-icon-cache that aborts the install where that tool is missing.
  # Step 6 rebuilds the caches this script actually uses.
  sed -i '/gtk-update-icon-cache/d' "$tmp/install.sh" || exit 1
  mkdir -p "$DATA_HOME/icons" || exit 1
  bash "$tmp/install.sh" -d "$DATA_HOME/icons" -t "$1"
)

if ! resolve_source; then
  # Only the stock names can be installed: MacTahoe or MacTahoe-<colour>.
  variant=""
  case "$SOURCE" in
    MacTahoe) variant=default ;;
    MacTahoe-blue|MacTahoe-purple|MacTahoe-green|MacTahoe-red|MacTahoe-orange\
    |MacTahoe-yellow|MacTahoe-grey|MacTahoe-nord) variant="${SOURCE#MacTahoe-}" ;;
  esac
  if [ -n "$variant" ] && [ "$DRYRUN" -eq 0 ] && [ -t 0 ]; then
    read -r -p "$SOURCE icon theme is not installed. Download it from $MACTAHOE_URL
and install it to $DATA_HOME/icons? [Y/n] " answer || answer=n
    case "$answer" in
      ""|[Yy]|[Yy][Ee][Ss])
        install_mactahoe "$variant" || { echo "MacTahoe install failed." >&2; exit 1; }
        resolve_source || true ;;
    esac
  fi
fi
if ! resolve_source; then
  echo "MacTahoe icon theme '$SOURCE' not found. Searched: ${ICON_BASES[*]}" >&2
  echo "Install it ($MACTAHOE_URL, or the AUR package mactahoe-icon-theme-git)," \
       "or pass --source NAME|DIR." >&2
  if [ -n "${variant:-}" ] && { [ "$DRYRUN" -eq 1 ] || [ ! -t 0 ]; }; then
    echo "Run from a terminal without --dry-run to be offered the install." >&2
  fi
  exit 1
fi
case "$MACTAHOE" in
  "$THEME_LIGHT"|"$THEME_DARK")
    echo "--source must be a MacTahoe theme, not this script's output" >&2; exit 2 ;;
esac
# The dark variant only works from the same directory: its apps/scalable is a
# relative symlink into the light theme.
MACTAHOE_DARK="$MACTAHOE-dark"
[ -d "$MACTAHOE_DARK" ] \
  || echo "warning: $MACTAHOE_DARK not found; the dark theme starts from light artwork" >&2
echo "Source: $MACTAHOE"

# --- Parent themes ------------------------------------------------------------
# What MacTahoe lacks (plenty of actions/, status/ and mimetypes/ names) comes
# from the first of these that is installed; hicolor always closes the chain.
parent_chain() {
  local t
  for t in "$@"; do
    theme_dir "$t" >/dev/null && { echo "$t,hicolor"; return 0; }
  done
  echo hicolor
}
[ -n "$INHERITS_LIGHT" ] \
  || INHERITS_LIGHT=$(parent_chain breeze-plus breeze Papirus-Light Papirus Adwaita)
[ -n "$INHERITS_DARK" ] \
  || INHERITS_DARK=$(parent_chain breeze-plus-dark breeze-dark Papirus-Dark Adwaita)
echo "Inherits: $INHERITS_LIGHT (light), $INHERITS_DARK (dark)"

# --- Folder tint (optional) ---------------------------------------------------
# matugen in use but the folder hook not wired up yet: offer it. --setup copies
# recolor_folders.py into matugen's post-hook-scripts and registers the template,
# so the folders follow the wallpaper palette. Asked up front, like the MacTahoe
# install, so the build itself runs unattended; a "no" is remembered.
REPO_DIR="$(dirname "$(readlink -f "$0")")"
MATUGEN_CONFIG="$CONFIG_HOME/matugen/config.toml"
MATUGEN_HOOK="$CONFIG_HOME/matugen/post-hook-scripts/recolor_folders.py"
NO_TINT_PROMPT="$CONFIG_HOME/macos-like/no-matugen-prompt"
if [ "$DRYRUN" -eq 0 ] && [ -t 0 ] && [ ! -e "$NO_TINT_PROMPT" ] \
   && command -v matugen >/dev/null 2>&1 && [ -f "$MATUGEN_CONFIG" ] \
   && { [ ! -f "$MATUGEN_HOOK" ] \
        || ! grep -qF '[templates.folder_icons]' "$MATUGEN_CONFIG"; }; then
  read -r -p "matugen found. Tint the folder icons with its palette? This installs a
post-hook in $MATUGEN_CONFIG (a backup is kept). [Y/n] " answer || answer=n
  case "$answer" in
    ""|[Yy]|[Yy][Ee][Ss])
      python3 "$REPO_DIR/matugen/recolor_folders.py" --setup \
        || echo "  matugen setup failed (non-fatal)" >&2 ;;
    *)
      mkdir -p "${NO_TINT_PROMPT%/*}" && : > "$NO_TINT_PROMPT"
      echo "  Not asking again; delete $NO_TINT_PROMPT to be asked." ;;
  esac
fi

# --- Overrides ----------------------------------------------------------------
OVERRIDES=()
if [ -f "$OVERRIDES_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != ?*=?* ]]; then
      echo "  $OVERRIDES_FILE: ignoring '$line' (want name=path)" >&2
      continue
    fi
    src="${line#*=}"
    [[ "$src" == \~/* ]] && src="$HOME/${src:2}"
    OVERRIDES+=("${line%%=*}=$src")
  done < "$OVERRIDES_FILE"
fi

# --- index.theme --------------------------------------------------------------
# Derived from MacTahoe's, so every context directory it ships is declared here
# too; only the identity, the inherit chain and the extra apps/<size> dirs
# holding the generated PNGs differ. Written right after the mirror, before any
# generation step: if one of those fails, the theme is still complete and usable.
write_index() {
  python3 - "$MACTAHOE/index.theme" "$1/index.theme" "$2" "$3" "${SIZES[*]}" <<'PYEOF'
import sys

src, dst, name, inherits, sizes = sys.argv[1:6]
extra, out = [], []
for ln in open(src, encoding='utf-8').read().splitlines():
    if ln.startswith('KDE-Extensions='):
        # MacTahoe is all-SVG and declares .svg only; that key makes KIconTheme
        # skip every .png in the theme, generated app icons included.
        ln = 'KDE-Extensions=.svg,.png'
    elif ln.startswith('Name='):
        ln = 'Name=' + name
    elif ln.startswith('Comment='):
        ln = 'Comment=macOS Tahoe theme: MacTahoe base + auto-wrapped app icons'
    elif ln.startswith('Inherits='):
        ln = 'Inherits=' + inherits
    elif ln.startswith('Directories='):
        dirs = [d for d in ln.split('=', 1)[1].split(',') if d]
        extra = ['apps/' + z for z in sizes.split() if 'apps/' + z not in dirs]
        ln = 'Directories=' + ','.join(dirs + extra)
    out.append(ln)

for d in extra:
    out += ['', '[%s]' % d, 'Size=%s' % d.split('/')[1],
            'Context=Applications', 'Type=Fixed']
open(dst, 'w', encoding='utf-8').write('\n'.join(out).rstrip('\n') + '\n')
PYEOF
}

# --- 0. Mirror the MacTahoe tree into both themes -----------------------------
# Real copies, so each theme is a complete theme on its own. rsync keeps the
# thousands of alias symlinks that point *inside* the tree as symlinks, and
# --copy-unsafe-links dereferences the ones that escape it (MacTahoe-dark's
# apps/scalable -> ../../MacTahoe/apps/scalable, its animations/emotes/
# preferences top-level links) so nothing in the output points back at MacTahoe.
# index.theme is written by write_index; a copied icon-theme.cache would be stale.
mirror() {
  rsync -a --copy-unsafe-links \
        --exclude='index.theme' --exclude='icon-theme.cache' "$1/" "$2/"
}
if [ "$DRYRUN" -eq 0 ]; then
  # The light theme used to be plain "MacOS-Like": carry an existing build over
  # so its generated icons are kept instead of rebuilt next to a stale copy.
  OLD_LIGHT="$DATA_HOME/icons/MacOS-Like"
  if [ -d "$OLD_LIGHT" ] && [ ! -e "$THEME_LIGHT" ] \
     && grep -qx 'Name=MacOS-Like' "$OLD_LIGHT/index.theme" 2>/dev/null; then
    mv "$OLD_LIGHT" "$THEME_LIGHT"
    rm -f "$THEME_LIGHT/icon-theme.cache"
    echo "Renamed $OLD_LIGHT -> $THEME_LIGHT"
  fi
  echo "Mirroring MacTahoe into both themes..."
  # rsync creates only the last path component; ~/.local/share/icons need not
  # exist yet when MacTahoe is installed system-wide.
  mkdir -p "$THEME_LIGHT" "$THEME_DARK"
  mirror "$MACTAHOE" "$THEME_LIGHT"
  mirror "$MACTAHOE" "$THEME_DARK"
  # MacTahoe-dark only ships the contexts it actually restyles; the rest of the
  # dark theme is the MacTahoe copy laid down above.
  if [ -d "$MACTAHOE_DARK" ]; then mirror "$MACTAHOE_DARK" "$THEME_DARK"; fi
  write_index "$THEME_LIGHT" "MacOS-Like-Light" "$INHERITS_LIGHT"
  write_index "$THEME_DARK" "MacOS-Like-Dark" "$INHERITS_DARK"
fi

# --- 1. Collect Icon= names from every .desktop file --------------------------
mapfile -t ICONS < <(
  for d in "${DATA_DIRS[@]}"; do
    d="$d/applications"
    [ -d "$d" ] || continue
    grep -rhs --include='*.desktop' '^Icon=' "$d" | cut -d= -f2-
  done | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u
)
echo "Found ${#ICONS[@]} unique icon names in .desktop files."

# --- 2. Filter: keep only names MacTahoe does not ship ------------------------
covered() {
  local n="$1"
  for ctx in apps/scalable apps/symbolic apps/16 apps/22 apps/32; do
    [ -e "$MACTAHOE/$ctx/$n.svg" ] || [ -e "$MACTAHOE/$ctx/$n.png" ] && return 0
  done
  return 1
}

overridden() {
  local n="$1" o
  for o in "${OVERRIDES[@]}"; do [ "${o%%=*}" = "$n" ] && return 0; done
  return 1
}

# --- 3. Resolve best source artwork for a name --------------------------------
HICOLOR_ROOTS=()
for b in "${ICON_BASES[@]}"; do
  [ -d "$b/hicolor" ] && HICOLOR_ROOTS+=("$b/hicolor")
done

resolve_src() {
  local n="$1" d s
  # absolute path in Icon=
  if [[ "$n" == /* ]]; then [ -f "$n" ] && { echo "$n"; return 0; }; return 1; fi
  for d in "${HICOLOR_ROOTS[@]}"; do
    [ -f "$d/scalable/apps/$n.svg" ] && { echo "$d/scalable/apps/$n.svg"; return 0; }
  done
  for s in 1024 512 256 192 128 96 64 48 32; do
    for d in "${HICOLOR_ROOTS[@]}"; do
      [ -f "$d/${s}x${s}/apps/$n.png" ] && { echo "$d/${s}x${s}/apps/$n.png"; return 0; }
    done
  done
  for s in svg png xpm; do
    for d in "${DATA_DIRS[@]}"; do
      [ -f "$d/pixmaps/$n.$s" ] && { echo "$d/pixmaps/$n.$s"; return 0; }
    done
  done
  return 1
}

# --- 4. Build work list -------------------------------------------------------
if [ "$DRYRUN" -eq 0 ]; then
  for t in "$THEME_LIGHT" "$THEME_DARK"; do
    for s in "${SIZES[@]}"; do mkdir -p "$t/apps/$s"; done
  done
fi

WORK=()   # entries: "name<TAB>srcpath"
for n in "${ICONS[@]}"; do
  base="$n"
  [[ "$base" == /* ]] && base="$(basename "$base")" && base="${base%.*}"
  overridden "$base" && continue
  covered "$base" && continue
  if [ "$FORCE" -eq 0 ] \
     && [ -f "$THEME_LIGHT/apps/512/$base.png" ] \
     && [ -f "$THEME_DARK/apps/512/$base.png" ]; then continue; fi
  if src=$(resolve_src "$n"); then
    WORK+=("$base"$'\t'"$src")
  else
    echo "  skip (no source art): $n"
  fi
done
# Overrides are wrapped like everything else, and unconditionally: they bypass
# covered()/FORCE so a rerun always re-derives them from the pinned source. The
# mirrored MacTahoe files must go first, or its apps/16|22|32 SVGs (Type=Fixed)
# and apps/scalable copy would outrank the PNGs generated below.
for o in "${OVERRIDES[@]}"; do
  name="${o%%=*}"; src="${o#*=}"
  [ -f "$src" ] || { echo "  override source missing: $src" >&2; continue; }
  if [ "$DRYRUN" -eq 0 ]; then
    for t in "$THEME_LIGHT" "$THEME_DARK"; do
      for d in "$t"/apps/*/; do rm -f "$d$name.svg" "$d$name.png"; done
    done
  fi
  WORK+=("$name"$'\t'"$src")
done

echo "To generate: ${#WORK[@]} icons (x2 variants)."
[ "$DRYRUN" -eq 1 ] && { printf '%s\n' "${WORK[@]}"; exit 0; }

# --- 5. Composite with Pillow -------------------------------------------------
if [ "${#WORK[@]}" -gt 0 ]; then
  WORKLIST=$(mktemp)
  trap 'rm -f "$WORKLIST"' EXIT
  printf '%s\n' "${WORK[@]}" > "$WORKLIST"
  python3 - "$THEME_LIGHT" "$THEME_DARK" "$WORKLIST" \
           "$DARK_TILE_TOP" "$DARK_TILE_BOT" "$DARK_TILE_HL" "$DARK_TILE_HL_SPAN" \
           "$DARK_TILE_RIM" <<'PYEOF'
import sys, os, math, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageChops

light_dir, dark_dir, worklist = sys.argv[1], sys.argv[2], sys.argv[3]

def hex2rgb(h):
    h = h.lstrip('#')
    if len(h) == 3:
        h = ''.join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def luma(c):
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255

DARK_TOP, DARK_BOT = hex2rgb(sys.argv[4]), hex2rgb(sys.argv[5])
DARK_HL, DARK_HL_SPAN = float(sys.argv[6]), float(sys.argv[7])
DARK_RIM = float(sys.argv[8])
DARK_MID_L = (luma(DARK_TOP) + luma(DARK_BOT)) / 2   # where white must land
DARK_LIFT = 1.02                                     # where black must lift to

SIZES = [16, 22, 24, 32, 48, 64, 96, 128, 256, 512]
C = 512                               # canvas
MARGIN, TILE, RADIUS = 32, 448, 104   # = 4, 56, 13 on MacTahoe's 64px grid
GLYPH_BOX = 328                       # glyph fits a centered box ~73% of the tile

def is_svg(path):
    if path.endswith('.svg'):
        return True
    with open(path, 'rb') as f:
        head = f.read(512).lstrip()
    return head.startswith(b'<') and b'svg' in head[:512].lower()

def load_512(path):
    if is_svg(path):
        with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as t:
            tmp = t.name
        try:
            subprocess.run(['rsvg-convert', '-w', str(C), '-h', str(C),
                            '--keep-aspect-ratio', '-o', tmp, path],
                           check=True, capture_output=True)
            img = Image.open(tmp).convert('RGBA')
        finally:
            os.unlink(tmp)
    else:
        img = Image.open(path).convert('RGBA')
    return img

# --- shared squircle layers ---------------------------------------------------
MASK = Image.new('L', (C, C), 0)
ImageDraw.Draw(MASK).rounded_rectangle(
    [MARGIN, MARGIN, MARGIN + TILE - 1, MARGIN + TILE - 1], radius=RADIUS, fill=255)

SHADOW = Image.new('RGBA', (C, C), (0, 0, 0, 0))
SHADOW.paste((0, 0, 0, 70), (0, 8), MASK.filter(ImageFilter.GaussianBlur(10)))

def border(rgba):
    b = Image.new('RGBA', (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(b).rounded_rectangle(
        [MARGIN, MARGIN, MARGIN + TILE - 1, MARGIN + TILE - 1],
        radius=RADIUS, outline=rgba, width=2)
    return b

BORDER_DARKLINE = border((0, 0, 0, 22))     # over light fills / full-bleed art

# Tahoe's corner rim: a 1px band just inside the squircle edge, painted with two
# white->transparent ramps -- one anchored at the top-left corner, one at the
# bottom-right -- softened and dropped to DARK_RIM. Geometry lifted from the rim
# MacTahoe bakes into Finder and Obsidian.
RIM_TL = ((9.82, 10.719), (40.0, 42.755))   # in 64-grid units
RIM_BR = ((57.0, 56.0), (48.0, 46.0))
RIM_BAND, RIM_BLUR = 1.0, 0.28

def _ramp(p0, p1):
    """255 at p0 falling linearly to 0 at p1 and clamped beyond both ends --
    the raster equivalent of an SVG linearGradient with #fff -> transparent."""
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    n = dx * dx + dy * dy
    g = Image.new('L', (C, C), 0)
    px = g.load()
    for y in range(C):
        for x in range(C):
            t = ((x - x0) * dx + (y - y0) * dy) / n
            px[x, y] = 0 if t >= 1 else (255 if t <= 0 else round(255 * (1 - t)))
    return g

def rim_layer(opacity):
    k = C / 64.0
    w = RIM_BAND * k
    inner = Image.new('L', (C, C), 0)
    ImageDraw.Draw(inner).rounded_rectangle(
        [MARGIN + w, MARGIN + w, MARGIN + TILE - 1 - w, MARGIN + TILE - 1 - w],
        radius=RADIUS - w, fill=255)
    ring = ImageChops.subtract(MASK, inner)
    a = Image.new('L', (C, C), 0)
    for p0, p1 in (RIM_TL, RIM_BR):
        g = ImageChops.multiply(ring, _ramp(tuple(v * k for v in p0),
                                            tuple(v * k for v in p1)))
        a = ImageChops.add(a, ImageChops.multiply(g, ImageChops.invert(a)))
    a = a.filter(ImageFilter.GaussianBlur(RIM_BLUR * k))
    out = Image.new('RGBA', (C, C), (255, 255, 255, 0))
    out.putalpha(a.point(lambda v: round(v * opacity)))
    return out

RIM_GLOW = rim_layer(DARK_RIM)              # the dark tile's only edge treatment

def tile_base(top, bot, bord, hl=0.0, hl_span=1.0):
    grad = Image.new('RGBA', (C, C))
    px = grad.load()
    for y in range(MARGIN, MARGIN + TILE):
        t = (y - MARGIN) / TILE
        col = [round(a + (b - a) * t) for a, b in zip(top, bot)]
        if hl > 0.0:
            # glass sheen: strongest at the top edge, gone by hl_span down
            a = hl * max(0.0, 1.0 - t / hl_span)
            col = [round(c + (255 - c) * a) for c in col]
        col = tuple(col) + (255,)
        for x in range(MARGIN, MARGIN + TILE):
            px[x, y] = col
    grad.putalpha(MASK)
    return Image.alpha_composite(Image.alpha_composite(SHADOW, grad), bord)

BASE = {
    'light': tile_base((253, 253, 253), (233, 233, 233), BORDER_DARKLINE),
    'dark':  tile_base(DARK_TOP, DARK_BOT, RIM_GLOW, DARK_HL, DARK_HL_SPAN),
}

# --- source-art classification ------------------------------------------------
def shape_stats(glyph):
    """coverage of the alpha bbox, of the inscribed disc, and of its outer ring."""
    w, h = glyph.size
    a = glyph.getchannel('A')
    px = a.load()
    cov = sum(a.histogram()[9:]) / (w * h)
    cx, cy = w / 2, h / 2
    r_in, r_out = (min(w, h) * 0.40) ** 2, (min(w, h) * 0.46) ** 2
    disc = disc_op = ring = ring_op = 0
    for y in range(h):
        for x in range(w):
            d2 = (x - cx) ** 2 + (y - cy) ** 2
            if d2 <= r_out:
                disc += 1
                op = px[x, y] > 8
                disc_op += op
                if d2 >= r_in:
                    ring += 1
                    ring_op += op
    return cov, disc_op / max(disc, 1), ring_op / max(ring, 1)

def cover_resize(glyph, box):
    """scale to fill a box x box square, preserving aspect, center-cropped."""
    w, h = glyph.size
    s = max(box / w, box / h)
    g = glyph.resize((max(box, round(w * s)), max(box, round(h * s))), Image.LANCZOS)
    ox, oy = (g.width - box) // 2, (g.height - box) // 2
    return g.crop((ox, oy, ox + box, oy + box))

MASK_TILE = MASK.crop((MARGIN, MARGIN, MARGIN + TILE, MARGIN + TILE))

def overscan(glyph, k):
    """cover_resize onto a k-times-oversized square, center-cropped back to TILE."""
    box = round(TILE * k)
    g = cover_resize(glyph, box)
    o = (box - TILE) // 2
    return g.crop((o, o, o + TILE, o + TILE))

def uncovered(layer):
    """fraction of the squircle the artwork leaves transparent."""
    a = layer.getchannel('A').point(lambda v: 255 if v > 200 else 0)
    miss = ImageChops.subtract(MASK_TILE, a)
    return sum(i * n for i, n in enumerate(miss.histogram())) / (255.0 * TILE * TILE)

def fit_to_squircle(glyph):
    """Art that is already a rounded tile (Breeze-style app icons) has its own
    corner radius, usually a little rounder than macOS's. Scaling it up until its
    silhouette covers the squircle keeps the design intact; a synthetic backdrop
    would smear the rim outwards instead. Returns None when no sane amount of
    overscan closes the corners — a disc badge needs bleed_backdrop, not this."""
    if uncovered(overscan(glyph, 1.0)) <= 0.002:
        return overscan(glyph, 1.0)
    lo, hi = 1.0, 1.30
    if uncovered(overscan(glyph, hi)) > 0.002:
        return None
    for _ in range(6):
        mid = (lo + hi) / 2
        if uncovered(overscan(glyph, mid)) <= 0.002:
            hi = mid
        else:
            lo = mid
    return overscan(glyph, hi)

NA = 720   # angular buckets used by the radial edge extension

def bleed_backdrop(glyph):
    """Extend the badge's own background out to the squircle edge.

    Polar edge-clamp: every pixel beyond the badge outline is filled with the
    colour the badge has at its outline along the same angle. Unlike a blur
    this keeps rim colours clean instead of smearing the artwork outwards.
    """
    src = cover_resize(glyph, TILE)
    px = src.load()
    c = TILE / 2

    edge = [0.0] * NA
    for y in range(TILE):
        dy = y - c + 0.5
        for x in range(TILE):
            if px[x, y][3] > 200:
                dx = x - c + 0.5
                d = math.hypot(dx, dy)
                a = int((math.atan2(dy, dx) + math.pi) / (2 * math.pi) * NA) % NA
                if d > edge[a]:
                    edge[a] = d
    # circular moving average so the sampling radius varies smoothly
    k = 12
    sm = [sum(edge[(a + i) % NA] for i in range(-k, k + 1)) / (2 * k + 1)
          for a in range(NA)]

    back = Image.new('RGBA', (TILE, TILE), (0, 0, 0, 0))
    bp = back.load()
    for y in range(TILE):
        dy = y - c + 0.5
        for x in range(TILE):
            dx = x - c + 0.5
            d = math.hypot(dx, dy)
            th = math.atan2(dy, dx)
            a = int((th + math.pi) / (2 * math.pi) * NA) % NA
            r = min(d, max(sm[a] - 4.0, 1.0))
            sx = min(TILE - 1, max(0, int(c + math.cos(th) * r)))
            sy = min(TILE - 1, max(0, int(c + math.sin(th) * r)))
            p = px[sx, sy]
            bp[x, y] = (p[0], p[1], p[2], 255)
    return back.filter(ImageFilter.GaussianBlur(3))

# --- neutral (white-tile) artwork -> graphite for the dark theme --------------
_INNER = Image.new('L', (C, C), 0)
ImageDraw.Draw(_INNER).rounded_rectangle(
    [MARGIN + 16, MARGIN + 16, MARGIN + TILE - 17, MARGIN + TILE - 17],
    radius=RADIUS - 16, fill=255)
RIM_BAND_MASK = ImageChops.subtract(MASK, _INNER)  # 16px band inside the squircle

def rim_is_light_neutral(layer):
    """True when the artwork's own backdrop is a white/near-white tile rather
    than a brand colour — i.e. it should be re-tinted, not shipped as-is."""
    px, rp = layer.load(), RIM_BAND_MASK.load()
    n = sl = ss = 0
    for y in range(MARGIN, MARGIN + TILE, 3):
        for x in range(MARGIN, MARGIN + TILE, 3):
            if rp[x, y] < 200:
                continue
            r, g, b, a = px[x, y]
            if a < 200:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            n += 1
            sl += (0.299 * r + 0.587 * g + 0.114 * b) / 255
            ss += (mx - mn) / mx if mx else 0.0
    return n >= 100 and sl / n > 0.82 and ss / n < 0.12

def darkify(layer):
    """Invert the luminance of near-neutral pixels inside the squircle: a white
    backdrop lands on the graphite tile tone, saturated brand colours are left
    alone, and dark neutral detail brightens so it stays readable."""
    out = layer.copy()
    px, mp = out.load(), MASK.load()
    for y in range(MARGIN, MARGIN + TILE):
        for x in range(MARGIN, MARGIN + TILE):
            if mp[x, y] == 0:
                continue
            r, g, b, a = px[x, y]
            if a < 250:
                continue      # the artwork's own soft shadow: leave it dark
            mx, mn = max(r, g, b), min(r, g, b)
            w = 1.0 - min(((mx - mn) / mx if mx else 0.0) / 0.18, 1.0)
            if w <= 0.0:
                continue
            L = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            # inversion aimed so white lands exactly on the tile's mid tone
            d = (DARK_LIFT - (DARK_LIFT - DARK_MID_L) * L) - L
            px[x, y] = tuple(
                round(c + (min(255, max(0, c + d * 255)) - c) * w)
                for c in (r, g, b)) + (a,)
    return out

def prepare(glyph):
    """classify once; return (light_icon, dark_icon, glyph). The two icons are
    the same object unless the artwork supplies its own light backdrop."""
    bbox = glyph.getbbox()
    if bbox:
        glyph = glyph.crop(bbox)
    w, h = glyph.size
    cov, disc, ring = shape_stats(glyph)
    square = 0.93 <= w / h <= 1.07
    # 1. full-bleed square art (Steam covers, pre-rounded tiles) and
    # 2. solid disc/blob badges (circular logos with their own background):
    #    the artwork becomes the squircle instead of sitting on a tile.
    if square and (cov >= 0.90 or (disc >= 0.98 and ring >= 0.98)):
        layer = Image.new('RGBA', (C, C), (0, 0, 0, 0))
        fitted = fit_to_squircle(glyph) if cov < 0.995 else None
        if fitted is not None:
            layer.paste(fitted, (MARGIN, MARGIN))
        else:
            if cov < 0.995:
                layer.paste(bleed_backdrop(glyph), (MARGIN, MARGIN))
            layer.alpha_composite(cover_resize(glyph, TILE), (MARGIN, MARGIN))
        layer.putalpha(ImageChops.multiply(layer.getchannel('A'), MASK))
        base = Image.alpha_composite(SHADOW, layer)
        light = Image.alpha_composite(base, BORDER_DARKLINE)
        if rim_is_light_neutral(layer):
            # its own backdrop was a white tile: re-tone it, then rim it
            dark = Image.alpha_composite(
                Image.alpha_composite(SHADOW, darkify(layer)), RIM_GLOW)
        else:
            # brand artwork: same pixels as the light icon, but rimmed
            dark = Image.alpha_composite(base, RIM_GLOW)
        return light, dark, None
    # 3. shaped / transparent logo: it gets centred on a per-variant tile.
    scale = min(GLYPH_BOX / w, GLYPH_BOX / h)
    gw, gh = max(1, round(w * scale)), max(1, round(h * scale))
    return None, None, glyph.resize((gw, gh), Image.LANCZOS)

def compose(prepared, variant):
    light, dark, g = prepared
    if g is None:
        return light if variant == 'light' else dark
    icon = BASE[variant].copy()
    icon.alpha_composite(g, ((C - g.width) // 2, (C - g.height) // 2))
    return icon

done = fail = 0
for line in open(worklist):
    line = line.rstrip('\n')
    if not line:
        continue
    name, src = line.split('\t', 1)
    try:
        prepared = prepare(load_512(src))
        for variant, out_dir in (('light', light_dir), ('dark', dark_dir)):
            icon = compose(prepared, variant)
            for s in SIZES:
                out = icon if s == C else icon.resize((s, s), Image.LANCZOS)
                out.save(os.path.join(out_dir, 'apps', str(s), name + '.png'))
        done += 1
    except Exception as e:
        fail += 1
        print(f'  FAIL {name}: {e}', file=sys.stderr)
print(f'Generated {done} icons x2 variants ({fail} failed).')
PYEOF
fi

# --- 5b. Dark-tile copies of MacTahoe's own app SVGs --------------------------
# MacTahoe-dark/apps/scalable is a symlink to MacTahoe/apps/scalable: upstream
# ships no dark app icons at all, and the light tile is baked into each SVG as a
# near-white linearGradient (or a mid grey one for apps with a white logo).
# Re-tint just that gradient into the near-black glass tile, add the top sheen,
# and drop the results into the dark theme, where they shadow MacTahoe's.
python3 - "$MACTAHOE/apps/scalable" "$THEME_DARK/apps/scalable" \
         "$DARK_TILE_TOP" "$DARK_TILE_BOT" "$DARK_TILE_HL" "$DARK_TILE_HL_SPAN" <<'PYEOF'
import os, re, subprocess, sys, tempfile
from PIL import Image

src_dir, dst_dir = sys.argv[1], sys.argv[2]
os.makedirs(dst_dir, exist_ok=True)

GRAD = re.compile(r'<linearGradient\b[^>]*>(?:\s*<stop\b[^>]*/>\s*)+</linearGradient>')
GRAD_OPEN = re.compile(r'<linearGradient\b([^>]*)>')
STOP = re.compile(r'(stop-color=")(#[0-9a-fA-F]{3,6})(")')
ID = re.compile(r'\bid="([^"]+)"')
YS = re.compile(r'\b(y1|y2)="([-\d.eE]+)"')
# MacTahoe bakes the tile into each SVG as one of three neutral gradients: a
# near-white one for most apps, and two dark greys for apps whose logo is
# light (Zen and ~140 others use one; kitty and ~190 more use the darker
# one). All three are re-tinted to the same dark glass tile.
SIG_LIGHT = ('#f1efeb', '#fdfcfc')
SIG_DARK = ('#363636', '#6c6c6c', '#292929', '#4d4d4d')
HL_ID = 'tahoeGlass'

def rgb(h):
    h = h.lstrip('#')
    if len(h) == 3:
        h = ''.join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def luma(c):
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255

HI, LO = rgb(sys.argv[3]), rgb(sys.argv[4])   # tile top, tile bottom
HL, HL_SPAN = float(sys.argv[5]), float(sys.argv[6])

def retint(m, seen):
    block = m.group(0)
    hexes = [c for _, c, _ in STOP.findall(block)]
    if not hexes:
        return block
    lit = any(c.lower() in SIG_LIGHT for c in hexes)
    drk = any(c.lower() in SIG_DARK for c in hexes)
    if not (lit or drk):
        return block
    cols = [rgb(c) for c in hexes]
    # only touch gradients that are entirely neutral: those are tiles, never
    # artwork. The light tile must also be light and the grey tile mid-dark,
    # so a brand gradient that merely grazes a signature colour is left alone.
    if any(max(c) - min(c) > 14 for c in cols):
        return block
    if lit and any(luma(c) < 0.88 for c in cols):
        return block
    if drk and any(luma(c) > 0.55 for c in cols):
        return block
    ls = [luma(c) for c in cols]
    lo, hi = min(ls), max(ls)
    seq = iter(ls)

    def one(sm):
        t = 0.5 if hi - lo < 1e-6 else (next(seq) - lo) / (hi - lo)
        col = tuple(round(a + (b - a) * t) for a, b in zip(LO, HI))
        return sm.group(1) + '#%02x%02x%02x' % col + sm.group(3)

    out = STOP.sub(one, block)
    gid = ID.search(GRAD_OPEN.match(block).group(1))
    if gid and seen[0] is None:
        seen[0] = (gid.group(1), block)
    return out

def sheen(block):
    """A white top-edge sheen that reuses the tile gradient's own geometry, so
    it lines up whatever viewport or transform the SVG happens to use. Which
    end of the ramp is 'up' is read off y1/y2 rather than assumed."""
    attrs = GRAD_OPEN.match(block).group(1)
    ys = dict(YS.findall(attrs))
    if 'y1' not in ys or 'y2' not in ys or float(ys['y1']) == float(ys['y2']):
        return None                       # horizontal ramp: no meaningful top
    attrs = ID.sub('id="%s"' % HL_ID, attrs, count=1)
    if float(ys['y2']) < float(ys['y1']):          # offset 1 is the top edge
        stops = ('<stop offset="%.4g" stop-color="#fff" stop-opacity="0"/>'
                 '<stop offset="1" stop-color="#fff" stop-opacity="%.4g"/>'
                 % (1.0 - HL_SPAN, HL))
    else:                                          # offset 0 is the top edge
        stops = ('<stop offset="0" stop-color="#fff" stop-opacity="%.4g"/>'
                 '<stop offset="%.4g" stop-color="#fff" stop-opacity="0"/>'
                 % (HL, HL_SPAN))
    return '<linearGradient%s>%s</linearGradient>' % (attrs, stops)

def add_sheen(out, gid, block):
    """Duplicate the tile element with the sheen gradient as its fill, right
    after the original so it sits under the artwork."""
    if HL_ID in out or '</defs>' not in out:
        return out, False
    grad = sheen(block)
    if grad is None:
        return out, False
    el = re.search(r'<(?:rect|path|circle|ellipse)\b[^>]*url\(#%s\)[^>]*/>'
                   % re.escape(gid), out)
    if not el:
        return out, False
    dup = el.group(0).replace('url(#%s)' % gid, 'url(#%s)' % HL_ID)
    # the element sits after </defs>, so splice it in first and the gradient
    # second -- the indices stay valid.
    out = out[:el.end()] + dup + out[el.end():]
    return out.replace('</defs>', grad + '</defs>', 1), True

# A few white tiles (Firefox, Inkscape, Edge, ...) have their edge lit by an
# all-white ramp that is opaque at both ends and dim in the middle, drawn by one
# or two paths through gradients that href it. Meant for the white tile, it
# turns into a hard white outline on the dark one, so it goes; 5d gives these
# icons the same corner rim as every other dark tile.
TAG = re.compile(r'<(?:linear|radial)Gradient\b[^>]*>')
STOP_COL = re.compile(r'stop-color[=:]\s*"?(#[0-9a-fA-F]{3,6})')
STOP_OP = re.compile(r'stop-opacity[=:]\s*"?([-\d.eE]+)')
HREF_ATTR = re.compile(r'\bxlink:href="#([^"]+)"')

def edge_ramps(s):
    ids = set()
    for m in GRAD.finditer(s):
        stops = re.findall(r'<stop\b[^>]*/>', m.group(0))
        cols = [STOP_COL.search(t) for t in stops]
        if len(stops) < 3 or not all(c and c.group(1).lower() in ('#fff', '#ffffff')
                                     for c in cols):
            continue
        ops = [float(o.group(1)) if o else 1.0 for o in map(STOP_OP.search, stops)]
        gid = ID.search(GRAD_OPEN.match(m.group(0)).group(1))
        if gid and ops[0] >= 0.9 and ops[-1] >= 0.9 and min(ops) < 0.6:
            ids.add(gid.group(1))
    return ids

def drop_edge_ring(out):
    ramps = edge_ramps(out)
    if not ramps:
        return out, False
    users = set(ramps)
    for t in TAG.finditer(out):
        h, i = HREF_ATTR.search(t.group(0)), ID.search(t.group(0))
        if h and i and h.group(1) in ramps:
            users.add(i.group(1))
    el = re.compile(r'<(?:path|rect|circle|ellipse)\b[^>]*url\(#(?:%s)\)[^>]*/>'
                    % '|'.join(map(re.escape, users)))
    new = el.sub('', out)
    return new, new != out

def raster(path, size=64):
    with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as t:
        tmp = t.name
    try:
        subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size),
                        '-o', tmp, path], check=True, capture_output=True)
        return Image.open(tmp).convert('RGBA').copy()
    finally:
        os.unlink(tmp)

def legible(light_path, dark_path):
    """The artwork is exactly the pixels the gradient swap did NOT change, so
    diffing the two renders isolates the logo. A logo that is itself dark
    neutral (black wordmarks, line art) would vanish on the graphite tile —
    those icons keep MacTahoe's light tile instead."""
    a, b = raster(light_path).load(), raster(dark_path).load()
    n = lum = 0
    for y in range(7, 57):                    # inside the 4/56/13 tile only
        for x in range(7, 57):
            p, q = a[x, y], b[x, y]
            if p[3] < 250:
                continue
            if max(abs(p[i] - q[i]) for i in range(3)) > 6:
                continue                      # tile: recoloured, not artwork
            n += 1
            lum += (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255
    return n < 80 or lum / n >= 0.34

retinted, linked, kept_light, sheened, unringed = set(), 0, 0, 0, 0
for name in sorted(os.listdir(src_dir)):
    p = os.path.join(src_dir, name)
    if os.path.islink(p) or not name.endswith('.svg'):
        continue
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        s = f.read()
    seen = [None]                     # (id, original markup) of the tile ramp
    out = GRAD.sub(lambda m: retint(m, seen), s)  # noqa: B023 -- called before seen rebinds
    if out == s:
        continue
    hl = False
    if seen[0] is not None:
        out, hl = add_sheen(out, seen[0][0], seen[0][1])
    out, ring = drop_edge_ring(out)
    dst = os.path.join(dst_dir, name)
    tmp = dst + '.retint'
    with open(tmp, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(out)
    if legible(p, tmp):
        os.replace(tmp, dst)
        retinted.add(name)
        sheened += hl
        unringed += ring
    else:
        # illegible on the dark tile: leave the mirrored light SVG in place
        os.unlink(tmp)
        kept_light += 1

links = {n: os.readlink(os.path.join(src_dir, n))
         for n in sorted(os.listdir(src_dir))
         if os.path.islink(os.path.join(src_dir, n))}
have = set(retinted)
while True:                      # repeat: alias chains resolve one hop per pass
    added = 0
    for name, tgt in links.items():
        if name in have or '/' in tgt or tgt not in have:
            continue
        dst = os.path.join(dst_dir, name)
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(tgt, dst)
        have.add(name)
        added += 1
        linked += 1
    if not added:
        break

print(f'Re-tinted {len(retinted)} MacTahoe app SVGs for the dark theme '
      f'({sheened} with a glass sheen, {unringed} lost a white edge ring, '
      f'+{linked} aliases); '
      f'{kept_light} kept light for legibility.')
PYEOF

# --- 5c. Tahoe dark Finder ----------------------------------------------------
# 5b only re-tints near-white tiles; Finder's tile is a saturated blue gradient,
# so it passes through as the light-mode artwork. In Tahoe's dark appearance the
# icon inverts instead: the tile goes graphite and the blue moves onto the face.
# Recolour only the gradients -- geometry, filters and paths are untouched.
# The match strings are exact on purpose. A MacTahoe release that changes this
# markup fails loudly, but the patch is all-or-nothing and the rest of the build
# goes on: the dark Finder just stays MacTahoe's own until the strings are fixed.
if ! python3 - "$THEME_DARK/apps/scalable/file-manager.svg" <<'PYEOF'
import os, sys

path = sys.argv[1]
if not os.path.isfile(path):
    sys.exit('file-manager.svg: not found at %s (upstream MacTahoe changed?)' % path)
s = open(path, encoding='utf-8').read()

def swap(old, new, what, count=1):
    global s
    if new in s:
        return                       # already applied
    if s.count(old) < count:
        sys.exit('file-manager.svg: cannot find %s (upstream MacTahoe changed?)' % what)
    s = s.replace(old, new, count)

G = '<linearGradient id="%s" x1="%s" x2="%s" y1="%s" y2="%s" gradientUnits="userSpaceOnUse">'

# tile: bright blue -> graphite
swap('<stop offset="0" stop-color="#02c5fd"/><stop offset="1" stop-color="#2f71f9"/>',
     '<stop offset="0" stop-color="#3c3c3f"/><stop offset="1" stop-color="#141416"/>',
     'tile gradient #b')

# face: white -> the blue that left the tile
c = G % ('c', '10.789', '10.789', '2.117', '14.816')
swap(c + '<stop offset="0" stop-color="#fff"/>'
         '<stop offset=".549" stop-color="#fff" stop-opacity=".796"/>'
         '<stop offset="1" stop-color="#fff" stop-opacity=".5"/></linearGradient>',
     c + '<stop offset="0" stop-color="#5cc8fa"/>'
         '<stop offset=".549" stop-color="#25a3ee" stop-opacity=".96"/>'
         '<stop offset="1" stop-color="#1274cf" stop-opacity=".92"/></linearGradient>',
     'face gradient #c')

# smile stroke: runs x 3.969 -> 12.964; it crosses onto the face at ~47%, so it
# glows blue over the graphite and drops to navy over the blue face.
h = G % ('h', '3.969', '12.964', '13.229', '13.229')
swap(h + '<stop offset="0"/><stop offset="1" stop-color="#0b2242"/></linearGradient>',
     h + '<stop offset="0" stop-color="#4bb4f2"/><stop offset=".34" stop-color="#2f8fd0"/>'
         '<stop offset=".47" stop-color="#0d2c50"/><stop offset="1" stop-color="#0b2242"/>'
         '</linearGradient>',
     'smile gradient #h')

# smile highlight: reversed (offset 0 is the face side) -- keep it on the tile only
j = G % ('j', '12.964', '3.969', '11.641', '11.641')
swap(j + '<stop offset="0" stop-color="#fff"/>'
         '<stop offset="1" stop-color="#fff" stop-opacity=".65"/></linearGradient>',
     j + '<stop offset="0" stop-color="#fff" stop-opacity="0"/>'
         '<stop offset=".52" stop-color="#fff" stop-opacity="0"/>'
         '<stop offset="1" stop-color="#bfe4ff" stop-opacity=".85"/></linearGradient>',
     'smile highlight #j')

# eyes: identical markup, the second wrapped in translate(-6.35). Document order
# is face-side first, tile-side second -- so one darkens, one lightens.
eye = '<rect width=".529" height="1.455" x="11.377" y="5.424" rx=".265" ry=".277"/>'
tinted = eye.replace(' rx=', ' fill="%s" rx=')
swap(eye, tinted % '#0b2a4d', 'face-side eye')
swap(eye, tinted % '#2f9fe0', 'tile-side eye')

# corner glass: MacTahoe blends it with overlay, which brightens the blue tile
# but all but vanishes on graphite. Only librsvg (GTK) honours the blend; QtSvg
# (KDE) draws it normally, and that is the look wanted -- so say normal outright
# and both renderers show the same glass.
swap('<g filter="url(#d)" opacity=".45" style="mix-blend-mode:overlay">',
     '<g filter="url(#d)" opacity=".45" style="mix-blend-mode:normal">',
     'corner glass group')
swap('opacity="1" style="mix-blend-mode:overlay"/>',
     'opacity="1" style="mix-blend-mode:normal"/>',
     'corner glass paths', count=2)

open(path, 'w', encoding='utf-8').write(s)
print('Dark Finder applied to', path)
PYEOF
then
  echo "  warning: dark Finder skipped (see above); the build continues" >&2
fi

# --- 5d. Tahoe corner rim on every dark app SVG -------------------------------
# A 1px band just inside the squircle, lit from the top-left and bottom-right
# corners. MacTahoe bakes this into a handful of icons (Finder, Obsidian) and
# omits it everywhere else; this gives the whole dark theme the same edge.
# Runs last so it layers over 5b's re-tint and 5c's Finder, and only in the dark
# theme -- a white rim on the light theme's near-white tile is invisible.
python3 - "$THEME_DARK/apps/scalable" "$DARK_TILE_RIM" <<'PYEOF'
import os, re, subprocess, sys, tempfile
from PIL import Image

dst_dir, RIM = sys.argv[1], float(sys.argv[2])
if RIM <= 0:
    print('Corner rim disabled (DARK_TILE_RIM=0).')
    raise SystemExit

SVG = re.compile(r'<svg\b[^>]*>')
ATTR = lambda t, n: (re.search(r'\b%s="([^"]*)"' % n, t) or [None, None])[1]
# a white -> transparent ramp reused by two href'd gradients is the rim MacTahoe
# already ships; those icons are left alone rather than double-lit.
WT = re.compile(r'<linearGradient id="([^"]+)"[^>]*>\s*'
                r'<stop offset="0" stop-color="#fff"/>\s*'
                r'<stop offset="1" stop-color="#fff" stop-opacity="0"/>\s*'
                r'</linearGradient>')
HREF = re.compile(r'<linearGradient xlink:href="#([^"]+)"')

# The stops are written out twice rather than shared through an xlink:href:
# plenty of these icons never declare xmlns:xlink, and an undeclared prefix is
# a hard XML parse error -- the whole icon disappears, not just the rim.
STOPS = ('<stop offset="0" stop-color="#fff"/>'
         '<stop offset="1" stop-color="#fff" stop-opacity="0"/>')
RIM_MARKUP = (
 '<defs>'
 '<linearGradient id="tahoeRimTL" '
 'x1="9.82" x2="40" y1="10.719" y2="42.755" gradientUnits="userSpaceOnUse">'
 + STOPS + '</linearGradient>'
 '<linearGradient id="tahoeRimBR" '
 'x1="57" x2="48" y1="56" y2="46" gradientUnits="userSpaceOnUse">'
 + STOPS + '</linearGradient>'
 '<filter id="tahoeRimBlur" width="1.024" height="1.024" x="-.012" y="-.012" '
 'color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation=".28"/></filter>'
 '</defs>'
 '<g filter="url(#tahoeRimBlur)" opacity="%.4g" fill="none" stroke-width="1">'
 '<rect width="55" height="55" x="4.5" y="4.5" rx="12.5" ry="12.5" '
 'stroke="url(#tahoeRimTL)"/>'
 '<rect width="55" height="55" x="4.5" y="4.5" rx="12.5" ry="12.5" '
 'stroke="url(#tahoeRimBR)"/></g>') % RIM

def user_space(tag):
    """(kx, ky, ox, oy) mapping the 64-grid onto this file's user space. The
    squircle is always 4/56/13 of the viewport -- that is MacTahoe's invariant --
    but the units it is expressed in vary (16.933, 1024, 327.68, ...)."""
    vb = ATTR(tag, 'viewBox')
    if vb:
        p = [float(v) for v in vb.replace(',', ' ').split()]
        if len(p) != 4 or p[2] <= 0 or p[3] <= 0:
            return None
        return p[2] / 64.0, p[3] / 64.0, p[0], p[1]
    w, h = ATTR(tag, 'width'), ATTR(tag, 'height')
    try:
        w = float(re.sub(r'[a-z%]+$', '', w))
        h = float(re.sub(r'[a-z%]+$', '', h))
    except (TypeError, ValueError):
        return None
    return (w / 64.0, h / 64.0, 0.0, 0.0) if w > 0 and h > 0 else None

PROBE = ((32, 5), (32, 58), (5, 32), (58, 32),      # edge midpoints
         (10, 10), (53, 10), (10, 53), (53, 53))    # just inside the corners

def render(path):
    """RGBA pixel access for a 64px render, or None if the file will not parse.
    rsvg-convert refuses a non-regular output file, so this needs a real temp."""
    with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as t:
        tmp = t.name
    try:
        subprocess.run(['rsvg-convert', '-w', '64', '-h', '64', '-o', tmp, path],
                       check=True, capture_output=True)
        return Image.open(tmp).convert('RGBA').load()
    except Exception:
        return None
    finally:
        os.unlink(tmp)

def fills_tile(px):
    """Only icons that actually fill the squircle get a rim: anything smaller or
    a different shape would just gain a floating rounded rectangle."""
    return px is not None and all(px[x, y][3] >= 250 for x, y in PROBE)

rimmed = skipped_have = skipped_shape = reverted = 0
for name in sorted(os.listdir(dst_dir)):
    p = os.path.join(dst_dir, name)
    if os.path.islink(p) or not name.endswith('.svg'):
        continue                       # aliases inherit their target's rim
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        s = f.read()
    if 'tahoeRim' in s:
        continue                       # already run over this file
    ids = set(WT.findall(s))
    if ids:
        refs = HREF.findall(s)
        if any(refs.count(i) >= 2 for i in ids):
            skipped_have += 1          # MacTahoe already lights this one
            continue
    m = SVG.search(s)
    sp = user_space(m.group(0)) if m else None
    if sp is None or not s.rstrip().endswith('</svg>') or not fills_tile(render(p)):
        skipped_shape += 1
        continue
    kx, ky, ox, oy = sp
    rim = RIM_MARKUP
    if (kx, ky, ox, oy) != (1.0, 1.0, 0.0, 0.0):
        rim = ('<g transform="translate(%.6g %.6g) scale(%.6g %.6g)">%s</g>'
               % (ox, oy, kx, ky, rim))
    cut = s.rstrip().rfind('</svg>')
    with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(s[:cut] + rim + s[cut:])
    if render(p) is None:
        # the rim must never cost us the icon: put the original back
        with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.write(s)
        reverted += 1
        continue
    rimmed += 1

msg = (f'Corner rim added to {rimmed} dark app SVGs '
       f'({skipped_have} already had one, {skipped_shape} are not full tiles')
print(msg + (f', {reverted} REVERTED - rim broke the render).' if reverted
             else ').'))
PYEOF

# --- 6. Icon caches -----------------------------------------------------------
# GTK reads this cache; a stale one is worse than none, so rebuild it every run.
for t in "$THEME_LIGHT" "$THEME_DARK"; do
  gtk4-update-icon-cache -q -f "$t" 2>/dev/null \
    || gtk-update-icon-cache -q -f "$t" 2>/dev/null || true
done

echo "Themes written to $THEME_LIGHT and $THEME_DARK"

# --- 7. Re-apply the folder tint ----------------------------------------------
# Step 0 rsyncs MacTahoe back over both themes, which restores its blue folder
# artwork. Lay the last tint (matugen palette or --color) back down so a rebuild
# doesn't leave blue folders behind. The recolour reads from its own pristine
# baseline, so this is idempotent; with no tint ever set, --if-set does nothing.
# The copy matugen's post-hook runs is preferred, so both always agree.
RECOLOR_FOLDERS="$MATUGEN_HOOK"
[ -f "$RECOLOR_FOLDERS" ] || RECOLOR_FOLDERS="$REPO_DIR/matugen/recolor_folders.py"
if [ -f "$RECOLOR_FOLDERS" ]; then
  echo "Re-applying folder tint..."
  python3 "$RECOLOR_FOLDERS" --if-set || echo "  folder tint failed (non-fatal)" >&2
fi

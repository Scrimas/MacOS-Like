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
# the squircle. Defined once here and passed into the Pillow pass (step 5), the
# SVG re-tint (step 5b) and the tile repaint (step 5d) so the raster and vector
# icons agree.
DARK_TILE_TOP="#2c2c2f"     # top of the tile gradient
DARK_TILE_BOT="#1c1c1e"     # bottom
DARK_TILE_HL="0.10"         # white sheen opacity at the top edge, fading to 0
DARK_TILE_HL_SPAN="0.55"    # fraction of the tile height the sheen covers
DARK_TILE_RIM="0.35"        # corner rim glow: 1px inset stroke on the squircle,
                            # lit from the top-left and bottom-right corners.
                            # Matches the rim MacTahoe already bakes into a few
                            # icons (Finder, Obsidian); 0 disables it.

# Light-theme tile: MacTahoe's own warm white ramp, so generated tiles match the
# ~300 white tiles MacTahoe draws itself. Step 5d turns MacTahoe's neutral dark
# tiles (kitty, VS Code, terminals, ...) into this same ramp, and repaints its
# other whites and greys (flat white, cool grey, ...) with it; step 5 does the
# same for artwork that brings its own neutral tile (Proton Pass).
LIGHT_TILE_TOP="#fdfcfc"
LIGHT_TILE_BOT="#f1efeb"

# One drop shadow under every app tile, in both themes, and a hairline outline
# along the squircle edge in the light theme; pixels on the 512 canvas. Step 5
# draws them into the generated icons, and step 5d swaps MacTahoe's own shadows
# (which differ from icon to icon, and are missing from some) for the same one.
TILE_SHADOW_ALPHA="70"      # 0-255
TILE_SHADOW_BLUR="10"       # Gaussian radius
TILE_SHADOW_DROP="8"        # downward offset
TILE_OUTLINE_ALPHA="22"     # 2px black line just inside the edge; 0-255

# Apps whose icon should come from a specific file rather than from MacTahoe or
# from the usual source-art search. The file is run through the same tile wrap as
# every other app, so the result is a macOS-shaped icon carrying that artwork.
# One "icon-name=/path/to/source.svg-or-png" per line; blank lines and lines
# starting with # are skipped, and a leading ~/ is expanded.
OVERRIDES_FILE="$CONFIG_HOME/macos-like/overrides.conf"

# Icons that keep a dark tile in the light theme: one icon name per line (an
# alias such as "com.visualstudio.code" counts for the file it points to); #
# starts a comment.
KEEP_DARK_FILE="$CONFIG_HOME/macos-like/keep-dark.conf"

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
    grep -Rhs --include='*.desktop' '^Icon=' "$d" | cut -d= -f2-
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

# Icon= lookup is case-sensitive, so "vesktop" misses MacTahoe's Vesktop.svg and
# would be wrapped from the generic hicolor art. Map lowercased names to
# MacTahoe's spelling; such names get an alias to MacTahoe's own design instead.
declare -A MT_CASE=()
for ctx in apps/scalable apps/symbolic apps/16 apps/22 apps/32; do
  for f in "$MACTAHOE/$ctx"/*.svg "$MACTAHOE/$ctx"/*.png; do
    [ -e "$f" ] || continue
    f="${f##*/}"; f="${f%.*}"
    MT_CASE[${f,,}]="$f"
  done
done

case_alias() {   # prints MacTahoe's spelling when $1 differs from it only by case
  local alt="${MT_CASE[${1,,}]:-}"
  [ -n "$alt" ] && [ "$alt" != "$1" ] && { echo "$alt"; return 0; }
  return 1
}

# Point name at MacTahoe's differently-cased file in every apps dir of both
# themes, and drop any PNG an earlier build generated for it: apps/<size> is
# Type=Fixed and would outrank the alias.
link_case_alias() {
  local name="$1" alt="$2" t d e
  for t in "$THEME_LIGHT" "$THEME_DARK"; do
    for d in "$t"/apps/*/ "$t"/apps@2x/*/; do
      [ -d "$d" ] || continue
      rm -f "$d$name.png"
      for e in svg png; do
        if [ -e "$d$alt.$e" ]; then ln -sfn "$alt.$e" "$d$name.$e"; break; fi
      done
    done
  done
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
  if alt=$(case_alias "$base"); then
    echo "  alias: $base -> $alt"
    [ "$DRYRUN" -eq 0 ] && link_case_alias "$base" "$alt"
    continue
  fi
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
           "$DARK_TILE_RIM" "$LIGHT_TILE_TOP" "$LIGHT_TILE_BOT" \
           "$TILE_SHADOW_ALPHA" "$TILE_SHADOW_BLUR" "$TILE_SHADOW_DROP" \
           "$TILE_OUTLINE_ALPHA" "$KEEP_DARK_FILE" <<'PYEOF'
import sys, os, math, statistics, subprocess, tempfile
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
LIGHT_TOP, LIGHT_BOT = hex2rgb(sys.argv[9]), hex2rgb(sys.argv[10])
LIGHT_MID_L = (luma(LIGHT_TOP) + luma(LIGHT_BOT)) / 2
GLYPH_DARK_L = 0.11                     # where a white glyph lands on a lightened tile
SHADOW_A, SHADOW_BLUR, SHADOW_DROP = (int(v) for v in sys.argv[11:14])
OUTLINE_A = int(sys.argv[14])

def keep_dark(path):
    """icon names listed in keep-dark.conf (missing file: none)."""
    try:
        with open(path, encoding='utf-8') as f:
            return {ln.split('#', 1)[0].strip() for ln in f} - {''}
    except OSError:
        return set()

KEEP_DARK = keep_dark(sys.argv[15])

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
SHADOW.paste((0, 0, 0, SHADOW_A), (0, SHADOW_DROP),
             MASK.filter(ImageFilter.GaussianBlur(SHADOW_BLUR)))

def border(rgba):
    b = Image.new('RGBA', (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(b).rounded_rectangle(
        [MARGIN, MARGIN, MARGIN + TILE - 1, MARGIN + TILE - 1],
        radius=RADIUS, outline=rgba, width=2)
    return b

BORDER_DARKLINE = border((0, 0, 0, OUTLINE_A))   # every light-theme tile

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

def tile_rows(top, bot, hl=0.0, hl_span=1.0):
    """the tile's colour on every canvas row (clamped above and below it)."""
    rows = []
    for y in range(C):
        t = min(max((y - MARGIN) / TILE, 0.0), 1.0)
        col = [round(a + (b - a) * t) for a, b in zip(top, bot)]
        if hl > 0.0:
            # glass sheen: strongest at the top edge, gone by hl_span down
            a = hl * max(0.0, 1.0 - t / hl_span)
            col = [round(c + (255 - c) * a) for c in col]
        rows.append(tuple(col))
    return rows

TILE_ROW = {
    'light': tile_rows(LIGHT_TOP, LIGHT_BOT),
    'dark':  tile_rows(DARK_TOP, DARK_BOT, DARK_HL, DARK_HL_SPAN),
}

def tile_base(variant, bord):
    grad = Image.new('RGBA', (C, C))
    px = grad.load()
    for y in range(MARGIN, MARGIN + TILE):
        col = TILE_ROW[variant][y] + (255,)
        for x in range(MARGIN, MARGIN + TILE):
            px[x, y] = col
    grad.putalpha(MASK)
    return Image.alpha_composite(Image.alpha_composite(SHADOW, grad), bord)

BASE = {
    'light': tile_base('light', BORDER_DARKLINE),
    'dark':  tile_base('dark', RIM_GLOW),
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

def rim_stats(layer):
    """(samples, mean luma, luma spread, mean saturation) of the artwork's own
    backdrop, read off the band just inside the squircle edge."""
    px, rp = layer.load(), RIM_BAND_MASK.load()
    ls, ss = [], 0.0
    for y in range(MARGIN, MARGIN + TILE, 3):
        for x in range(MARGIN, MARGIN + TILE, 3):
            if rp[x, y] < 200:
                continue
            r, g, b, a = px[x, y]
            if a < 200:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            ls.append((0.299 * r + 0.587 * g + 0.114 * b) / 255)
            ss += (mx - mn) / mx if mx else 0.0
    if not ls:
        return 0, 0.0, 0.0, 0.0
    return len(ls), statistics.fmean(ls), statistics.pstdev(ls), ss / len(ls)

def rim_is_light_neutral(stats):
    """A white/near-white tile rather than a brand colour: the dark theme
    re-tints it instead of shipping it as-is."""
    n, lum, _, sat = stats
    return n >= 100 and lum > 0.82 and sat < 0.12

def rim_is_dark_neutral(stats):
    """A flat graphite/black tile (haruna, xclicker): the light theme turns it
    white. Flat matters: dark cover art (Steam games) has a busy edge, and
    inverting that would make a negative of the picture."""
    n, lum, spread, sat = stats
    return n >= 100 and lum < 0.40 and sat < 0.12 and spread < 0.03

def dark_px(c):
    """darkify's colour map: near-neutral colours invert, aimed so white lands
    exactly on the dark tile's mid tone; saturated brand colours stay."""
    r, g, b = c
    mx, mn = max(r, g, b), min(r, g, b)
    w = 1.0 - min(((mx - mn) / mx if mx > 0 else 0.0) / 0.18, 1.0)
    if w <= 0.0:
        return c
    L = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    d = (DARK_LIFT - (DARK_LIFT - DARK_MID_L) * L) - L
    return tuple(v + (min(255, max(0, v + d * 255)) - v) * w for v in c)

def light_px(c, k):
    """lightify's colour map: its mirror, with white landing on near-black."""
    r, g, b = c
    # absolute chroma, not darkify's ratio: on a dark grey a few levels of tint
    # already read as saturated and would half-block the flip
    ch = (max(r, g, b) - min(r, g, b)) / 255
    w = 1.0 - min(max(ch - 0.04, 0.0) / 0.14, 1.0)
    if w <= 0.0:
        return c
    L = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    d = (GLYPH_DARK_L + k * (1.0 - L)) - L
    return tuple(v + (min(255, max(0, v + d * 255)) - v) * w for v in c)

def light_k(back_l):
    """light_px's slope: the backdrop (luma back_l) lands on the light tile's
    mid tone."""
    return (LIGHT_MID_L - GLYPH_DARK_L) / max(1.0 - back_l, 0.05)

def remap(layer, f):
    out = layer.copy()
    px, mp = out.load(), MASK.load()
    for y in range(MARGIN, MARGIN + TILE):
        for x in range(MARGIN, MARGIN + TILE):
            if mp[x, y] == 0:
                continue
            r, g, b, a = px[x, y]
            if a < 250:
                continue      # the artwork's own soft shadow: leave it dark
            px[x, y] = tuple(round(v) for v in f((r, g, b))) + (a,)
    return out

def darkify(layer):
    """Invert the luminance of near-neutral pixels inside the squircle: a white
    backdrop lands on the graphite tile tone, saturated brand colours are left
    alone, and dark neutral detail brightens so it stays readable."""
    return remap(layer, dark_px)

def lightify(layer, back_l):
    """darkify's mirror for the light theme: near-neutral pixels invert, aimed
    so the backdrop (luma back_l) lands on the light tile's mid tone and white
    detail on near-black; brand colours stay. None when the coloured art then
    loses most of its contrast (a yellow logo on white) -- keep it dark then."""
    px, mp = layer.load(), MASK.load()
    n = c0 = c1 = 0.0
    for y in range(MARGIN, MARGIN + TILE):
        for x in range(MARGIN, MARGIN + TILE):
            if mp[x, y] == 0:
                continue
            r, g, b, a = px[x, y]
            if a >= 250 and max(r, g, b) - min(r, g, b) >= 0.18 * 255:
                L = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                n += 1
                c0 += abs(L - back_l)
                c1 += abs(L - LIGHT_MID_L)
    if n > 0.01 * TILE * TILE and c1 < 0.3 * n and c1 < 0.7 * c0:
        return None
    k = light_k(back_l)
    return remap(layer, lambda c: light_px(c, k))

# --- artwork on its own neutral tile -> the standard tile ---------------------
def terms(x, y):
    u, v = (x - C / 2) / (C / 2), (y - C / 2) / (C / 2)
    return (1.0, u, v, u * u, v * v, u * v)

def solve(a, b):
    """Gauss-Jordan with partial pivoting: x with a x = b."""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                k = m[r][c] / m[c][c]
                m[r] = [u - k * w for u, w in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]

def surface(pts):
    """least-squares quadratic surface in x and y through (x, y, rgb) points,
    per channel: a gradient in any direction, and one that darkens faster
    towards an edge (Proton Authenticator's)."""
    a = [[0.0] * 6 for _ in range(6)]
    b = [[0.0] * 6 for _ in range(3)]
    for x, y, c in pts:
        t = terms(x, y)
        for i in range(6):
            for j in range(6):
                a[i][j] += t[i] * t[j]
            for k in range(3):
                b[k][i] += t[i] * c[k]
    return [solve(a, b[k]) for k in range(3)]

def at(fit, x, y):
    t = terms(x, y)
    return tuple(min(255.0, max(0.0, sum(u * w for u, w in zip(f, t)))) for f in fit)

def backdrop(layer):
    """The artwork's own tile as a smooth surface, fitted to the band just
    inside the squircle edge, then refitted without the art it caught there.
    None unless nearly all of that band sits on the fit: a smooth tile, not
    cover art or a busy edge."""
    px, rp = layer.load(), RIM_BAND_MASK.load()
    samples = [(x, y, px[x, y][:3])
               for y in range(MARGIN, MARGIN + TILE, 2) for x in range(MARGIN, MARGIN + TILE, 2)
               if rp[x, y] >= 200 and px[x, y][3] >= 250]
    if len(samples) < 100:
        return None
    keep = samples
    for _ in range(2):
        fit = surface(keep)
        keep = [p for p in samples
                if max(abs(a - b) for a, b in zip(p[2], at(fit, p[0], p[1]))) <= 10]
        if len(keep) < 0.85 * len(samples):
            return None
    return fit

def retile(layer, back, variant, f=None):
    """Map the artwork's colours through f (darkify's or lightify's map, or
    none), then move whatever shows its own tile onto the standard one: each
    pixel shifts by the gap between the standard tile and f(own tile), times
    how much of the pixel is tile (1 - alpha, colour to alpha against the
    fitted gradient `back`). Art keeps its mapped colour; a pale pastel stays
    pale instead of turning into a see-through colour, which the dark tile
    would show through."""
    out = layer.copy()
    px, mp, T = out.load(), MASK.load(), TILE_ROW[variant]
    for y in range(MARGIN, MARGIN + TILE):
        Ty = T[y]
        for x in range(MARGIN, MARGIN + TILE):
            if mp[x, y] == 0:
                continue
            B = at(back, x, y)
            r, g, b, a = px[x, y]
            # how opaque art over B would have to be to give this pixel; a few
            # levels of slack keep bitmap noise in the tile from speckling it
            al = 0.0
            for v, k in zip((r, g, b), B):
                d = abs(v - k) - 3
                if d > 0:
                    al = max(al, d / ((255 - k) if v > k else k))
            if al <= 0.0:
                col = Ty
            else:
                al = min(al, 1.0)
                fp, fb = (f((r, g, b)), f(B)) if f is not None else ((r, g, b), B)
                col = tuple(p + (1 - al) * (t - q) for p, t, q in zip(fp, Ty, fb))
            px[x, y] = tuple(min(255, max(0, round(v))) for v in col) + (a,)
    return out

def tone(lum):
    """which standard tile a neutral backdrop of this luma belongs on, if any."""
    return 'light' if lum > 0.8 else 'dark' if lum < 0.45 else None

def prepare(glyph, name):
    """classify once; return (light_icon, dark_icon, glyph). The two icons are
    the same object unless the artwork supplies its own neutral backdrop."""
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
        stats = rim_stats(layer)
        # a smooth neutral tile of its own (Proton Pass's white, haruna's
        # graphite) is swapped for the standard one; brand colours and cover
        # art keep theirs
        own = tone(stats[1]) if stats[0] >= 100 and stats[3] < 0.12 else None
        back = backdrop(layer) if own else None
        light = dark = layer
        lit = (lightify(layer, stats[1])
               if rim_is_dark_neutral(stats) and name not in KEEP_DARK else None)
        if lit is not None:
            # its own backdrop was a graphite tile: white in the light theme
            k = light_k(stats[1])
            light = retile(layer, back, 'light', lambda c: light_px(c, k)) if back else lit
        elif back:
            light = retile(layer, back, own)
        if rim_is_light_neutral(stats):
            # its own backdrop was a white tile: re-tone it
            dark = retile(layer, back, 'dark', dark_px) if back else darkify(layer)
        elif back:
            dark = retile(layer, back, own)
        light = Image.alpha_composite(Image.alpha_composite(SHADOW, light), BORDER_DARKLINE)
        dark = Image.alpha_composite(Image.alpha_composite(SHADOW, dark), RIM_GLOW)
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
        prepared = prepare(load_512(src), name)
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
# turns into a hard white outline on the dark one, so it goes; 5e gives these
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

# --- 5d. One shadow under every tile; light tiles in the light theme ----------
# MacTahoe draws each app's shadow its own way (an embedded PNG, stacks of faint
# rings, a blurred black rect, or nothing at all for VS Code and Obsidian), so
# no two match, and none match step 5's. For every app SVG that fills the
# squircle, the tile is found by rendering: the first element that leaves the
# squircle opaque. Whatever is drawn before it can only show outside the tile,
# i.e. it is the shadow; it goes, and step 5's shadow goes under everything.
# The light theme also gets step 5's outline on top, and its neutral dark tiles
# (kitty, VS Code, terminals, ...) take the light ramp, with white glyphs made
# dark where they would vanish. Every other neutral tile, in both themes, is
# repainted with step 5's light or dark ramp: MacTahoe's own come in a dozen
# whites, greys and blacks. Every edit is re-rendered: the tile interior must
# come out unchanged (bar the tile's own colour) and art poking outside the
# tile must survive, or the icon stays exactly as MacTahoe drew it.
# Runs before 5e's rim, so the dark theme's untouched SVGs are still identical
# to the light theme's and reuse its result instead of being worked out again.
python3 - "$THEME_LIGHT/apps/scalable" "$THEME_DARK/apps/scalable" \
         "$LIGHT_TILE_TOP" "$LIGHT_TILE_BOT" "$TILE_SHADOW_ALPHA" "$TILE_SHADOW_BLUR" \
         "$TILE_SHADOW_DROP" "$TILE_OUTLINE_ALPHA" "$KEEP_DARK_FILE" \
         "$DARK_TILE_TOP" "$DARK_TILE_BOT" "$DARK_TILE_HL" "$DARK_TILE_HL_SPAN" <<'PYEOF'
import base64, functools, hashlib, io, os, re, subprocess, sys, xml.parsers.expat
from concurrent.futures import ThreadPoolExecutor
from PIL import Image, ImageChops, ImageDraw, ImageFilter

light_dir, dark_dir = sys.argv[1], sys.argv[2]

def rgb(h):
    h = h.lstrip('#')
    if len(h) == 3:
        h = ''.join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def luma(c):
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255

def sat(c):
    return (max(c) - min(c)) / max(c) if max(c) else 0.0

HI, LO = rgb(sys.argv[3]), rgb(sys.argv[4])      # light tile top, bottom
SHADOW_A, SHADOW_BLUR, SHADOW_DROP = (int(v) for v in sys.argv[5:8])
OUTLINE_A = int(sys.argv[8])
DHI, DLO = rgb(sys.argv[10]), rgb(sys.argv[11])  # dark tile top, bottom
DHL, DHL_SPAN = float(sys.argv[12]), float(sys.argv[13])

def keep_dark(path):
    """keep-dark.conf names as file names in the light theme, aliases resolved
    to the SVG they point to (that file is the one that gets recoloured)."""
    try:
        with open(path, encoding='utf-8') as f:
            names = {ln.split('#', 1)[0].strip() for ln in f} - {''}
    except OSError:
        return set()
    out = set()
    for n in names:
        p = os.path.join(light_dir, n + '.svg')
        out.add(os.path.basename(os.path.realpath(p)) if os.path.lexists(p) else n + '.svg')
    return out

KEEP = keep_dark(sys.argv[9])

# --- analysis renders: 128 px, so the 64-grid is 2 px per unit ----------------
N, K = 128, 2
# int(), not round(): 59.4 must stay off the tile's antialiased last pixel
PROBE = [(int(x * K), int(y * K)) for x, y in
         ((32, 4.6), (32, 59.4), (4.6, 32), (59.4, 32),     # just inside each edge
          (10, 10), (54, 10), (10, 54), (54, 54))]          # inside the corners

def squircle(grow):
    m = Image.new('L', (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [4 * K - grow, 4 * K - grow, 60 * K - 1 + grow, 60 * K - 1 + grow],
        radius=13 * K + grow, fill=255)
    return m

INSIDE = squircle(-2)                        # clear of the antialiased edge
OUTSIDE = ImageChops.invert(squircle(2))
# beyond any tile: some are a little squarer or off the grid than the squircle
# (a flickr tile has radius 10), but a full-square shadow reaches ~11 px out
FAR = ImageChops.invert(squircle(4))
BAND_IM = ImageChops.subtract(squircle(-1), squircle(-5))
BAND, BAND_AREA = BAND_IM.load(), BAND_IM.histogram()[255]
IN = INSIDE.load()
AREA = INSIDE.histogram()[255]

def render(b):
    try:
        r = subprocess.run(['rsvg-convert', '-w', str(N), '-h', str(N)], input=b,
                           check=True, capture_output=True)
        return Image.open(io.BytesIO(r.stdout)).convert('RGBA')
    except Exception:
        return None

def opaque(im):
    return im is not None and all(im.getpixel(p)[3] >= 250 for p in PROBE)

def over(im, cut):
    return im.point(lambda v: 255 if v > cut else 0)

def changed(a, b, tol):
    """255 wherever any channel moved by more than tol."""
    return over(functools.reduce(ImageChops.lighter, ImageChops.difference(a, b).split()), tol)

def hits(mask, region):
    return ImageChops.multiply(mask, region).getbbox() is not None

def points(mask):
    """(x, y) of every set pixel of a 0/255 mask."""
    px = mask.load()
    return [(x, y) for y in range(N) for x in range(N) if px[x, y]]

# --- the SVG as byte spans ----------------------------------------------------
# expat for the structure, but every edit is a splice of the original bytes, so
# nothing else in the file (namespaces, entities, formatting) is touched.
DRAW = {'path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon',
        'image', 'use', 'g', 'text', 'a', 'switch', 'svg'}
START_TAG = re.compile(rb'<[^\s/>]+(?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|\'[^\']*\'))*\s*/?>')

class Node:
    __slots__ = ('tag', 'attrs', 'start', 'end', 'kids', 'parent')

    def __init__(self, tag, attrs, start, parent):
        self.tag, self.attrs, self.start, self.parent = tag, attrs, start, parent
        self.end, self.kids = None, []

def tag_end(b, i):
    m = START_TAG.match(b, i)
    if not m:
        raise ValueError('unparsable tag at %d' % i)
    return m.end()

def parse(b):
    p = xml.parsers.expat.ParserCreate()
    stack, root = [], []

    def start(tag, attrs):
        tag = tag[4:] if tag.startswith('svg:') else tag
        n = Node(tag, attrs, p.CurrentByteIndex, stack[-1] if stack else None)
        (stack[-1].kids if stack else root).append(n)
        stack.append(n)

    def end(_):
        n = stack.pop()
        e = tag_end(b, n.start)
        if b[e - 2:e] == b'/>':
            n.end = e
        else:
            # expat reports a self-closing tag's end one byte on, which is why
            # that case is read off the start tag above instead
            i = p.CurrentByteIndex
            if not b.startswith(b'</', i):
                raise ValueError('end tag not at %d' % i)
            n.end = b.index(b'>', i) + 1
    p.StartElementHandler, p.EndElementHandler = start, end
    p.Parse(b, True)
    return root[0] if root and root[0].tag == 'svg' else None

def cut(b, spans):
    out, last = [], 0
    for s, e in sorted(spans):
        out.append(b[last:s])
        last = e
    return b''.join(out) + b[last:]

def drawables(n):
    return [k for k in n.kids if k.tag in DRAW]

def has_effect(n):
    """a group effect that changes how its children composite. A clip-path
    doesn't: it only cuts them (Figma exports wrap the whole icon in one)."""
    st = n.attrs.get('style', '')
    return any(n.attrs.get(k, 'none') != 'none'
               or re.search(r'(?:^|;)\s*%s\s*:\s*(?!none)' % k, st)
               for k in ('filter', 'mask', 'opacity'))

def siblings(path, after):
    out = []
    for n in path:
        sib = drawables(n.parent)
        i = sib.index(n)
        out += [(x.start, x.end) for x in (sib[i + 1:] if after else sib[:i])]
    return out

def find_tile(b, root):
    """Nodes from the <svg> down to the tile: at each level the first element
    whose prefix of the drawing is opaque at every probe. Plain groups are
    entered to find the tile inside them. [] when nothing covers the tile."""
    path, level, later = [], root, []
    while True:
        kids = drawables(level)
        i = next((i for i in range(len(kids)) if opaque(render(
            cut(b, [(x.start, x.end) for x in kids[i + 1:]] + later)))), None)
        if i is None:
            return path
        k = kids[i]
        path.append(k)
        later += [(x.start, x.end) for x in kids[i + 1:]]
        if k.tag != 'g' or not drawables(k) or has_effect(k):
            return path
        level = k

def user_space(root):
    """(kx, ky, ox, oy) mapping the 64-grid onto the file's user space."""
    vb = root.attrs.get('viewBox')
    try:
        if vb:
            p = [float(v) for v in vb.replace(',', ' ').split()]
            if len(p) == 4 and p[2] > 0 and p[3] > 0:
                return p[2] / 64.0, p[3] / 64.0, p[0], p[1]
            return None
        w = float(re.sub(r'[a-z%]+$', '', root.attrs.get('width', '')))
        h = float(re.sub(r'[a-z%]+$', '', root.attrs.get('height', '')))
    except ValueError:
        return None
    return (w / 64.0, h / 64.0, 0.0, 0.0) if w > 0 and h > 0 else None

def in_space(markup, sp):
    if sp != (1.0, 1.0, 0.0, 0.0):
        markup = '<g transform="translate(%.6g %.6g) scale(%.6g %.6g)">%s</g>' % (
            sp[2], sp[3], sp[0], sp[1], markup)
    return markup.encode()

# --- shadow and outline markup ------------------------------------------------
def shadow_png():
    """step 5's SHADOW, drawn the same way, as a 128 px data URI."""
    c = 512
    m = Image.new('L', (c, c), 0)
    ImageDraw.Draw(m).rounded_rectangle([32, 32, 479, 479], radius=104, fill=255)
    a = Image.new('L', (c, c), 0)
    a.paste(SHADOW_A, (0, SHADOW_DROP), m.filter(ImageFilter.GaussianBlur(SHADOW_BLUR)))
    a = a.resize((128, 128), Image.LANCZOS)
    buf = io.BytesIO()
    Image.merge('LA', (Image.new('L', a.size, 0), a)).save(buf, 'PNG', optimize=True)
    return 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode()

# A bitmap rather than a blur filter, so every renderer draws the same pixels
# as the generated icons. xmlns:xlink is declared on the element itself: many
# of these files never declare it, and an undeclared prefix is a parse error.
SHADOW_EL = ('<image xmlns:xlink="http://www.w3.org/1999/xlink" id="tahoeShadow" '
             'width="64" height="64" preserveAspectRatio="none" '
             'href="{0}" xlink:href="{0}"/>').format(shadow_png())
# step 5's 2 px border, i.e. a quarter unit just inside the squircle
OUTLINE_EL = ('<rect id="tahoeOutline" width="55.75" height="55.75" x="4.125" y="4.125" '
              'rx="12.875" ry="12.875" fill="none" stroke="#000" '
              'stroke-opacity="%.4g" stroke-width=".25"/>' % (OUTLINE_A / 255))

def reshadow(b):
    """-> (bytes, None) with MacTahoe's shadow swapped for ours, or (None, why)."""
    if b'tahoeShadow' in b:
        return None, 'done'
    root = parse(b)
    sp = user_space(root) if root is not None else None
    orig = render(b)
    if sp is None or not opaque(orig):
        return None, 'shape'
    path = find_tile(b, root)
    if not path:
        return None, 'shape'
    nb = cut(b, siblings(path, after=False))
    new = render(nb)
    if new is None or hits(changed(orig, new, 8), INSIDE):
        return None, 'kept'           # the tile itself changed: leave it be
    lost = ImageChops.subtract(over(orig.getchannel('A'), 200), over(new.getchannel('A'), 200))
    if hits(lost, OUTSIDE):
        return None, 'kept'           # art drawn under the tile pokes out of it
    at = tag_end(nb, root.start)      # first thing drawn = bottom of the stack
    return nb[:at] + in_space(SHADOW_EL, sp) + nb[at:], None

# --- neutral dark tile -> light tile (light theme) ----------------------------
COLOR = re.compile(rb'((?<![\w-])(?:fill|stroke|stop-color|color)\s*[=:]\s*"?\s*)'
                   rb'(#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|white\b)')

def rim(im):
    """mean (luma, saturation) of the band just inside the squircle edge."""
    px = im.load()
    n = sl = ss = 0.0
    for y in range(0, N, 2):
        for x in range(0, N, 2):
            if BAND[x, y] >= 200 and px[x, y][3] >= 250:
                n += 1
                sl += luma(px[x, y])
                ss += sat(px[x, y][:3])
    return (sl / n, ss / n) if n else (1.0, 1.0)

def by_id(root, gid):
    stack = [root]
    while stack:
        n = stack.pop()
        if n.attrs.get('id') == gid:
            return n
        stack += n.kids
    return None

# --- the standard tile --------------------------------------------------------
# MacTahoe's neutral tiles come in a dozen shades (flat white, cool greys, three
# graphites, black), and step 5's generated ones in one. A neutral tile gets
# step 5's ramp as a fresh gradient, whatever its paint was: darker/lighter
# stops mapped one by one would keep a flat tile flat.
RAMP = {'light': (HI, LO, 0.0, 1.0), 'dark': (DHI, DLO, DHL, DHL_SPAN)}

def ramp_at(which, t):
    top, bot, hl, span = RAMP[which]
    col = [a + (c - a) * t for a, c in zip(top, bot)]
    a = hl * max(0.0, 1.0 - t / span)             # the dark tile's top sheen
    return tuple(round(c + (255 - c) * a) for c in col)

def expect(which):
    im = Image.new('RGB', (N, N))
    px = im.load()
    for y in range(N):
        col = ramp_at(which, min(max((y + 0.5 - 4 * K) / (56 * K), 0.0), 1.0))
        for x in range(N):
            px[x, y] = col
    return im

EXPECT = {w: expect(w) for w in RAMP}

def off_ramp(im, which):
    """mean distance (0-255) from the standard ramp along the band inside the
    tile's edge: top, bottom and sides, clear of art, holes in the tile, ..."""
    d = functools.reduce(ImageChops.lighter,
                         ImageChops.difference(im.convert('RGB'), EXPECT[which]).split())
    return sum(i * n for i, n in enumerate(ImageChops.multiply(d, BAND_IM).histogram())) / BAND_AREA

def ramp_stops(which):
    # the sheen bends the dark ramp over its top part, so that part gets stops
    span = RAMP[which][3]
    ts = [0.0, 1.0] if RAMP[which][2] == 0 else [span * i / 8 for i in range(9)] + [1.0]
    return ''.join('<stop offset="%.4g" stop-color="#%02x%02x%02x"/>' % ((t,) + ramp_at(which, t))
                   for t in ts)

STYLE = re.compile(rb'((?<![\w-])style\s*=\s*")([^"]*)(")')
STYLE_FILL = re.compile(rb'(?:^|;)\s*fill\s*:\s*([^;]*)')
SHAPES = {'path', 'rect', 'circle', 'ellipse', 'polygon'}

def set_tile(b, tile, which, geom):
    """-> (bytes, shift): the tile element filled with a new tahoeTile
    gradient, and how far everything after its start tag moved. The fill goes
    in its style, which beats a presentation attribute and a CSS class; the
    gradient goes last in the file, so every other node keeps its place in
    document order (glyphs() and darken() count on that)."""
    s, e = tile.start, tag_end(b, tile.start)
    tag, url = b[s:e], b'url(#tahoeTile)'
    m = STYLE.search(tag)
    if m:
        body = m.group(2)
        f = STYLE_FILL.search(body)
        if f:
            body = body[:f.start(1)] + url + body[f.end(1):]
        else:
            body = (body.rstrip().rstrip(b';') + b';' if body.strip() else b'') + b'fill:' + url
        tag = tag[:m.start(2)] + body + tag[m.end(2):]
    else:
        at = len(tag) - (2 if tag.endswith(b'/>') else 1)
        tag = tag[:at] + b' style="fill:' + url + b'"' + tag[at:]
    nb = b[:s] + tag + b[e:]
    at = nb.rstrip().rfind(b'</svg>')
    grad = '<linearGradient id="tahoeTile" %s>%s</linearGradient>' % (geom, ramp_stops(which))
    return nb[:at] + grad.encode() + nb[at:], len(tag) - (e - s)

def tile_parts(b, path):
    """-> (the element that paints the tile, spans drawn after it, 5b's sheen
    over it or None). A clipped or filtered group's tile is its first shape."""
    tile, later = path[-1], siblings(path, after=True)
    if tile.tag == 'g':
        # find_tile's test inside the group: the first child that covers the
        # tile (what comes before it can be a shadow under it)
        kids = drawables(tile)
        i = next((i for i in range(len(kids)) if opaque(render(
            cut(b, later + [(k.start, k.end) for k in kids[i + 1:]])))), None)
        if i is None:
            return None, later, None
        later += [(k.start, k.end) for k in kids[i + 1:]]
        tile = kids[i]
    if tile.tag not in SHAPES:
        return None, later, None
    sib = drawables(tile.parent)
    i = sib.index(tile) + 1
    glass = sib[i] if i < len(sib) and b'tahoeGlass' in b[sib[i].start:tag_end(b, sib[i].start)] \
        else None
    if glass is not None:
        later.remove((glass.start, glass.end))
    return tile, later, glass

def restyle(b, root, tile, later, glass, which):
    """-> (bytes, tile-only render) with the tile on the standard ramp (and
    5b's sheen gone: the dark ramp carries its own), or (None, None) when no
    gradient geometry puts it there. The tile's bounding box is tried first,
    either way up (a flipped transform flips it), then the 64-grid in the
    file's user space (a tile larger than the squircle)."""
    sp = user_space(root)
    if b'tahoeTile' in b or sp is None:
        return None, None
    x = sp[2] + 32 * sp[0]
    for geom in ('x1="0" y1="0" x2="0" y2="1"', 'x1="0" y1="1" x2="0" y2="0"',
                 'x1="%.6g" y1="%.6g" x2="%.6g" y2="%.6g" gradientUnits="userSpaceOnUse"'
                 % (x, sp[3] + 4 * sp[1], x, sp[3] + 60 * sp[1])):
        nb, shift = set_tile(b, tile, which, geom)
        gone = [(glass.start + shift, glass.end + shift)] if glass is not None else []
        t = render(cut(nb, gone + [(s + shift, e + shift) for s, e in later]))
        if t is not None and opaque(t) and off_ramp(t, which) <= 3:
            return cut(nb, gone), t
    return None, None

def standard(b):
    """-> (bytes, 'light' | 'dark') with a neutral tile repainted with the
    standard ramp, or (None, why). Every pixel may move at most as far as the
    tile under it did: art drawn over the tile keeps its colours, and anything
    blended with it (overlay, multiply) sends the icon back unchanged."""
    if b'tahoeTile' in b:
        return None, 'standard'
    orig = render(b)
    if not opaque(orig):
        return None, 'shape'
    lum, s = rim(orig)
    which = 'light' if lum > 0.8 else 'dark' if lum < 0.45 else None
    if s >= 0.12 or which is None:
        return None, 'brand'
    root = parse(b)
    path = find_tile(b, root)
    if not path:
        return None, 'shape'
    tile, later, glass = tile_parts(b, path)
    if tile is None:
        return None, 'paint'
    t0 = render(cut(b, later))                # the tile, with 5b's sheen if any
    if t0 is None:
        return None, 'paint'
    # the tile's own paint, art aside, must be neutral all over: a white that
    # fades to cyan (linuxthemestore) or a lilac one (gpodder) is a design, not
    # a shade of the tile. Chroma in levels, not saturation, which blows up on
    # near-black; the top 10% allows for antialiased edges
    px = t0.load()
    ch = sorted(max(p[:3]) - min(p[:3]) for y in range(0, N, 2) for x in range(0, N, 2)
                if BAND[x, y] >= 200 and (p := px[x, y])[3] >= 250)
    if not ch or ch[int(0.9 * len(ch))] > 12:
        return None, 'brand'
    if off_ramp(t0, which) <= 3:
        return None, 'standard'
    nb, t1 = restyle(b, root, tile, later, glass, which)
    if nb is None:
        return None, 'paint'
    after = render(nb)
    if after is None or hits(changed(after, orig, 3), FAR):
        return None, 'paint'                  # what got repainted was not the tile
    moved = ImageChops.subtract(ImageChops.difference(after.convert('RGB'), orig.convert('RGB')),
                                ImageChops.difference(t1.convert('RGB'), t0.convert('RGB')))
    if hits(over(functools.reduce(ImageChops.lighter, moved.split()), 8), INSIDE):
        return None, 'paint'
    return nb, which

def preorder(root):
    out, stack = [], [root]
    while stack:
        n = stack.pop()
        out.append(n)
        stack += reversed(n.kids)
    return out

def artwork(root):
    """drawn nodes, i.e. none inside defs, masks, clip paths or filters, where
    white means coverage rather than colour."""
    out, stack = [], [root]
    while stack:
        n = stack.pop()
        if n.tag in ('defs', 'mask', 'clipPath', 'filter', 'pattern', 'symbol'):
            continue
        if n.tag in DRAW and n is not root:
            out.append(n)
        stack += n.kids
    return out

def stops(root, n):
    """the gradient that actually holds the stops for gradient node n."""
    for _ in range(4):
        if n is None or n.kids:
            break
        h = n.attrs.get('xlink:href') or n.attrs.get('href') or ''
        n = by_id(root, h[1:]) if h.startswith('#') else None
    return n if n is not None and n.tag.endswith('Gradient') else None

def refs(n):
    """ids of the gradients node n fills or strokes with."""
    vals = [n.attrs.get('fill', ''), n.attrs.get('stroke', '')]
    vals += re.findall(r'(?:^|;)\s*(?:fill|stroke)\s*:\s*([^;]+)', n.attrs.get('style', ''))
    return [m.group(1) for m in (re.match(r'\s*url\(#([^)]+)\)', v) for v in vals) if m]

def colours(b, s, e):
    return [(255, 255, 255) if c == b'white' else rgb(c.decode())
            for _, c in COLOR.findall(b[s:e])]

def light_neutral(c):
    return sat(c) <= 0.15 and luma(c) >= 0.6

def footprint(full, without):
    return points(ImageChops.multiply(changed(full, without, 24), INSIDE))

def pale(p):
    return sat(p[:3]) < 0.2 and luma(p) > 0.6

def glyphs(b, root, orig, t0):
    """Nodes (by preorder index) that paint a light neutral glyph onto the tile:
    kitty's prompt, a white logo, or the stacked light layers of one (a face
    over its bevel). Left alone: light detail over coloured art (the whites of
    the cat's eyes), which still contrasts with what is under it; white objects
    with coloured detail on top (an eyeball and its iris), which would turn
    into dark blobs; and faint white sheens, which are not glyphs."""
    order = {id(n): i for i, n in enumerate(preorder(root))}
    po, pt = orig.load(), t0.load()
    picked = set()
    for n in artwork(root):
        own = colours(b, n.start, tag_end(b, n.start))
        grads = [stops(root, by_id(root, r)) for r in refs(n)]
        if not (any(light_neutral(c) for c in own) or any(
                g is not None and all(light_neutral(c) for c in colours(b, g.start, g.end))
                for g in grads)):
            continue
        without = render(cut(b, [(n.start, n.end)]))
        if without is None:
            continue
        pw = without.load()
        f = footprint(orig, without)
        if len(f) < 16:
            continue
        lit = sum(1 for x, y in f if pale(po[x, y]))
        # under it: the bare tile, or another light layer of the same glyph
        bare = sum(1 for x, y in f if pale(pw[x, y])
                   or max(abs(pw[x, y][i] - pt[x, y][i]) for i in range(3)) <= 24)
        if lit < 0.5 * len(f) or bare < 0.6 * len(f):
            continue
        # what later art hides of it, drawn without that art
        chain, a = [], n
        while a is not root:
            chain.append(a)
            a = a.parent
        later = siblings(chain, after=True)
        alone, gone = render(cut(b, later)), render(cut(b, later + [(n.start, n.end)]))
        if alone is None or gone is None:
            continue
        full = footprint(alone, gone)
        seen = set(f)
        hidden = sum(1 for p in full if p not in seen and not pale(po[p]))
        if hidden <= 0.15 * len(full):
            picked.add(order[id(n)])
    return picked

def darken(b, root, picked):
    """Recolour the picked nodes' light neutral paints near-black, in their own
    start tag and in any gradient that only picked nodes use."""
    nodes = preorder(root)
    users = {}
    for i, n in enumerate(nodes):
        for r in refs(n):
            g = stops(root, by_id(root, r))
            if g is not None:
                users.setdefault(id(g), (g, set()))[1].add(i)
    spans = [(nodes[i].start, tag_end(b, nodes[i].start)) for i in picked]
    spans += [(g.start, g.end) for g, us in users.values() if us <= picked]

    def one(m):
        tok = m.group(2)
        c = (255, 255, 255) if tok == b'white' else rgb(tok.decode())
        if not light_neutral(c):
            return m.group(0)
        v = round(255 * (0.11 + (1.0 - luma(c)) * 0.95))     # white -> #1c1c1c
        return m.group(1) + b'#%02x%02x%02x' % (v, v, v)
    out, last = [], 0
    for s, e in sorted(set(spans)):
        if s < last:
            continue                        # nested in a span already done
        out += [b[last:s], COLOR.sub(one, b[s:e])]
        last = e
    return b''.join(out) + b[last:]

OPACITY = re.compile(rb'(?<![\w-])(opacity\s*[=:]\s*"?\s*)([\d.eE+-]+)')

def soften_shadows(b, k):
    """Translucent layers that darken the bare tile evenly are shadows meant
    for the graphite tile, where they barely show; on white they turn into grey
    smudges (VS Code's logo). Scale their opacity by k, the dark/light tile
    luminance ratio, so they read as faintly as they used to."""
    root = parse(b)
    path = find_tile(b, root)
    full = render(b)
    if not path or full is None:
        return b
    t1 = render(cut(b, siblings(path, after=True)))
    if t1 is None:
        return b
    t1, pf = t1.load(), full.load()
    edits = []
    for n in artwork(root):
        if n.start < path[-1].end or drawables(n):
            continue                        # the tile, or a group: its leaves decide
        without = render(cut(b, [(n.start, n.end)]))
        if without is None:
            continue
        pw = without.load()
        f = points(ImageChops.multiply(changed(full, without, 3), INSIDE))
        if len(f) < 16:
            continue
        even = bare = 0
        for x, y in f:
            p, q = pf[x, y], pw[x, y]
            bare += max(abs(q[i] - t1[x, y][i]) for i in range(3)) <= 24
            if min(q[:3]) >= 40:
                a = [1.0 - p[i] / q[i] for i in range(3)]
                even += 0.0 <= min(a) and max(a) < 0.6 and max(a) - min(a) < 0.06
        if even >= 0.85 * len(f) and bare >= 0.6 * len(f):
            edits.append(n)
    for n in sorted(edits, key=lambda n: -n.start):
        e = tag_end(b, n.start)
        tag = b[n.start:e]
        m = OPACITY.search(tag)
        if m:
            tag = tag[:m.start(2)] + b'%.3g' % (float(m.group(2)) * k) + tag[m.end(2):]
        else:
            at = len(tag) - (2 if tag.endswith(b'/>') else 1)
            tag = tag[:at] + b' opacity="%.3g"' % k + tag[at:]
        b = b[:n.start] + tag + b[e:]
    return b

def neutral_art(im, art):
    """Neutral artwork: (light share, dark share) of the tile area, and the
    share of light pixels that border the bare tile -- a white glyph that
    vanishes on white, as opposed to white detail inside coloured art."""
    px = im.load()
    inart = set(art)
    lt = dk = edge = 0
    for x, y in art:
        p = px[x, y][:3]
        if sat(p) >= 0.2:
            continue
        L = luma(p)
        dk += L < 0.35
        if L > 0.6:
            lt += 1
            edge += any((q not in inart) and IN[q] for q in
                        ((x - 2, y), (x + 2, y), (x, y - 2), (x, y + 2))
                        if 0 <= q[0] < N and 0 <= q[1] < N)
    return lt / AREA, dk / AREA, edge / AREA

def contrast(im, tile, region):
    a, t = im.load(), tile.load()
    return sum(abs(luma(a[x, y]) - luma(t[x, y])) for x, y in region) / len(region)

def lighten(b):
    """-> (bytes, 'lit' | 'lit+glyphs') or (None, why); why 'no' = not a
    neutral dark tile at all."""
    orig = render(b)
    lum, s = rim(orig)
    if not (lum < 0.45 and s < 0.12):
        return None, 'no'
    root = parse(b)
    path = find_tile(b, root)
    if not path:
        return None, 'paint'
    # only a tile that is a shape of its own: the art checks below take the
    # tile's whole subtree as "the tile", which a group's first shape is not
    tile, later, _ = tile_parts(b, path)
    nb = restyle(b, root, tile, later, None, 'light')[0] if tile is path[-1] else None
    if nb is None:
        return None, 'paint'                  # a pattern, a bitmap, ...
    after = render(nb)
    if after is None or rim(after)[0] < 0.8:
        return None, 'paint'                  # overlays keep the edge dark
    if hits(changed(after, orig, 3), FAR):
        return None, 'paint'                  # what got repainted was not the tile
    k = lum / rim(after)[0]
    # the artwork: whatever differs from the tile drawn on its own, which also
    # catches translucent art the swap recolours along with the tile
    t0 = render(cut(b, siblings(path, after=True)))
    t1 = render(cut(nb, siblings(find_tile(nb, parse(nb)), after=True)))
    region = points(ImageChops.multiply(changed(orig, t0, 24), INSIDE))
    if len(region) < 0.01 * AREA:
        return soften_shadows(nb, k), 'lit'
    c0 = contrast(orig, t0, region)

    def reads(im):
        c = contrast(im, t1, region)
        return c >= 0.3 or c >= 0.7 * c0
    # opaque art the swap left alone. Contrast is an average, so a small white
    # glyph next to big colourful art (kitty's prompt under the cat) is looked
    # for on its own: light pixels along the bare tile
    art = points(ImageChops.multiply(ImageChops.multiply(
        ImageChops.invert(changed(orig, after, 6)), over(orig.getchannel('A'), 249)), INSIDE))
    lt, dk, edge = neutral_art(after, art)
    if reads(after) and edge <= 0.003:
        return soften_shadows(nb, k), 'lit'
    if lt > 0.01 and dk > 0.01:
        # light and dark neutral art together (paper and text, piano keys, a
        # badge holding a glyph): darkening only the light half merges them
        return None, 'twotone'
    picked = glyphs(b, root, orig, t0)
    if not picked:
        return None, 'unreadable'
    # b and nb differ only in attribute values, so their trees line up node for node
    nb2 = darken(nb, parse(nb), picked)
    after2 = render(nb2)
    if after2 is None or not reads(after2) or neutral_art(after2, art)[2] > 0.003:
        return None, 'unreadable'             # pale colour on white, or a bitmap
    return soften_shadows(nb2, k), 'lit+glyphs'

# --- run ----------------------------------------------------------------------
def svgs(d):
    return [f for f in sorted(os.listdir(d))
            if f.endswith('.svg') and not os.path.islink(os.path.join(d, f))]

def read(p):
    with open(p, 'rb') as f:
        return f.read()

def write(p, b):
    with open(p, 'wb') as f:
        f.write(b)

memo = {}

def standardise(b):
    """-> (bytes, 'light' | 'dark') or (None, None): standard(b), worked out
    once for a file the two themes share."""
    key = hashlib.sha1(b).digest()
    if key not in memo:
        memo[key] = standard(b)
    nb, which = memo[key]
    return (nb, which) if nb is not None else (None, None)

def do_light(name):
    p = os.path.join(light_dir, name)
    b = read(p)
    s, why = reshadow(b)
    if s is None:
        # MacTahoe's shadow stays, but the tile can still take the common ramp
        std, which = standardise(b) if why == 'kept' else (None, None)
        if std is not None:
            write(p, std)
        return b, None, why, which
    out, how, which = s, 'shadow', None
    if name in KEEP:
        how = 'keep'
    else:
        lit, how = lighten(s)
        out = lit if lit is not None else s
    if out is s:
        std, which = standardise(s)
        out = std if std is not None else s
    cut_at = out.rstrip().rfind(b'</svg>')
    sp = user_space(parse(out))
    out = out[:cut_at] + in_space(OUTLINE_EL, sp) + out[cut_at:]
    if render(out) is None:
        return b, None, 'kept', None
    write(p, out)
    return b, s, how, which

def do_dark(name, cache):
    p = os.path.join(dark_dir, name)
    b = read(p)
    key = hashlib.sha1(b).digest()
    s, why = cache[key] if key in cache else reshadow(b)
    if s is not None and render(s) is None:
        s, why = None, 'kept'
    std, which = standardise(s if s is not None else b) \
        if s is not None or why == 'kept' else (None, None)
    out = std if std is not None else s
    if out is not None:
        write(p, out)
    return 'shadow' if s is not None else why, which

pool = ThreadPoolExecutor(os.cpu_count() or 4)
cache, light, light_std = {}, {}, {}
for b, s, how, which in pool.map(do_light, svgs(light_dir)):
    cache[hashlib.sha1(b).digest()] = (s, how if s is None else None)
    light[how] = light.get(how, 0) + 1
    light_std[which] = light_std.get(which, 0) + 1
dark, dark_std = {}, {}
for how, which in pool.map(lambda n: do_dark(n, cache), svgs(dark_dir)):
    dark[how] = dark.get(how, 0) + 1
    dark_std[which] = dark_std.get(which, 0) + 1

done_l = sum(v for k, v in light.items() if k not in ('shape', 'kept', 'done'))
print(f'Tile shadow unified on {done_l} light and {dark.get("shadow", 0)} dark app SVGs '
      f'({light.get("kept", 0)} + {dark.get("kept", 0)} kept MacTahoe\'s, where the '
      f'swap would have changed the tile or cut off art).')
print(f'Common tile ramp: {light_std.get("light", 0)} white + {light_std.get("dark", 0)} '
      f'graphite tiles repainted in the light theme, {dark_std.get("dark", 0)} graphite + '
      f'{dark_std.get("light", 0)} white in the dark one.')
lit = light.get('lit', 0) + light.get('lit+glyphs', 0)
print(f'Light theme: {lit} dark tiles made light ({light.get("lit+glyphs", 0)} with '
      f'darkened glyphs); kept dark: {light.get("twotone", 0)} two-tone art, '
      f'{light.get("unreadable", 0)} unreadable on white, {light.get("paint", 0)} '
      f'unusual tile paint, {light.get("keep", 0)} from keep-dark.conf.')
PYEOF

# --- 5e. Tahoe corner rim on every dark app SVG -------------------------------
# A 1px band just inside the squircle, lit from the top-left and bottom-right
# corners. MacTahoe bakes this into a handful of icons (Finder, Obsidian) and
# omits it everywhere else; this gives the whole dark theme the same edge.
# Runs last so it layers over 5b's re-tint and 5c's Finder, and only in the dark
# theme -- a white rim on the light theme's near-white tile is invisible (5d
# gives that one step 5's dark outline instead).
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

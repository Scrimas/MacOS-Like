#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# setup.sh — build the MacOS-Like-Light / MacOS-Like-Dark icon themes.
#
# Each theme is MacTahoe, which ships with this script in vendor/ (nothing to
# install), with the app icons in prebuilt/ laid over it. On top of that, it
# scans all installed .desktop files, finds app icons that MacTahoe does NOT
# cover, and composites each app's own artwork onto a macOS Tahoe squircle
# tile (geometry matched to MacTahoe: margin 4/64, radius 13/64, top-lit
# gradient, drop shadow).
#
# Three source-art classes are handled differently:
#   1. full-bleed square art  -> becomes the squircle itself (clipped); on a
#                                coloured tile of its own, that tile becomes
#                                a Tahoe brand tile -- see BRAND_TILE_*
#   2. solid disc/blob badge  -> its own background is bled out to the squircle
#   3. shaped / transparent   -> centered glyph on a Tahoe tile
#      logo                      (white tile in the light theme, near-black
#                                glass in dark -- see DARK_TILE_* below)
#
# prebuilt/ holds what steps 5b-5e make of MacTahoe's own app icons: one
# shadow, the common tiles, brand tiles, the dark theme's versions. That work
# takes ~9 minutes and depends only on vendor/ and this script, never on the
# machine, so it runs once, with --rebuild, and its result ships with the
# script; prebuilt/STAMP records what it was made from (--check compares).
#
# Both themes are self-contained and only fall back to a parent theme
# (breeze-plus, breeze, Papirus or Adwaita, whichever is installed) for what
# MacTahoe never had. Each is built in a staging directory next to it and
# swapped in at the end, so a run that fails leaves the old theme untouched.
#
# Output: $XDG_DATA_HOME/icons/MacOS-Like-{Light,Dark} (default ~/.local/share/icons)
#
# Rerunnable: app tiles from an earlier run are reused. Use --force to remake them.
#
# Usage:  setup.sh [--force] [--dry-run] [--rebuild] [--check]
#                  [--inherits-light LIST] [--inherits-dark LIST]

set -euo pipefail

USAGE="usage: setup.sh [--force] [--dry-run] [--rebuild] [--check]
                [--inherits-light LIST] [--inherits-dark LIST]

  --force       remake every app tile instead of reusing the last run's
  --dry-run     list the app tiles that would be made, change nothing
  --rebuild     remake prebuilt/ from vendor/ first (maintainers; ~9 minutes)
  --check       exit 0 if prebuilt/ matches vendor/ and this script, else 1
  --inherits-light LIST, --inherits-dark LIST
                fallback themes for icons MacTahoe has no version of at all"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
THEME_LIGHT="$DATA_HOME/icons/MacOS-Like-Light"
THEME_DARK="$DATA_HOME/icons/MacOS-Like-Dark"

# >>> look
# Everything from here to "<<< look" decides how a tile looks, so a change in
# here makes prebuilt/ stale and remakes every app tile (see section() below).
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

# Brand tile: an app tile of its own colour -- MacTahoe's coloured tiles
# (Spotify, Discord, ...) and generated art that brings one (the Craft apps,
# Beeper, Claude) -- keeps that colour, as a Tahoe ramp: lighter at the top in
# the light theme, deep in the dark one, with a sheen and Finder's corner glass.
# Its black and white ink is toned to the brand too. A tile of several hues
# keeps its own gradient, deepened in the dark theme, under the same sheen.
# Feeds step 5 (generated PNGs), 5d (MacTahoe's SVGs) and 5e (the glass).
BRAND_TILE_HL_LIGHT="0.22"  # white sheen opacity at the top edge
BRAND_TILE_HL_DARK="0.12"
BRAND_TILE_RIM="0.45"       # corner glass, both themes: Finder's own opacity
# <<< look

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
REBUILD=0
CHECK=0
INHERITS_LIGHT=""
INHERITS_DARK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRYRUN=1 ;;
    --rebuild) REBUILD=1 ;;
    --check) CHECK=1 ;;
    --inherits-light) INHERITS_LIGHT="${2:?--inherits-light needs a list}"; shift ;;
    --inherits-dark) INHERITS_DARK="${2:?--inherits-dark needs a list}"; shift ;;
    --source)
      echo "--source is gone: MacTahoe now comes with MacOS-Like (vendor/). Its colour" \
           "variants only recolour the folders; for that, run 'macos-like folders nord'" \
           "(or any of MacTahoe's colours, or a '#rrggbb'), or" \
           "matugen/recolor_folders.py --color '#rrggbb'." >&2
      exit 2 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done
if [ "$DRYRUN" -eq 1 ] && [ "$REBUILD" -eq 1 ]; then
  echo "--dry-run writes nothing, so it can't --rebuild" >&2; exit 2
fi

# --- MacTahoe and prebuilt/ ---------------------------------------------------
# vendor/ is MacTahoe at the commit tools/update-mactahoe.sh pins, exactly as
# its installer lays it out; prebuilt/ is steps 5b-5e's output for it.
SCRIPT="$(readlink -f "$0")"
REPO_DIR="$(dirname "$SCRIPT")"
VENDOR="$REPO_DIR/vendor"
MACTAHOE="$VENDOR/MacTahoe"
MACTAHOE_DARK="$VENDOR/MacTahoe-dark"
PREBUILT="$REPO_DIR/prebuilt"
if [ ! -f "$VENDOR/VERSION" ] || [ ! -f "$MACTAHOE/index.theme" ] \
   || [ ! -d "$MACTAHOE/apps/scalable" ] || [ ! -f "$MACTAHOE_DARK/index.theme" ]; then
  echo "vendor/ is incomplete: $VENDOR should hold MacTahoe and MacTahoe-dark." >&2
  echo "Download MacOS-Like again, or run tools/update-mactahoe.sh." >&2
  exit 1
fi
read -r MACTAHOE_COMMIT < "$VENDOR/VERSION"

# A short hash of the lines between "# >>> NAME" and "# <<< NAME" in this
# script, comments and blank lines aside: "look" holds the tile constants,
# "prebuilt" steps 5b-5e and "tiles" step 5. prebuilt/ is stale when MacTahoe or
# look/prebuilt changed since it was made; the app tiles of an earlier run are
# remade when look/tiles changed.
section() {
  sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$SCRIPT" \
    | grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' || true
}
for s in look prebuilt tiles; do
  [ -n "$(section "$s")" ] || { echo "setup.sh: no '# >>> $s' section" >&2; exit 2; }
done
PREBUILT_ID=$({ echo "$MACTAHOE_COMMIT"; section look; section prebuilt; } \
                | sha256sum | cut -c1-16)
TILES_ID=$({ section look; section tiles; } | sha256sum | cut -c1-16)
STAMP="$PREBUILT/STAMP"
stamp_id() { [ -f "$STAMP" ] && sed -n 's/^inputs=//p' "$STAMP" || true; }

if [ "$CHECK" -eq 1 ]; then
  if [ "$(stamp_id)" = "$PREBUILT_ID" ]; then
    echo "prebuilt/ is up to date ($PREBUILT_ID)."; exit 0
  fi
  echo "prebuilt/ is stale: it was made from '$(stamp_id)', but vendor/ and setup.sh" \
       "now give $PREBUILT_ID. Run ./setup.sh --rebuild." >&2
  exit 1
fi
if [ "$REBUILD" -eq 0 ]; then
  if [ ! -d "$PREBUILT/Light/apps" ] || [ ! -d "$PREBUILT/Dark/apps" ]; then
    echo "prebuilt/ is missing: run ./setup.sh --rebuild (about 9 minutes)." >&2
    exit 1
  fi
  if [ "$(stamp_id)" != "$PREBUILT_ID" ]; then
    echo "warning: prebuilt/ was made by another version of setup.sh or MacTahoe;" \
         "./setup.sh --rebuild remakes it (about 9 minutes)." >&2
  fi
fi

# --- Dependencies -------------------------------------------------------------
# Checked up front: a tool that turns out to be missing mid-run would stop the
# build halfway through. --dry-run only reports them.
missing=()
command -v python3 >/dev/null 2>&1 || missing+=("python3")
python3 -c 'import PIL' 2>/dev/null \
  || missing+=("Pillow        (Arch: python-pillow  Debian/Ubuntu: python3-pil   Fedora: python3-pillow)")
command -v rsvg-convert >/dev/null 2>&1 \
  || missing+=("rsvg-convert  (Arch: librsvg        Debian/Ubuntu: librsvg2-bin  Fedora: librsvg2-tools)")
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'missing dependency: %s\n' "${missing[@]}" >&2
  [ "$DRYRUN" -eq 1 ] || exit 1
fi

# --- Search paths -------------------------------------------------------------
# XDG data dirs in spec order, plus the usual system and Flatpak roots even when
# $XDG_DATA_DIRS leaves them out. They are searched for the parent theme,
# .desktop files and source artwork alike.
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

echo "Base: MacTahoe ${MACTAHOE_COMMIT:0:7} (vendor/)"

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
# so the folders follow the wallpaper palette. Asked up front, so the build
# itself runs unattended; a "no" is remembered.
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
# holding the generated PNGs differ.
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

# The run itself (step 0, assembling both themes from vendor/ and prebuilt/,
# and the order of every step) is at the end of this file, under "--- run".
# Everything up to there only defines functions and gathers what they need.

# --- 1. Collect Icon= names from every .desktop file --------------------------
mapfile -t ICONS < <(
  for d in "${DATA_DIRS[@]}"; do
    d="$d/applications"
    [ -d "$d" ] || continue
    # grep exits 2 on a dangling .desktop link and 1 on a dir without Icon=
    # lines; under errexit either would end the loop and skip the later dirs.
    { grep -Rhs --include='*.desktop' '^Icon=' "$d" || true; } | cut -d= -f2-
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
# themes, and drop any PNG generated for it: apps/<size> is Type=Fixed and
# would outrank the alias.
link_case_alias() {
  local name="$1" alt="$2" t d e
  for t in "$OUT_LIGHT" "$OUT_DARK"; do
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
# For the themes being built, $OUT_LIGHT and $OUT_DARK: the staging copies, or
# on --dry-run the installed themes, which it only reads. An app's tiles from
# the last run are copied over rather than made again, unless --force says so
# or the tile code or look changed since (TILES_ID, kept in each theme's
# .macos-like file).
BUILD_INFO=.macos-like

built_tiles() { sed -n 's/^tiles=//p' "$1/$BUILD_INFO" 2>/dev/null || true; }

has_tiles() {   # every size of $1's tile in both installed themes
  local s
  for s in "${SIZES[@]}"; do
    [ -f "$THEME_LIGHT/apps/$s/$1.png" ] && [ -f "$THEME_DARK/apps/$s/$1.png" ] || return 1
  done
}

reuse_tiles() {
  local s
  for s in "${SIZES[@]}"; do
    cp -p "$THEME_LIGHT/apps/$s/$1.png" "$OUT_LIGHT/apps/$s/"
    cp -p "$THEME_DARK/apps/$s/$1.png" "$OUT_DARK/apps/$s/"
  done
}

plan_work() {
  local n base alt src o name t d s reuse=0
  if [ "$FORCE" -eq 0 ] && [ "$(built_tiles "$THEME_LIGHT")" = "$TILES_ID" ] \
     && [ "$(built_tiles "$THEME_DARK")" = "$TILES_ID" ]; then
    reuse=1
  fi
  if [ "$DRYRUN" -eq 0 ]; then
    for t in "$OUT_LIGHT" "$OUT_DARK"; do
      for s in "${SIZES[@]}"; do mkdir -p "$t/apps/$s"; done
    done
  fi

  WORK=()   # entries: "name<TAB>srcpath"
  REUSED=0
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
    if [ "$reuse" -eq 1 ] && has_tiles "$base"; then
      [ "$DRYRUN" -eq 1 ] || reuse_tiles "$base"
      REUSED=$((REUSED + 1))
      continue
    fi
    if src=$(resolve_src "$n"); then
      WORK+=("$base"$'\t'"$src")
    else
      echo "  skip (no source art): $n"
    fi
  done
  # Overrides are wrapped like everything else, and unconditionally: they bypass
  # covered() and the reuse above, so a rerun always re-derives them from the
  # pinned source. MacTahoe's own files must go first, or its apps/16|22|32 SVGs
  # (Type=Fixed) and apps/scalable copy would outrank the PNGs generated below.
  for o in "${OVERRIDES[@]}"; do
    name="${o%%=*}"; src="${o#*=}"
    [ -f "$src" ] || { echo "  override source missing: $src" >&2; continue; }
    if [ "$DRYRUN" -eq 0 ]; then
      for t in "$OUT_LIGHT" "$OUT_DARK"; do
        for d in "$t"/apps/*/; do rm -f "$d$name.svg" "$d$name.png"; done
      done
    fi
    WORK+=("$name"$'\t'"$src")
  done
  echo "App tiles: ${#WORK[@]} to make, $REUSED reused from the last run."
}

# >>> tiles
# --- 5. Composite with Pillow -------------------------------------------------
step_5() {
  [ "${#WORK[@]}" -gt 0 ] || return 0
  WORKLIST=$(mktemp)
  printf '%s\n' "${WORK[@]}" > "$WORKLIST"
  python3 - "$OUT_LIGHT" "$OUT_DARK" "$WORKLIST" \
           "$DARK_TILE_TOP" "$DARK_TILE_BOT" "$DARK_TILE_HL" "$DARK_TILE_HL_SPAN" \
           "$DARK_TILE_RIM" "$LIGHT_TILE_TOP" "$LIGHT_TILE_BOT" \
           "$TILE_SHADOW_ALPHA" "$TILE_SHADOW_BLUR" "$TILE_SHADOW_DROP" \
           "$TILE_OUTLINE_ALPHA" "$KEEP_DARK_FILE" \
           "$BRAND_TILE_HL_LIGHT" "$BRAND_TILE_HL_DARK" "$BRAND_TILE_RIM" <<'PYEOF'
import sys, os, math, random, statistics, subprocess, tempfile, colorsys
from concurrent.futures import ThreadPoolExecutor, as_completed
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
BRAND_HL = {'light': float(sys.argv[16]), 'dark': float(sys.argv[17])}
BRAND_RIM = float(sys.argv[18])

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
    """quadratic terms first, then the cubic ones: a fit keeps len(coeffs)."""
    u, v = (x - C / 2) / (C / 2), (y - C / 2) / (C / 2)
    return (1.0, u, v, u * u, v * v, u * v, u * u * u, v * v * v, u * u * v, u * v * v)

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

def surface(pts, n=6):
    """least-squares quadratic (n=6) or cubic (n=10) surface in x and y through
    (x, y, rgb) points, per channel: a gradient in any direction, and one that
    darkens faster towards an edge (Proton Authenticator's)."""
    a = [[0.0] * n for _ in range(n)]
    b = [[0.0] * n for _ in range(3)]
    for x, y, c in pts:
        t = terms(x, y)
        for i in range(n):
            for j in range(n):
                a[i][j] += t[i] * t[j]
            for k in range(3):
                b[k][i] += t[i] * c[k]
    return [solve(a, b[k]) for k in range(3)]

def at(fit, x, y):
    t = terms(x, y)       # zip stops at the fit's own number of terms
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

# --- artwork on a brand-colour tile of its own -> Tahoe brand tile ------------
# The Craft apps, Beeper, Claude: a flat or graded saturated tile with art on
# it. The tile is fitted as a smooth surface, every pixel is read as bare tile,
# tile under a translucent shadow or glow (Breeze long shadows, Kasts' rings),
# or art, and the tile is repainted as a Tahoe ramp of its own colour. Each test
# below has a wide margin on the icons it was tuned on; an icon that fails one
# keeps the plain full-bleed treatment, never a half-repainted tile.
TOL = 10      # levels a pixel may sit from the fitted tile and still be tile
NSEC = 72     # angular sectors of the edge band

def off(c, f):
    return max(abs(a - b) for a, b in zip(c, f))

def classify(c, B):
    """('tile', None), ('shade', k) for B * k, ('glow', k) for B lifted k of
    the way to white, or ('art', None)."""
    if off(c, B) <= TOL:
        return 'tile', None
    n = sum(b * b for b in B)
    if n:
        k = sum(a * b for a, b in zip(c, B)) / n
        if 0.3 <= k < 1.0 and max(abs(a - k * b) for a, b in zip(c, B)) <= TOL:
            return 'shade', k
    w = [255 - b for b in B]
    n = sum(v * v for v in w)
    if n:
        k = sum((a - b) * v for a, b, v in zip(c, B, w)) / n
        if 0.0 < k <= 0.7 and max(abs(a - (b + k * v)) for a, b, v in zip(c, B, w)) <= TOL:
            return 'glow', k
    return 'art', None

def band_samples(layer):
    px, rp = layer.load(), RIM_BAND_MASK.load()
    return [(x, y, px[x, y][:3])
            for y in range(MARGIN, MARGIN + TILE, 2) for x in range(MARGIN, MARGIN + TILE, 2)
            if rp[x, y] >= 200 and px[x, y][3] >= 250]

def band_fit(samples):
    """The tile as a quadratic surface, from the edge band: the median of each
    sector that is mostly one colour, then RANSAC over those medians (seeded,
    so every run picks the same tile), refined on the band samples it explains.
    A plain least-squares fit is pulled off by art crossing the edge (the Craft
    animals cover a fifth of it), and one seeded from the commonest colour only
    ever learns a stripe of a gradient tile (Kasts)."""
    sec = [[] for _ in range(NSEC)]
    for s in samples:
        a = math.atan2(s[1] - C / 2, s[0] - C / 2)
        sec[int((a + math.pi) / (2 * math.pi) * NSEC) % NSEC].append(s)
    meds = []
    for ss in sec:
        if len(ss) < 8:
            continue
        m = tuple(statistics.median(s[2][i] for s in ss) for i in range(3))
        if sum(off(s[2], m) <= 12 for s in ss) >= 0.6 * len(ss):
            meds.append((statistics.fmean(s[0] for s in ss),
                         statistics.fmean(s[1] for s in ss), m))
    if len(meds) < 12:
        return None
    rnd = random.Random(0)
    best, most = None, -1
    for _ in range(300):
        try:
            fit = surface(rnd.sample(meds, 8))
        except ZeroDivisionError:
            continue
        n = sum(off(m[2], at(fit, m[0], m[1])) <= TOL for m in meds)
        if n > most:
            best, most = fit, n
    if best is None:
        return None
    keep = [m for m in meds if off(m[2], at(best, m[0], m[1])) <= TOL]
    for _ in range(3):
        if len(keep) < 12:
            return None
        try:
            fit = surface(keep)
        except ZeroDivisionError:
            return None
        keep = [s for s in samples if off(s[2], at(fit, s[0], s[1])) <= 12]
    return fit

def grow_fit(layer, fit):
    """Refit on every pixel of the squircle that reads as bare tile, cubic once
    the samples span it: a fit taken from the band alone drifts more than TOL
    inside the tile (Francis, Kasts), and those pixels would keep their old
    colour as patches."""
    px, mp = layer.load(), MASK.load()
    pts = [(x, y, px[x, y][:3]) for y in range(MARGIN, MARGIN + TILE, 3)
           for x in range(MARGIN, MARGIN + TILE, 3) if mp[x, y] == 255 and px[x, y][3] >= 250]
    for _ in range(4):
        keep = [p for p in pts if off(p[2], at(fit, p[0], p[1])) <= TOL]
        if len(keep) < 60:
            break
        try:
            fit = surface(keep, 10 if len(keep) >= 400 else 6)
        except ZeroDivisionError:
            break
    return fit

def classes(layer, fit):
    """classify() for every pixel of the squircle. Specks of art, shade or glow
    are tile grain (Claude's), not design: under 8 px, or under 64 px and never
    more than 32 levels off the tile. Left alone they keep the old tile colour,
    or darken and lift the new one, and speckle it."""
    src, mp = layer.load(), MASK.load()
    kind = {}
    for y in range(MARGIN, MARGIN + TILE):
        for x in range(MARGIN, MARGIN + TILE):
            if mp[x, y]:
                kind[x, y] = classify(src[x, y][:3], at(fit, x, y))
    seen = set()
    for p, (k, _) in kind.items():
        if k == 'tile' or p in seen:
            continue
        blob, todo = [p], [p]
        seen.add(p)
        while todo:
            x, y = todo.pop()
            for q in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if q not in seen and kind.get(q, ('',))[0] == k:
                    seen.add(q)
                    blob.append(q)
                    todo.append(q)
        if len(blob) < 8 or (len(blob) < 64 and max(
                off(src[q][:3], at(fit, *q)) for q in blob) <= 32):
            for q in blob:
                kind[q] = ('tile', None)
    return kind

def two_tone(layer, fit, samples):
    """A second smooth saturated surface over a quarter of the tile or more: a
    split design (Kontrast), not art on a tile."""
    rest = [s for s in samples if classify(s[2], at(fit, s[0], s[1]))[0] == 'art']
    if len(rest) < 30:
        return False
    bins = {}
    for s in rest:
        bins.setdefault(tuple(v // 12 for v in s[2]), []).append(s)
    keep = max(bins.values(), key=len)
    for _ in range(3):
        if len(keep) < 12:
            return False
        try:
            f2 = surface(keep)
        except ZeroDivisionError:
            return False
        keep = [s for s in rest if off(s[2], at(f2, s[0], s[1])) <= TOL]
    px, mp = layer.load(), MASK.load()
    n = m = 0
    for y in range(MARGIN, MARGIN + TILE, 4):
        for x in range(MARGIN, MARGIN + TILE, 4):
            if mp[x, y] == 255:
                n += 1
                m += off(px[x, y][:3], at(f2, x, y)) <= TOL
    c = at(f2, C / 2, C / 2)
    return m >= 0.25 * n and max(c) - min(c) >= 0.12 * 255

def stray_tile(layer, fit, kind):
    """share of the squircle read as art yet within 48 levels of the tile: tile
    the fit failed to explain (0.01 at most on the icons this was tuned on,
    0.05 and up on Breeze long shadows that are not a plain darkening)."""
    px = layer.load()
    n = m = 0
    for (x, y), (k, _) in kind.items():
        if px[x, y][3] < 250:
            continue
        n += 1
        m += k == 'art' and off(px[x, y][:3], at(fit, x, y)) <= 48
    return m / max(n, 1)

def neutral(c):
    """1 for black, white and greys up to a chroma of 0.10, 0 from 0.22."""
    return 1.0 - min(max(((max(c) - min(c)) / 255 - 0.10) / 0.12, 0.0), 1.0)

def ink_and_paper(layer, kind):
    """The neutral art is ink and paper (engravings, white logos), not grey
    material: under half of it is mid grey. A chalkboard (Cantor) or a grey
    elephant (Tokodon) is near all mid grey, and keeps its colour."""
    px = layer.load()
    n = mid = 0
    for (x, y), (k, _) in kind.items():
        c = px[x, y][:3]
        if k == 'art' and px[x, y][3] >= 250 and neutral(c) >= 1.0:
            n += 1
            mid += 0.18 <= luma(c) <= 0.70
    return mid < 0.5 * n if n else True

def many_hued(fit):
    """the fitted tile spans several hues (a teal -> green ramp, Instagram's):
    a design of its own, not one brand colour."""
    hs = []
    for y in range(MARGIN, MARGIN + TILE, 16):
        for x in range(MARGIN, MARGIN + TILE, 16):
            c = at(fit, x, y)
            if MASK.getpixel((x, y)) == 255 and max(c) - min(c) >= 24:
                hs.append(colorsys.rgb_to_hsv(*(v / 255 for v in c))[0])
    if not hs:
        return False
    sx = sum(math.cos(2 * math.pi * h) for h in hs) / len(hs)
    sy = sum(math.sin(2 * math.pi * h) for h in hs) / len(hs)
    r = min(max(math.hypot(sx, sy), 1e-9), 1.0)
    return math.sqrt(max(0.0, -2 * math.log(r))) > 0.25   # circular std, radians

def brand_tile(layer, name):
    """(fit, kind, brand colour, tint, many-hued) for art on a coloured tile of
    its own, else None."""
    samples = band_samples(layer)
    if len(samples) < 100:
        return None
    fit = band_fit(samples)
    if fit is None:
        return None
    c = at(fit, C / 2, C / 2)
    if max(c) - min(c) < 16:
        return None           # neutral: backdrop()'s business
    if sum(classify(s[2], at(fit, s[0], s[1]))[0] != 'art'
           for s in samples) < 0.70 * len(samples):
        return None           # not a tile along the edge: cover art, scenes
    fit = grow_fit(layer, fit)
    if two_tone(layer, fit, samples):
        print(f'  brand tile left as-is (two-tone design): {name}')
        return None
    kind = classes(layer, fit)
    if stray_tile(layer, fit, kind) > 0.03:
        print(f'  brand tile left as-is (tile not fully explained): {name}')
        return None
    b = tuple(round(v) for v in at(fit, C / 2, C / 2))
    return fit, kind, b, ink_and_paper(layer, kind), many_hued(fit)

def hls(c, l=None, dl=0.0, ds=0.0, dh=0.0):
    h, ll, s = colorsys.rgb_to_hls(*(v / 255 for v in c))
    ll = l if l is not None else ll + dl
    r = colorsys.hls_to_rgb((h + dh) % 1, min(1, max(0, ll)), min(1, max(0, s + ds)))
    return tuple(round(v * 255) for v in r)

def brand_palette(b, variant):
    """(ramp top, ramp bottom, ink, paper). Light: the brand as a ramp, a
    little lighter and cooler at the top, ink a deep brand shade, paper the
    light tile's white. Dark: the brand deepened, ink near-black brand, paper a
    pale brand tint. Step 5d's brand_palette is the same: keep them equal."""
    if variant == 'light':
        top, bot = hls(b, dl=.08, ds=.04, dh=-.012), hls(b, dl=-.10, dh=.012)
        ink, paper = hls(b, l=.16, ds=.1), LIGHT_TOP
    else:
        l = colorsys.rgb_to_hls(*(v / 255 for v in b))[1]
        top_l = min(.26, l)
        top, bot = hls(b, l=top_l, ds=-.05), hls(b, l=max(.06, top_l - .12), ds=-.1)
        ink = hls(b, l=.07)
        paper = tuple(round(v + (255 - v) * .72) for v in b)
    return top, bot, ink, paper

def deepen(c):
    """a many-hued tile's colour in the dark theme: as deep as the brand ramp,
    its hue kept (step 5d deepens such a tile's gradient stops the same way)."""
    return hls(c, l=max(.06, min(.26, colorsys.rgb_to_hls(*(v / 255 for v in c))[1]) - .06),
               ds=-.08)

def ink_map(ink, paper):
    """neutral colours onto the ink -> paper ramp by luma; colour stays."""
    def f(c):
        w = neutral(c)
        t = min(max((luma(c) - 0.05) / 0.85, 0.0), 1.0)
        return tuple(v + (i + (p - i) * t - v) * w for v, i, p in zip(c, ink, paper))
    return f

def brand_ground(brand, variant):
    """the repainted tile, shade and glow pixels: {(x, y): colour}. One brand
    colour: its ramp. Many hues: the tile's own colours (deepened in the dark
    theme) under the same sheen."""
    fit, kind, b, _, many = brand
    top, bot = brand_palette(b, variant)[:2]
    rows = tile_rows(top, bot, BRAND_HL[variant], DARK_HL_SPAN)
    res = {}
    for (x, y), (k, v) in kind.items():
        if k == 'art':
            continue
        if many:
            c = at(fit, x, y)
            c = deepen(c) if variant == 'dark' else c
            a = BRAND_HL[variant] * max(0.0, 1.0 - min(max((y - MARGIN) / TILE, 0.0), 1.0)
                                        / DARK_HL_SPAN)
            t = tuple(u + (255 - u) * a for u in c)
        else:
            t = rows[y]
        res[x, y] = (t if k == 'tile' else tuple(u * v for u in t) if k == 'shade'
                     else tuple(u + (255 - u) * v for u in t))
    return res

def rebrand(layer, brand, ground, tone=None):
    """the layer on its brand tile (ground from brand_ground), its art mapped
    through tone (None: left as it is)."""
    kind = brand[1]
    tone = tone or (lambda c: c)
    src = layer.load()
    out = layer.copy()
    px = out.load()
    res = dict(ground)
    for (x, y), (k, _) in kind.items():
        if k != 'art':
            continue
        c = src[x, y][:3]
        bg = [(x + dx, y + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)
              if kind.get((x + dx, y + dy), ('art',))[0] != 'art']
        if not bg:
            res[x, y] = tone(c)       # inside the art: opaque, whatever its colour
            continue
        # Anti-aliased edge: c = al * A + (1 - al) * the background pixel next
        # to it, A being the art colour nearby. Fractional alpha only here: an
        # unmix of every pixel against the tile reads opaque art close to the
        # tile colour as translucent, and the dark tile then shows through it.
        mx = sum(q[0] for q in bg) / len(bg)
        my = sum(q[1] for q in bg) / len(bg)
        q = min(bg, key=lambda q: (q[0] - mx) ** 2 + (q[1] - my) ** 2)
        pb = src[q][:3]
        near = [src[x + dx, y + dy][:3] for dx in range(-2, 3) for dy in range(-2, 3)
                if kind.get((x + dx, y + dy), ('',))[0] == 'art']
        A = max(near, key=lambda a: sum((u - w) ** 2 for u, w in zip(a, pb)))
        d = [u - w for u, w in zip(A, pb)]
        n = sum(t * t for t in d)
        al = 1.0 if n == 0 else min(max(sum((u - w) * t for u, w, t in zip(c, pb, d)) / n, 0.0), 1.0)
        res[x, y] = tuple(al * a + (1 - al) * o for a, o in zip(tone(A), res[q]))
    for (x, y), v in res.items():
        px[x, y] = tuple(min(255, max(0, round(u))) for u in v) + (src[x, y][3],)
    return out

# Legibility, measured on 128 px copies like step 5d's renders: the luma steps
# of 0.15 and up between pixels 2 px apart inside the squircle.
S128 = 128
_IN128 = Image.new('L', (S128, S128), 0)
ImageDraw.Draw(_IN128).rounded_rectangle([10, 10, 117, 117], radius=24, fill=255)
IN128 = _IN128.load()
PTS128 = [(x, y) for y in range(0, S128, 2) for x in range(0, S128, 2) if IN128[x, y] == 255]

def edge_steps(im):
    L = im.convert('L').load()
    out = {}
    for x, y in PTS128:
        for q in ((x + 2, y), (x, y + 2)):
            if q[0] < S128 and q[1] < S128 and IN128[q] == 255 and abs(L[x, y] - L[q]) >= 38:
                out[(x, y), q] = abs(L[x, y] - L[q])
    return out

def legible(r, steps, art):
    """The outlines that made the icon read still show: three in five of the
    original's luma steps keep a third of their contrast (and 0.08); or the art
    is a panel (JetBrains' black square) whose own content keeps reading, even
    if its edge melts into the deep tile. Step 5d tests its tiles the same way."""
    if len(steps) < 40:
        return True
    L = r.convert('L').load()
    kept = inner = inner_kept = 0
    for (p, q), d in steps.items():
        ok = abs(L[p] - L[q]) >= max(20, d / 3)
        kept += ok
        if p in art and q in art:
            inner += 1
            inner_kept += ok
    return kept >= 0.6 * len(steps) or (inner >= 0.25 * len(steps) and inner_kept >= 0.8 * inner)

def small(im):
    return im.resize((S128, S128), Image.LANCZOS)

def brand_variant(layer, brand, variant):
    """The icon on its brand tile for one theme, or None when nothing keeps
    its art readable there. Neutral art is toned to the brand (ink and paper
    only, not grey material); in the dark theme, dark art straight on the tile
    (Spotify's waves) that would sink into the deep tile has the tone map run
    the other way round instead, whatever it is."""
    _, kind, b, tint, _ = brand
    _, _, ink, paper = brand_palette(b, variant)
    ground = brand_ground(brand, variant)
    am = Image.new('L', (C, C), 0)
    ap = am.load()
    for p, (k, _) in kind.items():
        if k == 'art':
            ap[p] = 255
    am = am.resize((S128, S128), Image.BOX).load()
    art = {p for p in PTS128 if am[p] >= 128}
    steps = edge_steps(small(layer))
    out = rebrand(layer, brand, ground)
    plans = [ink_map(ink, paper)] if tint else []
    if variant == 'dark':
        plans.append(ink_map(paper, ink))
    for i, f in enumerate(plans):
        if variant == 'dark' and i == len(plans) - 1 and legible(small(out), steps, art):
            break                     # reads as it is: no need to turn it round
        cand = rebrand(layer, brand, ground, f)
        if legible(small(cand), steps, art):
            out = cand
            break
    if not legible(small(out), steps, art):
        return None
    return Image.alpha_composite(Image.alpha_composite(SHADOW, out), BRAND_EDGE[variant])

RIM_BRAND = rim_layer(BRAND_RIM)
BRAND_EDGE = {
    'light': Image.alpha_composite(RIM_BRAND, BORDER_DARKLINE),
    'dark': RIM_BRAND,
}
BRANDED = []    # names that got a brand tile, for the summary
KEPT_PLAIN = []  # (name, theme) whose art would not read on the brand tile

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
        brand = brand_tile(layer, name)
        branded = {}
        if brand is not None:
            BRANDED.append(name)
            branded = {v: brand_variant(layer, brand, v) for v in ('light', 'dark')}
            KEPT_PLAIN.extend((name, v) for v, im in branded.items() if im is None)
            if None not in branded.values():
                return branded['light'], branded['dark'], None
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
        # every tile but a light one gets the corner glass, in both themes
        # (white glass on a white tile is invisible)
        edge = (Image.alpha_composite(RIM_GLOW, BORDER_DARKLINE)
                if rim_stats(light)[1] < 0.8 else BORDER_DARKLINE)
        light = Image.alpha_composite(Image.alpha_composite(SHADOW, light), edge)
        dark = Image.alpha_composite(Image.alpha_composite(SHADOW, dark), RIM_GLOW)
        # a brand tile for the theme where its art reads, the plain one where
        # it would not
        return tuple(branded[v] if branded.get(v) is not None else im
                     for v, im in (('light', light), ('dark', dark))) + (None,)
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

def make(line):
    """One app's icon at every size in both themes; an error line if it failed."""
    name, src = line.split('\t', 1)
    try:
        prepared = prepare(load_512(src), name)
        for variant, out_dir in (('light', light_dir), ('dark', dark_dir)):
            icon = compose(prepared, variant)
            for s in SIZES:
                out = icon if s == C else icon.resize((s, s), Image.LANCZOS)
                out.save(os.path.join(out_dir, 'apps', str(s), name + '.png'))
    except Exception as e:
        return f'  FAIL {name}: {e}'
    return None

# Apps are independent of each other (brand_tile() seeds its own Random), and
# rsvg-convert and most of Pillow run outside the GIL, so threads share the work.
jobs = [ln.rstrip('\n') for ln in open(worklist) if ln.strip()]
fails = []
tty = sys.stdout.isatty()
with ThreadPoolExecutor(os.cpu_count() or 4) as pool:
    futures = [pool.submit(make, j) for j in jobs]
    for i, f in enumerate(as_completed(futures), 1):
        if f.result():
            fails.append(f.result())
        if tty:
            print(f'\r  making tiles: {i}/{len(jobs)}', end='', flush=True)
if tty:
    print()
for err in sorted(fails):
    print(err, file=sys.stderr)
print(f'Generated {len(jobs) - len(fails)} icons x2 variants ({len(fails)} failed; '
      f'{len(BRANDED)} on a brand tile).')
for name, theme in sorted(KEPT_PLAIN):
    print(f'  brand tile left out in the {theme} theme (art would not read): {name}')
PYEOF
  rm -f "$WORKLIST"
}
# <<< tiles

# >>> prebuilt
# Steps 5b-5e: MacTahoe's own app SVGs. Only --rebuild runs them all, on fresh
# copies of vendor/, and stores the result as prebuilt/ (rebuild_prebuilt,
# below); a normal run reruns 5d and 5e for keep-dark.conf's icons alone.

# --- 5b. Dark-tile copies of MacTahoe's own app SVGs --------------------------
# MacTahoe-dark/apps/scalable is a symlink to MacTahoe/apps/scalable: upstream
# ships no dark app icons at all, and the light tile is baked into each SVG as a
# near-white linearGradient (or a mid grey one for apps with a white logo).
# Re-tint just that gradient into the near-black glass tile, add the top sheen,
# and drop the results into the dark theme, where they shadow MacTahoe's.
# $1: MacTahoe's app SVGs, $2: the dark theme's apps/scalable.
step_5b() {
python3 - "$1" "$2" \
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

STOP_EL = re.compile(r'<stop\b[^>]*/>')
STYLE_COLOR = re.compile(r'(stop-color\s*:\s*)(#[0-9a-fA-F]{3,6})')

def drawn(stop):
    """the colour a <stop> is drawn with: a stop-color in its style beats the
    attribute. Some MacTahoe tiles keep the template's grey attributes and get
    their real colour (Zen Twilight's purple) through the style."""
    m = STYLE_COLOR.search(stop) or STOP.search(stop)
    return m.group(2) if m else '#000'

FILL_REF = re.compile(r'<[a-zA-Z]+\b[^>]*\bfill="url\(#([^)]+)\)"[^>]*>')
STYLE_FILL = re.compile(r'\bstyle="[^"]*?\bfill\s*:\s*([^;"]+)')

def stale(s):
    """Ids of gradients a shape names in its fill attribute while its style
    paints it with something else: leftovers of MacTahoe's template, not the
    tile. Half-Life: Alyx's tile is drawn brown over an unused grey template
    gradient; maxint's template gradient paints its white logo."""
    out = set()
    for m in FILL_REF.finditer(s):
        f = STYLE_FILL.search(m.group(0))
        if f and f.group(1).strip() != 'url(#%s)' % m.group(1):
            out.add(m.group(1))
    return out

def retint(m, seen, skip):
    block = m.group(0)
    hexes = [c for _, c, _ in STOP.findall(block)]
    if not hexes:
        return block
    gid = ID.search(GRAD_OPEN.match(block).group(1))
    if gid and gid.group(1) in skip:
        return block
    lit = any(c.lower() in SIG_LIGHT for c in hexes)
    drk = any(c.lower() in SIG_DARK for c in hexes)
    if not (lit or drk):
        return block
    cols = [rgb(drawn(s)) for s in STOP_EL.findall(block)]
    # only touch gradients that are entirely neutral as drawn: those are tiles,
    # never artwork. The light tile must also be light and the grey tile
    # mid-dark, so a brand gradient that merely grazes a signature colour is
    # left alone (5d makes it a brand tile).
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
        col = '#%02x%02x%02x' % tuple(round(a + (b - a) * t) for a, b in zip(LO, HI))
        # the attribute and the style both, so whichever wins draws the tile
        s = STOP.sub(lambda c: c.group(1) + col + c.group(3), sm.group(0))
        return STYLE_COLOR.sub(lambda c: c.group(1) + col, s)

    out = STOP_EL.sub(one, block)
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
    skip = stale(s)
    out = GRAD.sub(lambda m: retint(m, seen, skip), s)  # noqa: B023 -- called before seen rebinds
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
}

# --- 5c. Tahoe dark Finder ----------------------------------------------------
# 5b only re-tints near-white tiles; Finder's tile is a saturated blue gradient,
# so it passes through as the light-mode artwork. In Tahoe's dark appearance the
# icon inverts instead: the tile goes graphite and the blue moves onto the face.
# Recolour only the gradients -- geometry, filters and paths are untouched.
# The match strings are exact on purpose. A MacTahoe release that changes this
# markup fails loudly, but the patch is all-or-nothing and the rest of the build
# goes on: the dark Finder just stays MacTahoe's own until the strings are fixed.
# $1: the dark theme's file-manager.svg.
step_5c() {
if ! python3 - "$1" <<'PYEOF'
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
}

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
# whites, greys and blacks. Every coloured tile becomes a brand tile, like step
# 5's (see BRAND_TILE_*). Every edit is re-rendered: the tile interior must
# come out unchanged (bar the tile's own colour) and art poking outside the
# tile must survive, or the icon stays exactly as MacTahoe drew it.
# Runs before 5e's rim, so the dark theme's untouched SVGs are still identical
# to the light theme's and reuse its result instead of being worked out again.
# $1, $2: the light and dark themes' apps/scalable, $3: the keep-dark list.
step_5d() {
python3 - "$1" "$2" \
         "$LIGHT_TILE_TOP" "$LIGHT_TILE_BOT" "$TILE_SHADOW_ALPHA" "$TILE_SHADOW_BLUR" \
         "$TILE_SHADOW_DROP" "$TILE_OUTLINE_ALPHA" "$3" \
         "$DARK_TILE_TOP" "$DARK_TILE_BOT" "$DARK_TILE_HL" "$DARK_TILE_HL_SPAN" \
         "$BRAND_TILE_HL_LIGHT" "$BRAND_TILE_HL_DARK" <<'PYEOF'
import base64, colorsys, functools, hashlib, io, math, os, re, subprocess, sys, xml.parsers.expat
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

# --- coloured tile -> brand tile ---------------------------------------------
# A tile whose paint is coloured (a brand colour, or a tinted neutral that
# standard() leaves alone) is repainted the way step 5 paints a brand tile: its
# colour as a Tahoe ramp, lighter at the top in the light theme and deep in the
# dark one, with a sheen, and its neutral art toned to that colour (ink to a
# deep shade; paper to white in light, to a pale tint in dark). A tile of two or
# more hues is a design: its own gradient stays, deepened stop by stop in dark,
# under the same sheen. 5e adds the corner glass. Every edit is checked by
# rendering, and an icon that fails a check keeps MacTahoe's own tile.
BRAND_HL = {'light': float(sys.argv[14]), 'dark': float(sys.argv[15])}
SPAN = DHL_SPAN
SINGLE_HUE = 0.25          # circular std of the tile's hue, radians

def hls(c, l=None, dl=0.0, ds=0.0, dh=0.0):
    h, ll, s = colorsys.rgb_to_hls(*(v / 255 for v in c))
    ll = l if l is not None else ll + dl
    r = colorsys.hls_to_rgb((h + dh) % 1, min(1, max(0, ll)), min(1, max(0, s + ds)))
    return tuple(round(v * 255) for v in r)

def brand_palette(b, variant):
    """(ramp top, ramp bottom, ink, paper): step 5's brand_palette, kept equal."""
    if variant == 'light':
        top, bot = hls(b, dl=.08, ds=.04, dh=-.012), hls(b, dl=-.10, dh=.012)
        ink, paper = hls(b, l=.16, ds=.1), HI
    else:
        top_l = min(.26, colorsys.rgb_to_hls(*(v / 255 for v in b))[1])
        top, bot = hls(b, l=top_l, ds=-.05), hls(b, l=max(.06, top_l - .12), ds=-.1)
        ink, paper = hls(b, l=.07), tuple(round(v + (255 - v) * .72) for v in b)
    return top, bot, ink, paper

def sheen_at(variant, t):
    return BRAND_HL[variant] * max(0.0, 1.0 - t / SPAN)

def brand_at(pal, variant, t):
    col = [round(a + (c - a) * t) for a, c in zip(pal[0], pal[1])]
    a = sheen_at(variant, t)
    return tuple(round(c + (255 - c) * a) for c in col)

def deepen(c):
    """a stop of a many-hued tile, in the dark theme: as deep as the brand ramp
    (step 5's deepen, kept equal)."""
    return hls(c, l=max(.06, min(.26, colorsys.rgb_to_hls(*(v / 255 for v in c))[1]) - .06),
               ds=-.08)

def row_t(y):
    return min(max((y + 0.5 - 4 * K) / (56 * K), 0.0), 1.0)

def neutral(c):
    """1 for black, white and greys up to a chroma of 0.10, 0 from 0.22."""
    return 1.0 - min(max(((max(c) - min(c)) / 255 - 0.10) / 0.12, 0.0), 1.0)

def ink_map(ink, paper):
    """neutral colours onto the ink -> paper ramp by luma; colour stays."""
    def f(c):
        w = neutral(c)
        if w <= 0.0:
            return tuple(c)
        t = min(max((luma(c) - 0.05) / 0.85, 0.0), 1.0)
        return tuple(round(v + (i + (p - i) * t - v) * w) for v, i, p in zip(c, ink, paper))
    return f

INSIDE_PTS = [(x, y) for y in range(0, N, 2) for x in range(0, N, 2) if IN[x, y] == 255]

def cubic(x, y):
    u, v = (x - N / 2) / (N / 2), (y - N / 2) / (N / 2)
    return (1.0, u, v, u * u, v * v, u * v, u * u * u, v * v * v, u * u * v, u * v * v)

def lsq(pts):
    """per-channel least-squares cubic surface through (x, y, rgb) points."""
    n = 10
    a = [[0.0] * n for _ in range(n)]
    b = [[0.0] * n for _ in range(3)]
    for x, y, c in pts:
        t = cubic(x, y)
        for i in range(n):
            for j in range(n):
                a[i][j] += t[i] * t[j]
            for k in range(3):
                b[k][i] += t[i] * c[k]
    out = []
    for k in range(3):
        m = [row[:] + [b[k][i]] for i, row in enumerate(a)]
        for c in range(n):
            p = max(range(c, n), key=lambda r: abs(m[r][c]))
            m[c], m[p] = m[p], m[c]
            if abs(m[c][c]) < 1e-12:
                return None
            for r in range(n):
                if r != c:
                    f = m[r][c] / m[c][c]
                    m[r] = [u - f * w for u, w in zip(m[r], m[c])]
        out.append([m[i][n] / m[i][i] for i in range(n)])
    return out

def tile_paint(t_el):
    """(brand colour, many-hued?) of the tile drawn on its own, or (None, why):
    whatever shows through a notch in it (MacTahoe's page curls) is art. The
    tile must cover most of the squircle, be a smooth gradient (not a picture
    or a pattern) and be coloured; the brand colour is its colour at the
    centre."""
    px = t_el.load()
    pts = [(x, y, px[x, y][:3]) for x, y in INSIDE_PTS if px[x, y][3] >= 250]
    if len(pts) < 0.75 * len(INSIDE_PTS):
        return None, 'holes'
    fit = lsq(pts)
    if fit is None:
        return None, 'texture'
    on = sum(1 for x, y, c in pts
             if max(abs(c[k] - sum(u * w for u, w in zip(fit[k], cubic(x, y))))
                    for k in range(3)) <= 10)
    if on < 0.9 * len(pts):
        return None, 'texture'
    mid = [c for x, y, c in pts if abs(x - N / 2) <= 12 and abs(y - N / 2) <= 12]
    if not mid:
        return None, 'holes'
    b = tuple(round(sum(c[i] for c in mid) / len(mid)) for i in range(3))
    if max(b) - min(b) < 16:
        return None, 'neutral'
    hs = [colorsys.rgb_to_hsv(*(v / 255 for v in c))[0]
          for x, y, c in pts if max(c) - min(c) >= 24]
    if not hs:
        return b, False
    sx = sum(math.cos(2 * math.pi * h) for h in hs) / len(hs)
    sy = sum(math.sin(2 * math.pi * h) for h in hs) / len(hs)
    r = min(max(math.hypot(sx, sy), 1e-9), 1.0)
    return b, math.sqrt(max(0.0, -2 * math.log(r))) > SINGLE_HUE

# --- paints as the renderer resolves them -------------------------------------
RULE = re.compile(r'([^{}]+)\{([^}]*)\}')
DECL = re.compile(r'(?:^|;)\s*([\w-]+)\s*:\s*([^;]+)')
NAMED = {'white': (255, 255, 255), 'black': (0, 0, 0), 'gray': (128, 128, 128),
         'grey': (128, 128, 128), 'silver': (192, 192, 192)}
INHERITED = {'fill': True, 'stroke': True, 'color': True,
             'stop-color': False, 'stop-opacity': False}
INITIAL = {'fill': 'black', 'stroke': 'none', 'color': 'black',
           'stop-color': 'black', 'stop-opacity': '1'}

def css_rules(b, root):
    """class, id and type selectors of the file's <style> sheets (anything more
    elaborate is ignored; the pinned render in brandify catches what that
    misses)."""
    rules = []
    for n in preorder(root):
        if n.tag != 'style':
            continue
        text = re.sub(r'<!\[CDATA\[|\]\]>|<[^>]*>', '',
                      b[n.start:n.end].decode('utf-8', 'replace'))
        for m in RULE.finditer(text):
            props = {d.group(1).strip(): d.group(2).strip() for d in DECL.finditer(m.group(2))}
            for sel in (s.strip() for s in m.group(1).split(',')):
                if re.fullmatch(r'\.[\w-]+', sel):
                    rules.append((1, len(rules), 'class', sel[1:], props))
                elif re.fullmatch(r'#[\w-]+', sel):
                    rules.append((2, len(rules), 'id', sel[1:], props))
                elif re.fullmatch(r'[a-zA-Z]+', sel):
                    rules.append((0, len(rules), 'tag', sel, props))
    return rules

def declared(n, prop, rules):
    """n's own value for prop: style attribute, then CSS, then the attribute."""
    v = None
    for m in DECL.finditer(n.attrs.get('style', '')):
        if m.group(1) == prop:
            v = m.group(2).strip()
    if v is not None:
        return v
    best, classes = None, n.attrs.get('class', '').split()
    for spec, order, kind, name, props in rules:
        if prop in props and ((kind == 'class' and name in classes)
                              or (kind == 'id' and n.attrs.get('id') == name)
                              or (kind == 'tag' and n.tag == name)):
            if best is None or (spec, order) >= best[:2]:
                best = (spec, order, props[prop])
    return best[2] if best else n.attrs.get(prop)

def computed(n, prop, rules):
    while n is not None:
        v = declared(n, prop, rules)
        if v is not None and v != 'inherit':
            return v
        if v is None and not INHERITED[prop]:
            return INITIAL[prop]
        n = n.parent
    return INITIAL[prop]

def colour(v):
    v = v.strip()
    if re.fullmatch(r'#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})', v):
        return rgb(v)
    if v.lower() in NAMED:
        return NAMED[v.lower()]
    m = re.fullmatch(r'rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)', v)
    return tuple(int(g) for g in m.groups()) if m else None

def paint(n, prop, rules):
    """('none',), ('rgb', colour), ('url', id) or ('?', raw value)."""
    v = computed(n, prop, rules)
    if v in ('none', 'transparent'):
        return ('none',)
    if v == 'currentColor':
        v = computed(n, 'color', rules)
    m = re.match(r'\s*url\(\s*#([^)\s]+)\s*\)', v)
    if m:
        return ('url', m.group(1))
    c = colour(v)
    return ('rgb', c) if c is not None else ('?', v)

def with_style(tag, prop, value):
    """a start tag with prop:value in its style, which beats a presentation
    attribute and a CSS class."""
    m = STYLE.search(tag)
    pv = prop.encode() + b':' + value.encode()
    if m:
        body = m.group(2)
        f = re.search(rb'(?:^|;)\s*' + re.escape(prop.encode()) + rb'\s*:\s*([^;]*)', body)
        if f:
            body = body[:f.start(1)] + value.encode() + body[f.end(1):]
        else:
            body = (body.rstrip().rstrip(b';') + b';' if body.strip() else b'') + pv
        return tag[:m.start(2)] + body + tag[m.end(2):]
    at = len(tag) - (2 if tag.endswith(b'/>') else 1)
    return tag[:at] + b' style="' + pv + b'"' + tag[at:]

GEOM = {'linearGradient': ('x1', 'y1', 'x2', 'y2'),
        'radialGradient': ('cx', 'cy', 'r', 'fx', 'fy', 'fr')}
COMMON = ('gradientUnits', 'gradientTransform', 'spreadMethod')

def copy_gradient(root, gid, newid, f, rules, pin=False):
    """A gradient with every stop colour passed through f, written out whole
    (attributes it inherits through href resolved, no href left) so the
    original stays as it is for whatever else uses it. '' when f changes no
    stop, None when it can't be copied."""
    ch, g = [], by_id(root, gid)
    while g is not None and len(ch) < 8 and g.tag in GEOM:
        ch.append(g)
        h = g.attrs.get('xlink:href') or g.attrs.get('href') or ''
        g = by_id(root, h[1:]) if h.startswith('#') else None
    if not ch:
        return None
    attrs = {}
    for a in COMMON + GEOM[ch[0].tag]:
        for n in ch:
            if a in n.attrs and (a in COMMON or n.tag == ch[0].tag):
                attrs[a] = n.attrs[a]
                break
    holder = next((n for n in ch if any(k.tag == 'stop' for k in n.kids)), None)
    if holder is None:
        return None
    stops, moved_any = [], False
    for s in (k for k in holder.kids if k.tag == 'stop'):
        c = colour(computed(s, 'stop-color', rules))
        if c is None:
            return None
        nc = f(c)
        moved_any |= nc != c
        stops.append('<stop offset="%s" stop-color="#%02x%02x%02x" stop-opacity="%s"/>'
                     % ((s.attrs.get('offset', '0'),) + tuple(c if pin else nc)
                        + (computed(s, 'stop-opacity', rules),)))
    if not moved_any:
        return ''
    head = ' '.join('%s="%s"' % (a, v.replace('"', '&quot;')) for a, v in attrs.items())
    return '<%s id="%s" %s>%s</%s>' % (ch[0].tag, newid, head, ''.join(stops), ch[0].tag)

LEAVES = {'path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon',
          'text', 'tspan', 'use', 'image'}
NOT_ART = {'defs', 'mask', 'clipPath', 'filter', 'pattern', 'symbol', 'marker',
           'style', 'title', 'desc', 'metadata'}

def art_leaves(root, spans):
    """the shapes in spans (whole elements), this script's own markup aside."""
    by_start = {n.start: n for n in preorder(root)}
    out = []
    for s, _ in spans:
        stack = [by_start[s]] if s in by_start else []
        while stack:
            x = stack.pop()
            if x.tag in NOT_ART or (x.attrs.get('id') or '').startswith('tahoe'):
                continue
            if x.tag in LEAVES:
                out.append(x)
            if x.tag not in LEAVES or x.tag == 'text':
                stack += x.kids
    return out

def recolour(b, root, nodes, f, tag_id, pin=False):
    """-> (edits, extra markup, blind spans): every paint of nodes that f
    changes, written into the node's style -- recoloured, or with pin as it
    already is, which must render exactly like the original. Blind: shapes whose
    paint can't be recoloured here (bitmaps, <use>, values this can't read)."""
    rules = css_rules(b, root)
    edits, extra, copies, blind = [], [], {}, []
    for n in nodes:
        if n.tag in ('image', 'use'):
            blind.append((n.start, n.end))
            continue
        e = tag_end(b, n.start)
        tag = new = b[n.start:e]
        for prop in ('fill', 'stroke'):
            p = paint(n, prop, rules)
            if p[0] == 'rgb' and f(p[1]) != p[1]:
                new = with_style(new, prop, '#%02x%02x%02x' % (p[1] if pin else f(p[1])))
            elif p[0] == 'url':
                if p[1] not in copies:
                    nid = '%s%d' % (tag_id, len(copies))
                    copies[p[1]] = (nid, copy_gradient(root, p[1], nid, f, rules, pin))
                    extra.append(copies[p[1]][1] or '')
                nid, mk = copies[p[1]]
                if mk:
                    new = with_style(new, prop, 'url(#%s)' % nid)
                elif mk is None:
                    blind.append((n.start, n.end))
            elif p[0] == '?':
                blind.append((n.start, n.end))
        if new != tag:
            edits.append((n.start, e, new))
    return edits, ''.join(extra), blind

def splice(b, edits, extra=''):
    """b with start tags replaced or markup inserted ((s, e, bytes) each, e == s
    to insert) and extra appended inside the root."""
    out, last = [], 0
    for s, e, t in sorted(edits, key=lambda t: (t[0], t[1])):
        out += [b[last:s], t]
        last = e
    nb = b''.join(out) + b[last:]
    at = nb.rstrip().rfind(b'</svg>')
    return nb[:at] + extra.encode() + nb[at:]

def band_off(im, exp, band):
    """mean distance (0-255) between im and the expected tile along band (the
    band inside the squircle's edge, where the tile paints it itself)."""
    d = functools.reduce(ImageChops.lighter,
                         ImageChops.difference(im.convert('RGB'), exp).split())
    hist = ImageChops.multiply(d, band).histogram()
    return sum(i * n for i, n in enumerate(hist)) / max(band.histogram()[255], 1)

def geometries(root):
    """gradient geometries to try for a vertical ramp over the tile: its bounding
    box either way up, then the 64-grid in the file's user space."""
    sp = user_space(root)
    if sp is None:
        return []
    x = sp[2] + 32 * sp[0]
    return ['x1="0" y1="0" x2="0" y2="1"', 'x1="0" y1="1" x2="0" y2="0"',
            'x1="%.6g" y1="%.6g" x2="%.6g" y2="%.6g" gradientUnits="userSpaceOnUse"'
            % (x, sp[3] + 4 * sp[1], x, sp[3] + 60 * sp[1])]

def ramp_tile(b, root, tile, later, pal, variant, band):
    """-> (edits, extra, tile-only render): the tile on the brand ramp."""
    exp = Image.new('RGB', (N, N))
    px = exp.load()
    for y in range(N):
        col = brand_at(pal, variant, row_t(y))
        for x in range(N):
            px[x, y] = col
    ts = [SPAN * i / 8 for i in range(9)] + [1.0]
    stops = ''.join('<stop offset="%.4g" stop-color="#%02x%02x%02x"/>'
                    % ((t,) + brand_at(pal, variant, t)) for t in ts)
    s, e = tile.start, tag_end(b, tile.start)
    edit = (s, e, with_style(b[s:e], 'fill', 'url(#tahoeBrand)'))
    shift = len(edit[2]) - (e - s)
    for geom in geometries(root):
        extra = '<linearGradient id="tahoeBrand" %s>%s</linearGradient>' % (geom, stops)
        t = render(cut(splice(b, [edit], extra), [(a + shift, z + shift) for a, z in later]))
        if t is not None and opaque(t) and band_off(t, exp, band) <= 3:
            return [edit], extra, t
    return None

def sheened(im, variant):
    """im under the brand sheen, row by row."""
    out = im.convert('RGB')
    px = out.load()
    for y in range(N):
        a = sheen_at(variant, row_t(y))
        for x in range(N):
            px[x, y] = tuple(round(v + (255 - v) * a) for v in px[x, y])
    return out

def sheen_tile(b, root, tile, later, t0, variant, band):
    """-> (edits, extra, tile-only render): a many-hued tile keeps its own
    gradient (deepened stop by stop in the dark theme) and gets the sheen as a
    copy of itself painted white -> clear, just above it."""
    edits, extra, under = [], '', t0
    if variant == 'dark':
        rules = css_rules(b, root)
        p = paint(tile, 'fill', rules)
        if p[0] != 'url':
            return None
        s, e = tile.start, tag_end(b, tile.start)
        edit = (s, e, with_style(b[s:e], 'fill', 'url(#tahoeDeep)'))
        sh = len(edit[2]) - (e - s)
        bare = [(a + sh, z + sh) for a, z in later]
        # the copy, its stops left as they are, must draw the very same tile
        pin = copy_gradient(root, p[1], 'tahoeDeep', deepen, rules, pin=True)
        mk = copy_gradient(root, p[1], 'tahoeDeep', deepen, rules)
        if not mk:
            return None
        tp = render(cut(splice(b, [edit], pin), bare))
        under = render(cut(splice(b, [edit], mk), bare))
        if tp is None or under is None or changed_share(tp, t0, 3) > 0.002:
            return None
        edits, extra = [edit], mk
    exp = sheened(under, variant)
    dup = b[tile.start:tile.end]
    e = tag_end(dup, 0)
    head = re.sub(rb'\sid\s*=\s*"[^"]*"', b'', dup[:e], count=1)
    dup = with_style(with_style(head, 'fill', 'url(#tahoeSheen)'), 'stroke', 'none') + dup[e:]
    ins = (tile.end, tile.end, dup)
    shift = sum(len(t) - (z - a) for a, z, t in edits) + len(dup)
    for geom in geometries(root):
        grad = ('<linearGradient id="tahoeSheen" %s><stop offset="0" stop-color="#fff" '
                'stop-opacity="%.4g"/><stop offset="%.4g" stop-color="#fff" stop-opacity="0"/>'
                '</linearGradient>' % (geom, BRAND_HL[variant], SPAN))
        nb = splice(b, edits + [ins], extra + grad)
        t = render(cut(nb, [(a + shift, z + shift) for a, z in later]))
        if t is not None and opaque(t) and band_off(t, exp, band) <= 3:
            return edits + [ins], extra + grad, t
    return None

def changed_share(a, b, tol):
    return sum(1 for v in changed(a, b, tol).get_flattened_data() if v) / (N * N)

def moved_share(r, orig, t0, t1, slack=10):
    """share of the squircle that moved further than the tile under it did."""
    po, pt0, pt1, pr = orig.load(), t0.load(), t1.load(), r.load()
    bad = 0
    for x, y in INSIDE_PTS:
        allow = max(abs(u - v) for u, v in zip(pt1[x, y][:3], pt0[x, y][:3]))
        bad += max(abs(u - v) for u, v in zip(pr[x, y][:3], po[x, y][:3])) > allow + slack
    return bad / len(INSIDE_PTS)

SHIFTS = ((2, 0), (0, 2))

def edge_pairs(im):
    """{(p, shift): luma step} for the luma steps of 0.15 and up between pixels
    2 px apart inside the squircle."""
    L = im.convert('L').load()
    out = {}
    for x, y in INSIDE_PTS:
        for dx, dy in SHIFTS:
            q = (x + dx, y + dy)
            if q[0] < N and q[1] < N and IN[q] == 255:
                d = abs(L[x, y] - L[q])
                if d >= 38:
                    out[(x, y), (dx, dy)] = d
    return out

def legible(r, orig, art):
    """The outlines that made the icon read still show: three in five of the
    original's luma steps keep a third of their contrast (and 0.08); or the art
    is a panel (JetBrains' black square, Resolve's face) whose own content keeps
    reading, even if its edge melts into the deep tile. Step 5 tests its brand
    tiles the same way."""
    e0 = edge_pairs(orig)
    if len(e0) < 40:
        return True
    L = r.convert('L').load()
    kept = inner = inner_kept = 0
    for (p, (dx, dy)), d in e0.items():
        q = (p[0] + dx, p[1] + dy)
        ok = abs(L[p] - L[q]) >= max(20, d / 3)
        kept += ok
        if p in art and q in art:
            inner += 1
            inner_kept += ok
    if kept >= 0.6 * len(e0):
        return True
    return inner >= 0.25 * len(e0) and inner_kept >= 0.8 * inner

def edge_ring(b, root):
    """Spans of the shapes painting MacTahoe's white edge ring (an all-white
    ramp, opaque at both ends and dim in the middle, through a gradient or one
    that hrefs it). On a deep tile it shows as a hard white outline, which is
    why 5b drops it from the tiles it darkens; the dark brand tile drops it too
    (GitHub Desktop's)."""
    rules = css_rules(b, root)
    grads = [n for n in preorder(root) if n.tag in GEOM]

    def opacity(s):
        v = computed(s, 'stop-opacity', rules).strip()
        try:
            return float(v[:-1]) / 100 if v.endswith('%') else float(v)
        except ValueError:
            return 1.0
    ring = set()
    for g in grads:
        stops = [k for k in g.kids if k.tag == 'stop']
        if len(stops) < 3 or not g.attrs.get('id'):
            continue
        if any(colour(computed(s, 'stop-color', rules)) != (255, 255, 255) for s in stops):
            continue
        ops = [opacity(s) for s in stops]
        if ops[0] >= 0.9 and ops[-1] >= 0.9 and min(ops) < 0.6:
            ring.add(g.attrs['id'])
    users = set(ring)
    for g in grads:
        h = g.attrs.get('xlink:href') or g.attrs.get('href') or ''
        if h[1:] in ring and g.attrs.get('id'):
            users.add(g.attrs['id'])
    return [(n.start, n.end) for n in preorder(root) if n.tag in LEAVES and users
            and any(p[0] == 'url' and p[1] in users
                    for p in (paint(n, 'fill', rules), paint(n, 'stroke', rules)))]

_ZONE = ImageChops.subtract(squircle(0), squircle(-6))   # the tile's outer 3 units
ZONE, ZONE_AREA = _ZONE.load(), _ZONE.histogram()[255]
DEEP = squircle(-6).load()                                # the rest of it

def edge_shapes(b, root):
    """Spans of white shapes that only light the tile's edge: MacTahoe's other
    edge highlight, a blurred white ring (calc's, Health's). By rendering: at
    most 15% of the shape's footprint may reach past the tile's outer 3 units
    (its blur spills outwards too), and it must run along a good part of it."""
    full = render(b)
    if full is None:
        return []
    rules = css_rules(b, root)
    out = []
    for n in art_leaves(root, [(root.start, root.end)]):
        if not any(p[0] == 'rgb' and min(p[1]) >= 235
                   for p in (paint(n, 'fill', rules), paint(n, 'stroke', rules))):
            continue
        wo = render(cut(b, [(n.start, n.end)]))
        fp = points(changed(full, wo, 8)) if wo is not None else []
        deep = sum(1 for p in fp if DEEP[p] == 255)
        if fp and deep <= 0.15 * len(fp) and \
                sum(1 for p in fp if ZONE[p] == 255) >= 0.2 * ZONE_AREA:
            out.append((n.start, n.end))
    return out

def drop_edge(b, root):
    """b without its white edge ring or edge highlight shapes, and its tree."""
    spans = edge_ring(b, root)
    if spans:
        b = cut(b, spans)
        root = parse(b)
    spans = edge_shapes(b, root) if root is not None else []
    if spans:
        b = cut(b, spans)
        root = parse(b)
    return b, root

def brandify(b, variant):
    """-> (bytes, how) with the tile made a brand tile, or (None, why)."""
    if b'tahoeBrand' in b or b'tahoeSheen' in b:
        return None, 'done'
    root = parse(b)
    if root is None:
        return None, 'shape'
    if variant == 'dark':
        b, root = drop_edge(b, root)
        if root is None:
            return None, 'shape'
    orig = render(b)
    if not opaque(orig):
        return None, 'shape'
    path = find_tile(b, root)
    if not path:
        return None, 'shape'
    tile, later, glass = tile_parts(b, path)
    if tile is None or glass is not None:
        return None, 'paint'
    t0 = render(cut(b, later))
    chain, n = [], tile
    while n is not root:
        chain.append(n)
        n = n.parent
    before = siblings(chain, after=False)
    t_el = render(cut(b, before + later))            # the tile, nothing else
    if t0 is None or t_el is None:
        return None, 'paint'
    bc, many = tile_paint(t_el)
    if bc is None:
        return None, many
    own = ImageChops.multiply(over(t_el.getchannel('A'), 249), INSIDE)
    band = ImageChops.multiply(BAND_IM, own)
    if band.histogram()[255] < 0.6 * BAND_AREA:
        return None, 'holes'                      # the tile must own its edge
    pal = brand_palette(bc, variant)
    done = sheen_tile(b, root, tile, later, t0, variant, band) if many else \
        ramp_tile(b, root, tile, later, pal, variant, band)
    if done is None:
        return None, 'geom'
    tile_edits, tile_extra, t1 = done
    out = splice(b, tile_edits, tile_extra)
    r = render(out)
    if r is None or hits(changed(r, orig, 3), FAR):
        return None, 'far'                        # what got repainted was not the tile
    if moved_share(r, orig, t0, t1) > 0.005:
        return None, 'moved'                      # art blended with the tile
    how = 'many' if many else 'ramp'
    # the art: whatever differs from the tile drawn on its own
    region = points(ImageChops.multiply(changed(orig, t_el, 24), INSIDE))
    art = set(region)
    po = orig.load()
    neut = [po[p][:3] for p in region if neutral(po[p][:3]) >= 1.0]
    greys = sum(1 for c in neut if 0.18 <= luma(c) <= 0.70)
    plans = []
    if neut and greys < 0.5 * len(neut):     # ink and paper, not grey material
        plans.append((ink_map(pal[2], pal[3]), '+ink'))
    if variant == 'dark':
        # dark art straight on the tile (Spotify's waves, a grey elephant)
        # sinks into the deep tile: then, and only then, the tone map runs the
        # other way round, whatever the art is
        plans.append((ink_map(pal[3], pal[2]), '+ink-inverted'))
    # what gets toned: the shapes drawn over the tile, and those that show
    # through a notch in it (drawn before it, yet inside the squircle: not a
    # shadow)
    nodes = art_leaves(root, later)
    for n in art_leaves(root, before):
        if n.tag == 'image':
            continue
        fp = points(changed(t0, render(cut(b, later + [(n.start, n.end)])), 8))
        if fp and sum(1 for p in fp if IN[p] == 255) >= 0.5 * len(fp):
            nodes.append(n)
    for f, tag in plans:
        if tag == '+ink-inverted' and legible(r, orig, art):
            break
        pins, pextra, blind = recolour(b, root, nodes, f, 'tahoeInk', pin=True)
        edits, extra, _ = recolour(b, root, nodes, f, 'tahoeInk')
        if not edits:
            continue
        # the paints as read must be the paints drawn
        rp = render(splice(b, pins, pextra))
        if rp is None or changed_share(rp, orig, 3) > 0.002:
            how += ' (ink unread)'
            break
        # and what can't be recoloured must not be art the tone map moves
        if blind:
            wo = render(cut(b, blind))
            if wo is None:
                break
            missed = sum(1 for p in points(ImageChops.multiply(changed(orig, wo, 24), INSIDE))
                         if neutral(po[p][:3]) >= 0.5
                         and max(abs(u - v) for u, v in zip(f(po[p][:3]), po[p][:3])) > 20)
            if missed > 16:
                how += ' (ink blind)'
                break
        cand = splice(b, tile_edits + edits, tile_extra + extra)
        rc = render(cand)
        if rc is None or not legible(rc, orig, art):
            continue                           # the other way round, or no ink
        out, r = cand, rc
        how += tag
        break
    if not legible(r, orig, art):
        return None, 'illegible'
    return out, how

# --- white tile -> graphite (dark theme) ---------------------------------------
# 5b turns MacTahoe's usual white tile gradients graphite, but not white tiles
# painted any other way (Chrome's, Google's, WhatsApp's, ...), nor those whose
# dark art would sink into the graphite (it keeps them white). Here, in the dark
# theme, a white tile left white goes graphite after all: as it is when its art
# still reads there, or with its neutral art turned round, dark glyphs light,
# like the brand pass's inverted ink (Wikipedia's W, Notion's N). Either way at
# most 30% of the tile may stay white, or it is a white card on a dark tile and
# keeps its white tile instead.
WHITE_INK, WHITE_PAPER = (18, 18, 18), (255, 255, 255)    # brand_palette's, for white

def white_share(im):
    px = im.load()
    return sum(1 for p in INSIDE_PTS
               if luma(px[p]) >= 0.85 and max(px[p][:3]) - min(px[p][:3]) <= 20) / len(INSIDE_PTS)

def darken_white(b):
    """-> (bytes, 'graphite' | 'graphite-inverted') or (None, why)."""
    if b'tahoeTile' in b:
        return None, 'standard'
    root = parse(b)
    if root is None:
        return None, 'shape'
    orig = render(b)
    if not opaque(orig):
        return None, 'shape'
    lum, s = rim(orig)
    if lum <= 0.8 or s >= 0.12:
        return None, 'not-white'
    nb, root = drop_edge(b, root)
    if nb is not b:
        b, orig = nb, render(nb)
        if root is None or orig is None:
            return None, 'paint'
    path = find_tile(b, root)
    if not path:
        return None, 'shape'
    tile, later, glass = tile_parts(b, path)
    if tile is None:
        return None, 'paint'
    t0 = render(cut(b, later))
    if t0 is None:
        return None, 'paint'
    px = t0.load()
    ch = sorted(max(p[:3]) - min(p[:3]) for y in range(0, N, 2) for x in range(0, N, 2)
                if BAND[x, y] >= 200 and (p := px[x, y])[3] >= 250)
    if not ch or ch[int(0.9 * len(ch))] > 12:
        return None, 'not-white'                 # a tinted tile: the brand pass's
    nb, t1 = restyle(b, root, tile, later, glass, 'dark')
    if nb is None:
        return None, 'paint'
    after = render(nb)
    if after is None or hits(changed(after, orig, 3), FAR):
        return None, 'paint'
    if moved_share(after, orig, t0, t1) > 0.005:
        return None, 'paint'                     # art blended with the tile
    art = set(points(ImageChops.multiply(changed(orig, t0, 24), INSIDE)))
    plain = legible(after, orig, art) and white_share(after) <= 0.3
    # turned round, it may read much better (the calendar's dark 1, left as a
    # thin outline on graphite, comes out white): then that one, else the plain
    # graphite tile, the smaller change
    inv = invert_white(nb, after, orig, art)
    if inv is not None and (not plain or edges_kept(inv[1], orig) >= edges_kept(after, orig) + 0.15):
        return inv[0], 'graphite-inverted'
    return (nb, 'graphite') if plain else (None, 'unreadable')

def edges_kept(r, orig):
    """share of the original's luma steps that keep a third of their contrast
    (and 0.08) in r: legible()'s first measure."""
    e0 = edge_pairs(orig)
    if not e0:
        return 1.0
    L = r.convert('L').load()
    return sum(1 for (p, (dx, dy)), d in e0.items()
               if abs(L[p] - L[p[0] + dx, p[1] + dy]) >= max(20, d / 3)) / len(e0)

def invert_white(nb, after, orig, art):
    """(bytes, render) of nb (a white tile made graphite) with its neutral
    paints turned round, dark glyphs light, or None when that can't be done or
    doesn't read."""
    f = ink_map(WHITE_PAPER, WHITE_INK)
    nroot = parse(nb)
    npath = find_tile(nb, nroot)
    if not npath:
        return None
    _, nlater, _ = tile_parts(nb, npath)
    nodes = art_leaves(nroot, nlater)
    pins, pextra, blind = recolour(nb, nroot, nodes, f, 'tahoeInk', pin=True)
    edits, extra, _ = recolour(nb, nroot, nodes, f, 'tahoeInk')
    if not edits:
        return None
    # the paints as read must be the paints drawn, and what can't be recoloured
    # must not be art the tone map moves (as in brandify)
    rp = render(splice(nb, pins, pextra))
    if rp is None or changed_share(rp, after, 3) > 0.002:
        return None
    if blind:
        wo = render(cut(nb, blind))
        if wo is None:
            return None
        pa = after.load()
        missed = sum(1 for p in points(ImageChops.multiply(changed(after, wo, 24), INSIDE))
                     if neutral(pa[p][:3]) >= 0.5
                     and max(abs(u - v) for u, v in zip(f(pa[p][:3]), pa[p][:3])) > 20)
        if missed > 16:
            return None
    cand = splice(nb, edits, extra)
    rc = render(cand)
    if rc is None or not legible(rc, orig, art) or white_share(rc) > 0.3:
        return None
    return cand, rc

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
    """-> (bytes, 'light' | 'dark') or (None, why): standard(b), worked out
    once for a file the two themes share."""
    key = hashlib.sha1(b).digest()
    if key not in memo:
        memo[key] = standard(b)
    return memo[key]

def retile(b, variant):
    """-> (bytes, kind) with the tile on the common ramp (kind 'light' or
    'dark'), a white one made graphite in the dark theme ('graphite' or
    'graphite-inverted'), or made a brand tile ('brand', or 'brand-inverted'
    when its dark art had to be turned light); or (None, why)."""
    if variant == 'dark':
        try:
            nb, how = darken_white(b)
        except Exception as e:                # one odd file must not stop the build
            print(f'  graphite tile failed ({type(e).__name__}: {e}); white kept',
                  file=sys.stderr)
            nb, how = None, 'error'
        if nb is not None:
            return nb, how
        if how == 'unreadable':
            return standardise(b)[0], 'kept-white'
    nb, which = standardise(b)
    if nb is not None or which != 'brand':
        return nb, which
    try:
        nb, how = brandify(b, variant)
    except Exception as e:                    # one odd file must not stop the build
        print(f'  brand tile failed ({type(e).__name__}: {e}); MacTahoe\'s kept',
              file=sys.stderr)
        return None, 'error'
    if nb is None:
        return None, how
    return nb, 'brand-inverted' if 'inverted' in how else 'brand'

def do_light(name):
    p = os.path.join(light_dir, name)
    b = read(p)
    s, why = reshadow(b)
    if s is None:
        # MacTahoe's shadow stays, but the tile can still take the common ramp
        # or become a brand tile
        std, which = retile(b, 'light') if why == 'kept' else (None, None)
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
        std, which = retile(s, 'light')
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
    std, which = retile(s if s is not None else b, 'dark') \
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
gi = dark_std.get('graphite-inverted', 0)
print(f'Dark theme: {dark_std.get("graphite", 0) + gi} more white tiles made graphite '
      f'({gi} with their dark art turned light); {dark_std.get("kept-white", 0)} kept '
      f'white, their art would not read on graphite.')
inv = dark_std.get('brand-inverted', 0)
print(f'Brand tiles: {light_std.get("brand", 0)} coloured tiles in the light theme, '
      f'{dark_std.get("brand", 0) + inv} in the dark one ({inv} with their dark art '
      f'turned light); kept MacTahoe\'s tile where the art would not read: '
      f'{light_std.get("illegible", 0)} light, {dark_std.get("illegible", 0)} dark.')
PYEOF
}

# --- 5e. Tahoe corner rim on every app tile -----------------------------------
# A 1px band just inside the squircle, lit from the top-left and bottom-right
# corners. MacTahoe bakes this into a handful of icons (Finder, Obsidian) and
# omits it everywhere else; this gives every tile the same edge: every one in
# the dark theme, and every one but the light tiles in the light theme (a white
# rim on a near-white tile is invisible; 5d gives those step 5's dark outline).
# Brand tiles (5d's tahoeBrand / tahoeSheen) take step 5's brand rim, the rest
# DARK_TILE_RIM. Runs last so it layers over 5b's re-tint, 5c's Finder and 5d.
# $1, $2: the dark and light themes' apps/scalable.
step_5e() {
python3 - "$1" "$2" \
         "$DARK_TILE_RIM" "$BRAND_TILE_RIM" <<'PYEOF'
import os, re, subprocess, sys, tempfile
from PIL import Image

dark_dir, light_dir = sys.argv[1], sys.argv[2]
RIM, BRAND_RIM = float(sys.argv[3]), float(sys.argv[4])
if RIM <= 0 and BRAND_RIM <= 0:
    print('Corner rim disabled (DARK_TILE_RIM=0, BRAND_TILE_RIM=0).')
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
 'stroke="url(#tahoeRimBR)"/></g>')                # % opacity

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

def light_tile(px):
    """the tile is a light one (mean luma 0.8 and up along its edge)."""
    return sum((0.299 * px[x, y][0] + 0.587 * px[x, y][1] + 0.114 * px[x, y][2]) / 255
               for x, y in PROBE) / len(PROBE) >= 0.8

for theme, dst_dir in (('dark', dark_dir), ('light', light_dir)):
    rimmed = brand = skipped_have = skipped_shape = skipped_light = reverted = 0
    for name in sorted(os.listdir(dst_dir)):
        p = os.path.join(dst_dir, name)
        if os.path.islink(p) or not name.endswith('.svg'):
            continue                   # aliases inherit their target's rim
        with open(p, encoding='utf-8', errors='surrogateescape') as f:
            s = f.read()
        if 'tahoeRim' in s:
            continue                   # already run over this file
        ids = set(WT.findall(s))
        if ids:
            refs = HREF.findall(s)
            if any(refs.count(i) >= 2 for i in ids):
                skipped_have += 1      # MacTahoe already lights this one
                continue
        m = SVG.search(s)
        sp = user_space(m.group(0)) if m else None
        px = render(p)
        if sp is None or not s.rstrip().endswith('</svg>') or not fills_tile(px):
            skipped_shape += 1
            continue
        if theme == 'light' and light_tile(px):
            skipped_light += 1
            continue
        is_brand = 'tahoeBrand' in s or 'tahoeSheen' in s
        opacity = BRAND_RIM if is_brand else RIM
        if opacity <= 0:
            continue
        kx, ky, ox, oy = sp
        rim = RIM_MARKUP % opacity
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
        brand += is_brand

    msg = (f'Corner rim added to {rimmed} {theme} app SVGs ({brand} brand tiles; '
           f'{skipped_have} already had one, {skipped_shape} are not full tiles'
           + (f', {skipped_light} are light tiles' if theme == 'light' else ''))
    print(msg + (f', {reverted} REVERTED - rim broke the render).' if reverted
                 else ').'))
PYEOF
}

# Build a theme directory out of layers, or find what a build changed in one.
# A later layer wins wherever two hold the same path. A symlink that points out
# of its own layer (MacTahoe-dark's apps/scalable -> ../../MacTahoe/apps/scalable,
# its top-level animations, emotes and preferences) is left out: it can only lead
# back into a layer underneath, which supplies that path as a real copy. Every
# file is copied: rsync's size-and-mtime check, used before, skipped MacTahoe-
# dark's 24 wait-cursor frames, which match the light ones in both but not in
# their pixels.
#   layers assemble DEST LAYER...      DEST must not exist yet
#   layers overlay DEST OUT LAYER...   copy into OUT every file and link of
#                                      DEST that isn't what the layers give
layers() {
python3 - "$@" <<'PYEOF'
import filecmp, os, shutil, sys

mode, dest = sys.argv[1], sys.argv[2]

def plan(roots):
    """relative path -> ('dir', None) | ('file', source) | ('link', target),
    parents before their children."""
    out = {}
    for root in roots:
        for dp, dns, fns in os.walk(root):
            for n in dns + fns:
                p = os.path.join(dp, n)
                rel = os.path.relpath(p, root)
                if os.path.islink(p):
                    t = os.readlink(p)
                    to = os.path.normpath(os.path.join(os.path.dirname(rel), t))
                    if os.path.isabs(t) or to == '..' or to.startswith('../'):
                        continue
                    entry = ('link', t)
                elif os.path.isdir(p):
                    entry = ('dir', None)
                else:
                    entry = ('file', p)
                old = out.get(rel)
                if old and old[0] == 'dir' and entry[0] != 'dir':
                    for k in [k for k in out if k.startswith(rel + '/')]:
                        del out[k]
                out[rel] = entry
    return out

if mode == 'assemble':
    os.makedirs(dest)
    for rel, (kind, v) in plan(sys.argv[3:]).items():
        p = os.path.join(dest, rel)
        if kind == 'dir':
            os.mkdir(p)
        elif kind == 'link':
            os.symlink(v, p)
        else:
            shutil.copy2(v, p)
    raise SystemExit

out_dir, want = sys.argv[3], plan(sys.argv[4:])
changed = 0
for dp, dns, fns in os.walk(dest):
    for n in dns + fns:
        p = os.path.join(dp, n)
        rel = os.path.relpath(p, dest)
        link = os.path.islink(p)
        if rel == 'index.theme' or (os.path.isdir(p) and not link):
            continue
        w = want.get(rel)
        if link and w == ('link', os.readlink(p)):
            continue
        if not link and w and w[0] == 'file' and filecmp.cmp(p, w[1], shallow=False):
            continue
        q = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(q), exist_ok=True)
        if link:
            os.symlink(os.readlink(p), q)
        else:
            shutil.copy2(p, q)
        changed += 1
# an overlay can add and replace, not delete: a build step that removed a file
# would leave it in every theme assembled from prebuilt/
gone = [rel for rel, (kind, _) in want.items()
        if kind != 'dir' and not os.path.lexists(os.path.join(dest, rel))]
if gone:
    sys.exit('%s: %d files went missing during the build, %s among them'
             % (dest, len(gone), gone[0]))
print(f'  {changed} changed files kept in {out_dir}')
PYEOF
}

# Remake prebuilt/: fresh copies of vendor/ through steps 5b-5e, keeping only
# the files that changed. keep-dark.conf plays no part (5d gets an empty list):
# prebuilt/ is the same for everyone, and keep_dark_icons applies each user's
# own list on top of it.
rebuild_prebuilt() {
  local new="$REPO_DIR/.prebuilt.new"
  echo "Rebuilding prebuilt/ from MacTahoe ${MACTAHOE_COMMIT:0:7}" \
       "(about 9 minutes on 8 cores)..."
  layers assemble "$STAGE_LIGHT" "$MACTAHOE"
  layers assemble "$STAGE_DARK" "$MACTAHOE" "$MACTAHOE_DARK"
  step_5b "$MACTAHOE/apps/scalable" "$STAGE_DARK/apps/scalable"
  step_5c "$STAGE_DARK/apps/scalable/file-manager.svg"
  step_5d "$STAGE_LIGHT/apps/scalable" "$STAGE_DARK/apps/scalable" /dev/null
  step_5e "$STAGE_DARK/apps/scalable" "$STAGE_LIGHT/apps/scalable"
  rm -rf "$new"
  mkdir -p "$new"
  layers overlay "$STAGE_LIGHT" "$new/Light" "$MACTAHOE"
  layers overlay "$STAGE_DARK" "$new/Dark" "$MACTAHOE" "$MACTAHOE_DARK"
  if [ -f "$PREBUILT/README.md" ]; then cp -p "$PREBUILT/README.md" "$new/"; fi
  printf 'inputs=%s\nmactahoe=%s\nbuilt=%s\n' \
    "$PREBUILT_ID" "$MACTAHOE_COMMIT" "$(date -u +%Y-%m-%d)" > "$new/STAMP"
  rm -rf "$PREBUILT"
  mv "$new" "$PREBUILT"
  echo "prebuilt/ remade ($PREBUILT_ID)."
}
# <<< prebuilt

# --- keep-dark.conf -----------------------------------------------------------
# The one per-user setting steps 5b-5e read. prebuilt/ has every neutral dark
# tile 5d could make light made light, so the icons listed there are redone
# from MacTahoe's own files, through 5d's light pass and 5e's rim (a second or
# two each), into the light theme being built.
keep_dark_icons() {
  [ -f "$KEEP_DARK_FILE" ] || return 0
  local n f tmp apps
  local -A files=()
  apps="$(readlink -f "$MACTAHOE/apps/scalable")"
  while IFS= read -r n || [ -n "$n" ]; do
    n="${n%%#*}"; n="${n//[[:space:]]/}"
    [ -n "$n" ] && [ -e "$apps/$n.svg" ] || continue
    f="$(readlink -f "$apps/$n.svg")"     # an alias counts for its target
    [ "${f%/*}" = "$apps" ] && files[${f##*/}]=1
  done < "$KEEP_DARK_FILE"
  [ "${#files[@]}" -gt 0 ] || return 0
  tmp=$(mktemp -d)
  mkdir "$tmp/light" "$tmp/dark"
  for f in "${!files[@]}"; do
    cp -p "$apps/$f" "$tmp/light/"
    echo "${f%.svg}"
  done > "$tmp/keep"
  step_5d "$tmp/light" "$tmp/dark" "$tmp/keep" >/dev/null
  step_5e "$tmp/dark" "$tmp/light" >/dev/null
  cp -p "$tmp/light"/*.svg "$STAGE_LIGHT/apps/scalable/"
  rm -rf "$tmp"
  echo "keep-dark.conf: ${#files[@]} icon(s) keep their dark tile in the light theme."
}

# A running Plasma session (or KDE apps elsewhere) keeps showing the icons it
# has cached until it is told the theme changed.
plasma_nudge() {
  local cur tool
  cur=$(sed -n '/^\[Icons\]/,/^\[/s/^Theme=//p' "$CONFIG_HOME/kdeglobals" 2>/dev/null \
          | head -n 1) || true
  case "$cur" in MacOS-Like-Light|MacOS-Like-Dark) ;; *) return 0 ;; esac
  for tool in "$(command -v plasma-changeicons 2>/dev/null || true)" \
              /usr/lib/plasma-changeicons /usr/libexec/plasma-changeicons \
              /usr/lib/*/libexec/plasma-changeicons; do
    if [ -n "$tool" ] && [ -x "$tool" ]; then
      "$tool" "$cur" >/dev/null 2>&1 || true
      return 0
    fi
  done
}

# --- run ----------------------------------------------------------------------
# 0. Each theme is put together in a hidden staging directory next to it:
#    MacTahoe, MacTahoe-dark's restyled contexts for the dark one, prebuilt/'s
#    app icons (or, with --rebuild, steps 5b-5e run there and remake prebuilt/),
#    index.theme and keep-dark.conf's icons. Steps 1-5 add the app tiles, and
#    only then does it replace the installed theme.
STAGE_LIGHT="$DATA_HOME/icons/.MacOS-Like-Light.new"
STAGE_DARK="$DATA_HOME/icons/.MacOS-Like-Dark.new"
WORKLIST=""

if [ "$DRYRUN" -eq 1 ]; then
  OUT_LIGHT="$THEME_LIGHT"
  OUT_DARK="$THEME_DARK"
  plan_work
  [ "${#WORK[@]}" -eq 0 ] || printf '%s\n' "${WORK[@]}"
  exit 0
fi

mkdir -p "$DATA_HOME/icons"
# One build at a time: two would race over the same staging directories.
LOCK="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/macos-like-$(id -u).lock"
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  echo "Another setup.sh is running; waiting for it to finish..."
  flock 9
fi
cleanup() {
  rm -rf "$STAGE_LIGHT" "$STAGE_DARK" "$REPO_DIR/.prebuilt.new"
  if [ -n "$WORKLIST" ]; then rm -f "$WORKLIST"; fi
}
trap cleanup EXIT
cleanup

if [ "$REBUILD" -eq 1 ]; then
  rebuild_prebuilt
else
  echo "Assembling both themes from vendor/ and prebuilt/..."
  layers assemble "$STAGE_LIGHT" "$MACTAHOE" "$PREBUILT/Light"
  layers assemble "$STAGE_DARK" "$MACTAHOE" "$MACTAHOE_DARK" "$PREBUILT/Dark"
fi
write_index "$STAGE_LIGHT" "MacOS-Like-Light" "$INHERITS_LIGHT"
write_index "$STAGE_DARK" "MacOS-Like-Dark" "$INHERITS_DARK"
keep_dark_icons

OUT_LIGHT="$STAGE_LIGHT"
OUT_DARK="$STAGE_DARK"
plan_work
step_5
for t in "$STAGE_LIGHT" "$STAGE_DARK"; do
  printf 'tiles=%s\nprebuilt=%s\n' "$TILES_ID" "$(stamp_id)" > "$t/$BUILD_INFO"
done

# --- 6. Icon caches, then the switch ------------------------------------------
# GTK reads this cache; a stale one is worse than none, so every build makes a
# fresh one. Each staging copy then replaces its theme with one rename.
for t in "$STAGE_LIGHT" "$STAGE_DARK"; do
  gtk4-update-icon-cache -q -f "$t" 2>/dev/null \
    || gtk-update-icon-cache -q -f "$t" 2>/dev/null || true
done
swap() {
  local old="${2%/*}/.${2##*/}.old"
  rm -rf "$old"
  if [ -e "$2" ]; then mv "$2" "$old"; fi
  mv "$1" "$2"
  rm -rf "$old"
}
swap "$STAGE_LIGHT" "$THEME_LIGHT"
swap "$STAGE_DARK" "$THEME_DARK"
echo "Themes written to $THEME_LIGHT and $THEME_DARK"

# --- 7. Re-apply the folder tint ----------------------------------------------
# Every build starts from vendor/'s blue folders. Lay the last tint (matugen
# palette or --color) back down so a rebuild doesn't leave blue folders behind.
# The recolour reads from its own pristine baseline, so this is idempotent; with
# no tint ever set, --if-set does nothing. The copy matugen's post-hook runs is
# preferred, so both always agree.
RECOLOR_FOLDERS="$MATUGEN_HOOK"
[ -f "$RECOLOR_FOLDERS" ] || RECOLOR_FOLDERS="$REPO_DIR/matugen/recolor_folders.py"
if [ -f "$RECOLOR_FOLDERS" ]; then
  echo "Re-applying folder tint..."
  python3 "$RECOLOR_FOLDERS" --if-set || echo "  folder tint failed (non-fatal)" >&2
fi
plasma_nudge

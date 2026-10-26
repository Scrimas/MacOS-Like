#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# install.sh — install, update or remove MacOS-Like.
#
#   curl -fsSL https://raw.githubusercontent.com/Scrimas/MacOS-Like/main/install.sh | bash
#
# Run like that, it keeps a copy of MacOS-Like in ~/.local/share/macos-like
# ($XDG_DATA_HOME/macos-like) and links that copy's install.sh into ~/.local/bin
# as the `macos-like` command; run from a clone, it uses the clone. Either way it
# offers to install the few packages the build needs, builds the
# MacOS-Like-Light and MacOS-Like-Dark icon themes with setup.sh, and offers to
# switch the desktop to one of them. `macos-like help` lists everything else.
#
# For testing a fork: MACOS_LIKE_REPO (default the GitHub repo below),
# MACOS_LIKE_BRANCH (main) and MACOS_LIKE_DIR (~/.local/share/macos-like).
#
# Everything is in functions and runs from the last line, so a download cut
# short by `curl | bash` runs nothing at all.

set -euo pipefail

REPO_URL="${MACOS_LIKE_REPO:-https://github.com/Scrimas/MacOS-Like}"
BRANCH="${MACOS_LIKE_BRANCH:-main}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
APP_DIR="${MACOS_LIKE_DIR:-$DATA_HOME/macos-like}"
BIN_DIR="$HOME/.local/bin"
SETTINGS="$CONFIG_HOME/macos-like"
PREVIOUS="$SETTINGS/previous-icon-theme"

usage() {
  cat <<'EOF'
Usage: macos-like [COMMAND] [OPTIONS] [-- SETUP_OPTIONS]
       (or: install.sh ..., or: curl -fsSL .../install.sh | bash -s -- ...)

Commands:
  install           install MacOS-Like, or update it and rebuild (the default)
  update            the same as install
  refresh           rebuild the icons only, e.g. after installing apps (offline)
  apply light|dark  switch your desktop to MacOS-Like-Light or MacOS-Like-Dark
  folders COLOUR    tint the folder icons: #rrggbb, one of MacTahoe's colours
                    (blue green grey nord orange purple red yellow), "reset"
                    for the original blue, or "matugen" to follow its palette
  uninstall         remove the themes, the macos-like command and its copy
  help              show this

Options:
  --light, --dark   switch to that theme once installed, without asking
  --no-apply        don't offer to switch themes
  -y, --yes         answer yes to every question (installs missing packages)
  -- ...            hand the rest to setup.sh (--force, --inherits-light ...)
EOF
}

# --- output and questions -----------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\e[1m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' RESET=$'\e[0m'
else
  BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi
say()  { printf '%s==>%s %s%s%s\n' "$GREEN$BOLD" "$RESET" "$BOLD" "$*" "$RESET"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; exit 1; }

# Questions go to the terminal even under `curl | bash`, where stdin is the
# script itself. Without a terminal every question gets "no" unless --yes.
TTY=""
if { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi

ask() {   # ask QUESTION y|n -> status 0 for yes
  local answer hint='[Y/n]'
  [ "$2" = n ] && hint='[y/N]'
  [ "$YES" -eq 1 ] && return 0
  [ -n "$TTY" ] || return 1
  printf '%s %s ' "$1" "$hint" >"$TTY"
  read -r answer <"$TTY" || answer=""
  case "${answer:-$2}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- where MacOS-Like lives -----------------------------------------------------
# A clone runs as itself ("checkout"); anything else (curl | bash, the
# macos-like command) works on the copy in APP_DIR ("managed").
locate() {
  local self="${BASH_SOURCE[0]:-}" here="" app
  if [ -n "$self" ] && [ -f "$self" ]; then
    here="$(cd "$(dirname "$(readlink -f "$self")")" && pwd)"
  fi
  app="$(readlink -f "$APP_DIR" 2>/dev/null || echo "$APP_DIR")"
  if [ -n "$here" ] && [ "$here" != "$app" ] \
     && [ -f "$here/setup.sh" ] && [ -d "$here/vendor" ]; then
    MODE=checkout ROOT="$here"
  else
    MODE=managed ROOT="$APP_DIR"
  fi
}

# --- packages -----------------------------------------------------------------
# What is missing, as tool names: the build needs python3 with Pillow and
# rsvg-convert; a download needs git, or curl or wget with tar.
missing_tools() {
  local m=()
  command -v python3 >/dev/null 2>&1 || m+=(python3)
  python3 -c 'import PIL' >/dev/null 2>&1 || m+=(pillow)
  command -v rsvg-convert >/dev/null 2>&1 || m+=(rsvg-convert)
  if [ "$1" = download ] && ! command -v git >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || m+=(curl)
    command -v tar >/dev/null 2>&1 || m+=(tar)
  fi
  echo "${m[*]}"
}

package_manager() {
  local pm
  for pm in pacman apt-get dnf zypper xbps-install apk; do
    if command -v "$pm" >/dev/null 2>&1; then echo "$pm"; return 0; fi
  done
}

package_name() {   # package_name MANAGER TOOL
  case "$1:$2" in
    pacman:python3) echo python ;;
    pacman:pillow) echo python-pillow ;;
    pacman:rsvg-convert) echo librsvg ;;
    apt-get:pillow) echo python3-pil ;;
    apt-get:rsvg-convert) echo librsvg2-bin ;;
    dnf:pillow) echo python3-pillow ;;
    dnf:rsvg-convert) echo librsvg2-tools ;;
    zypper:pillow|xbps-install:pillow) echo python3-Pillow ;;
    xbps-install:rsvg-convert) echo librsvg-utils ;;
    apk:pillow) echo py3-pillow ;;
    *) echo "$2" ;;
  esac
}

install_command() {
  case "$1" in
    pacman) echo "pacman -S --needed --noconfirm" ;;
    apt-get) echo "apt-get install -y" ;;
    dnf) echo "dnf install -y" ;;
    zypper) echo "zypper --non-interactive install" ;;
    xbps-install) echo "xbps-install -y" ;;
    apk) echo "apk add" ;;
  esac
}

# Offer to install whatever `missing_tools $1` names, with the system's own
# package manager.
ensure_tools() {
  local missing pm t cmd=() pkgs=() root=()
  missing=$(missing_tools "$1")
  [ -n "$missing" ] || return 0
  pm=$(package_manager)
  if [ -z "$pm" ]; then
    die "missing: $missing. Install Python 3 with Pillow and rsvg-convert (librsvg)" \
        "with your package manager, then run this again."
  fi
  for t in $missing; do pkgs+=("$(package_name "$pm" "$t")"); done
  read -ra cmd <<< "$(install_command "$pm")"
  if command -v sudo >/dev/null 2>&1; then root=(sudo)
  elif command -v doas >/dev/null 2>&1; then root=(doas)
  else die "missing: ${pkgs[*]}. Install them as root: ${cmd[*]} ${pkgs[*]}"
  fi
  say "MacOS-Like needs ${pkgs[*]}"
  ask "Install with '${root[*]} ${cmd[*]} ${pkgs[*]}'?" y \
    || die "install them with: ${root[*]} ${cmd[*]} ${pkgs[*]}"
  "${root[@]}" "${cmd[@]}" "${pkgs[@]}" <"${TTY:-/dev/null}" \
    || die "the package install failed (on Debian or Ubuntu, try 'sudo apt-get update' first)"
  missing=$(missing_tools "$1")
  [ -z "$missing" ] || die "still missing after the install: $missing"
}

# --- download -----------------------------------------------------------------
# A git clone when git is there (updates then fetch only what changed), the
# tarball otherwise. A fresh copy is put together next to APP_DIR and swapped
# in, so a failed download leaves the old one as it was.
fetch() {
  local parent tmp url
  parent="$(dirname "$APP_DIR")"
  mkdir -p "$parent"
  if command -v git >/dev/null 2>&1 && [ -d "$APP_DIR/.git" ]; then
    say "Updating MacOS-Like in $APP_DIR"
    git -C "$APP_DIR" remote set-url origin "$REPO_URL"
    git -C "$APP_DIR" fetch --quiet --depth 1 origin "$BRANCH"
    git -C "$APP_DIR" reset --quiet --hard FETCH_HEAD
    git -C "$APP_DIR" clean --quiet -fdx
    return 0
  fi
  tmp=$(mktemp -d "$parent/.macos-like.XXXXXX")
  CLEANUP+=("$tmp")
  if command -v git >/dev/null 2>&1; then
    say "Downloading MacOS-Like (about 17 MB)"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$tmp/src"
  else
    url="$REPO_URL/archive/refs/heads/$BRANCH.tar.gz"
    say "Downloading MacOS-Like (about 17 MB)"
    mkdir "$tmp/src"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --progress-bar "$url" | tar -xz -C "$tmp/src" --strip-components=1
    else
      wget -qO- "$url" | tar -xz -C "$tmp/src" --strip-components=1
    fi
  fi
  [ -f "$tmp/src/setup.sh" ] && [ -f "$tmp/src/install.sh" ] \
    || die "the download from $REPO_URL is not MacOS-Like"
  if [ -e "$APP_DIR" ]; then mv "$APP_DIR" "$tmp/old"; fi
  mv "$tmp/src" "$APP_DIR"
  rm -rf "$tmp"   # now, not on exit: cmd_install execs the new copy next
}

# --- the macos-like command ---------------------------------------------------
link_command() {
  local link="$BIN_DIR/macos-like"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    warn "$link exists and isn't a link, so it stays; run $ROOT/install.sh instead"
    return 0
  fi
  mkdir -p "$BIN_DIR"
  ln -sfn "$ROOT/install.sh" "$link"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) note "$BIN_DIR is not in your PATH; until it is, the command is $link" ;;
  esac
}

build() {
  # setup.sh may ask about matugen, so it gets the terminal too
  bash "$ROOT/setup.sh" "${SETUP_ARGS[@]}" <"${TTY:-/dev/null}"
}

# --- the desktop's icon theme -------------------------------------------------
desktop() {
  case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:KDE:*) echo kde ;;
    *:X-Cinnamon:*|*:Cinnamon:*) echo cinnamon ;;
    *:MATE:*) echo mate ;;
    *:XFCE:*) echo xfce ;;
    *:GNOME:*|*:Unity:*|*:Budgie:*|*:Pantheon:*) echo gnome ;;
    *) echo other ;;
  esac
}

plasma_changeicons() {
  local t
  for t in "$(command -v plasma-changeicons 2>/dev/null || true)" \
           /usr/lib/plasma-changeicons /usr/libexec/plasma-changeicons \
           /usr/lib/*/libexec/plasma-changeicons; do
    if [ -n "$t" ] && [ -x "$t" ]; then echo "$t"; return 0; fi
  done
  return 1
}

kde_config() {   # kde_config read|write KEY [VALUE] in kdeglobals' [Icons]
  local tool
  for tool in kreadconfig6 kreadconfig5; do
    [ "$1" = read ] && command -v "$tool" >/dev/null 2>&1 \
      && { "$tool" --file kdeglobals --group Icons --key "$2"; return; }
  done
  for tool in kwriteconfig6 kwriteconfig5; do
    [ "$1" = write ] && command -v "$tool" >/dev/null 2>&1 \
      && { "$tool" --file kdeglobals --group Icons --key "$2" "$3"; return; }
  done
  return 1
}

current_theme() {
  local v=""
  case "$(desktop)" in
    kde) v=$(kde_config read Theme 2>/dev/null || true); v=${v:-breeze} ;;
    xfce) v=$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || true) ;;
    cinnamon) v=$(gsettings get org.cinnamon.desktop.interface icon-theme 2>/dev/null || true) ;;
    mate) v=$(gsettings get org.mate.interface icon-theme 2>/dev/null || true) ;;
    *) v=$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null || true) ;;
  esac
  v=${v#\'}
  echo "${v%\'}"
}

set_theme() {
  local tool done=0
  case "$(desktop)" in
    kde)
      if tool=$(plasma_changeicons); then "$tool" "$1" >/dev/null 2>&1
      else kde_config write Theme "$1"; fi ;;
    xfce) xfconf-query -c xsettings -p /Net/IconThemeName -s "$1" ;;
    cinnamon) gsettings set org.cinnamon.desktop.interface icon-theme "$1" ;;
    mate) gsettings set org.mate.interface icon-theme "$1" ;;
    gnome) gsettings set org.gnome.desktop.interface icon-theme "$1" ;;
    *)
      # Hyprland, Sway, niri, ...: GTK apps go by the GNOME setting, KDE apps
      # by kdeglobals; set whichever this system has.
      if command -v gsettings >/dev/null 2>&1 \
         && gsettings set org.gnome.desktop.interface icon-theme "$1" 2>/dev/null; then
        done=1
      fi
      if [ -f "$CONFIG_HOME/kdeglobals" ] && kde_config write Theme "$1" 2>/dev/null; then
        done=1
      fi
      [ "$done" -eq 1 ] || return 1
      note "Qt apps set up with qt5ct or qt6ct take their icon theme from there." ;;
  esac
}

prefers_dark() {
  local v
  v=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || true)
  [ "$v" = "'prefer-dark'" ] && return 0
  v=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null || true)
  case "$v" in *[Dd]ark*) return 0 ;; esac
  v=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)
  case "$v" in *[Dd]ark*) return 0 ;; esac
  return 1
}

# Switch to $1, remembering what was there before for `uninstall`.
switch_to() {
  local cur
  cur=$(current_theme)
  case "$cur" in
    MacOS-Like-Light|MacOS-Like-Dark|"") ;;
    *) mkdir -p "$SETTINGS"; echo "$cur" > "$PREVIOUS" ;;
  esac
  if set_theme "$1"; then
    say "Your icons are now $1"
  else
    warn "couldn't switch automatically; pick $1 in your desktop's settings"
  fi
}

offer_theme() {
  local cur pick default answer
  cur=$(current_theme)
  if [ -z "$THEME" ]; then
    case "$cur" in
      MacOS-Like-Light|MacOS-Like-Dark) note "Your desktop already uses $cur."; return 0 ;;
    esac
    [ "$APPLY" = ask ] || return 0
    if prefers_dark; then default=dark; else default=light; fi
    if [ "$YES" -eq 1 ]; then
      pick=$default
    elif [ -n "$TTY" ]; then
      if [ "$default" = dark ]; then
        printf 'Switch your icons to MacOS-Like now? [D]ark / [l]ight / [n]o ' >"$TTY"
      else
        printf 'Switch your icons to MacOS-Like now? [L]ight / [d]ark / [n]o ' >"$TTY"
      fi
      read -r answer <"$TTY" || answer=n
      case "${answer:-$default}" in
        [Dd]*) pick=dark ;;
        [Ll]*) pick=light ;;
        *) pick="" ;;
      esac
    fi
    if [ -z "$pick" ]; then
      note "Pick MacOS-Like-Light or MacOS-Like-Dark in your desktop's settings,"
      note "or run: macos-like apply dark"
      return 0
    fi
    THEME="MacOS-Like-${pick^}"
  fi
  switch_to "$THEME"
}

# --- commands -----------------------------------------------------------------
refuse_root() {
  [ "$(id -u)" -ne 0 ] && return 0
  die "don't run this as root: the themes go into your own ~/.local/share/icons," \
      "and it asks for sudo itself when it needs packages."
}

cmd_install() {
  refuse_root
  if [ "$MODE" = managed ] && [ -z "${MACOS_LIKE_FETCHED:-}" ]; then
    ensure_tools download
    fetch
    # carry on with the install.sh just downloaded, which may know more
    MACOS_LIKE_FETCHED=1 exec bash "$ROOT/install.sh" "${ARGS[@]}"
  fi
  ensure_tools build
  if [ "$MODE" = checkout ] && [ "$CMD" = update ]; then
    note "This is a clone ($ROOT): 'git pull' updates it. Rebuilding as it is."
  fi
  link_command
  say "Building MacOS-Like-Light and MacOS-Like-Dark"
  build
  offer_theme
  echo
  say "Done"
  note "macos-like refresh         after installing apps: gives them tiles (seconds)"
  note "macos-like update          get the latest MacOS-Like"
  note "macos-like apply dark      or light; 'macos-like help' for the rest"
}

cmd_refresh() {
  refuse_root
  [ -f "$ROOT/setup.sh" ] || die "MacOS-Like isn't installed; run the installer first"
  ensure_tools build
  build
}

cmd_apply() {
  local t
  case "${1:-}" in
    light|Light|MacOS-Like-Light) t=MacOS-Like-Light ;;
    dark|Dark|MacOS-Like-Dark) t=MacOS-Like-Dark ;;
    *) die "usage: macos-like apply light|dark" ;;
  esac
  [ -f "$DATA_HOME/icons/$t/index.theme" ] || die "$t isn't built yet; run: macos-like refresh"
  switch_to "$t"
}

cmd_folders() {
  local tool="$ROOT/matugen/recolor_folders.py" c
  [ -f "$tool" ] || die "MacOS-Like isn't installed; run the installer first"
  # MacTahoe's own colour variants, by the main colour of their folders
  case "${1:-}" in
    blue) c='#006efd' ;;    green) c='#27d83d' ;;  grey) c='#686868' ;;
    nord) c='#5a6885' ;;    orange) c='#ff8b1d' ;; purple) c='#aa5adc' ;;
    red) c='#fe342c' ;;     yellow) c='#ffc61d' ;;
    \#*) c="$1" ;;
    reset) python3 "$tool" --restore; return ;;
    matugen) python3 "$tool" --setup; return ;;
    *) die "usage: macos-like folders '#rrggbb' | blue|green|grey|nord|orange|purple|red|yellow | reset | matugen" ;;
  esac
  python3 "$tool" --color "$c"
}

cmd_uninstall() {
  local cur prev hook link
  say "Removing MacOS-Like"
  cur=$(current_theme)
  case "$cur" in
    MacOS-Like-Light|MacOS-Like-Dark)
      prev=$(cat "$PREVIOUS" 2>/dev/null || true)
      if [ -z "$prev" ]; then
        case "$(desktop)" in kde) prev=breeze ;; *) prev=Adwaita ;; esac
      fi
      if set_theme "$prev"; then note "Icons switched back to $prev"
      else warn "pick another icon theme in your desktop's settings"; fi ;;
  esac
  for t in MacOS-Like-Light MacOS-Like-Dark; do
    rm -rf "${DATA_HOME:?}/icons/$t" "$DATA_HOME/icons/.$t.new" "$DATA_HOME/icons/.$t.old"
  done
  note "removed the themes from $DATA_HOME/icons"
  hook="$CONFIG_HOME/matugen/post-hook-scripts/recolor_folders.py"
  if [ -f "$hook" ]; then
    python3 "$hook" --unsetup || warn "couldn't unhook the folder tint from matugen"
  fi
  rm -rf "$STATE_HOME/folder-icons"
  if [ -d "$SETTINGS" ]; then
    rm -f "$PREVIOUS" "$SETTINGS/no-matugen-prompt"
    rmdir "$SETTINGS" 2>/dev/null \
      || { ask "Delete your own settings in $SETTINGS too?" n && rm -rf "$SETTINGS"; } \
      || note "kept your settings in $SETTINGS"
  fi
  link="$BIN_DIR/macos-like"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$ROOT/install.sh" ]; then rm -f "$link"; fi
  if [ "$MODE" = managed ]; then
    rm -rf "$APP_DIR"
  else
    note "your clone in $ROOT stays"
  fi
  say "MacOS-Like is uninstalled"
}

# --- main ---------------------------------------------------------------------
CLEANUP=()
cleanup() { if [ "${#CLEANUP[@]}" -gt 0 ]; then rm -rf "${CLEANUP[@]}"; fi; }

main() {
  ARGS=("$@")
  CMD=install ARG="" THEME="" APPLY=ask YES=0 SETUP_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      install|update|refresh|uninstall|help) CMD=$1 ;;
      apply|folders) CMD=$1; ARG="${2:-}"; [ $# -lt 2 ] || shift ;;
      --light) THEME=MacOS-Like-Light ;;
      --dark) THEME=MacOS-Like-Dark ;;
      --no-apply) APPLY=no ;;
      -y|--yes) YES=1 ;;
      -h|--help) CMD=help ;;
      --) shift; SETUP_ARGS=("$@"); break ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  trap cleanup EXIT
  locate
  case "$CMD" in
    install|update) cmd_install ;;
    refresh) cmd_refresh ;;
    apply) cmd_apply "$ARG" ;;
    folders) cmd_folders "$ARG" ;;
    uninstall) cmd_uninstall ;;
    help) usage ;;
  esac
}

main "$@"

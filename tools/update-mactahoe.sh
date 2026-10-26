#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# update-mactahoe.sh — put MacTahoe at the pinned commit into vendor/, then
# rebuild prebuilt/ from it.
#
# MacOS-Like ships MacTahoe itself, so nobody has to install it: vendor/ holds
# the MacTahoe and MacTahoe-dark themes exactly as upstream's own installer
# lays them out (default colour), and prebuilt/ the app icons that
# `setup.sh --rebuild` makes from them. To move to another upstream commit,
# change MACTAHOE_COMMIT below and run this again. It downloads that commit,
# runs its install.sh into a temporary directory, swaps the result into
# vendor/ and, unless prebuilt/ already matches, runs `setup.sh --rebuild`
# (about 9 minutes on 8 cores), which also reinstalls your themes.
#
# Usage:  tools/update-mactahoe.sh [--no-rebuild]

set -euo pipefail

# https://github.com/vinceliuice/MacTahoe-icon-theme/commits/main
MACTAHOE_COMMIT=262c693cacbb1df218a6fce130a4500667c2aa9d   # 2026-08-17 "Fixed bold version"
MACTAHOE_URL=https://github.com/vinceliuice/MacTahoe-icon-theme

USAGE="usage: tools/update-mactahoe.sh [--no-rebuild]"
REBUILD=1
case "${1:-}" in
  "") ;;
  --no-rebuild) REBUILD=0 ;;
  -h|--help) echo "$USAGE"; exit 0 ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
VENDOR="$REPO_DIR/vendor"

if command -v curl >/dev/null 2>&1; then fetch=(curl -fsSL)
elif command -v wget >/dev/null 2>&1; then fetch=(wget -qO-)
else echo "update-mactahoe.sh needs curl or wget." >&2; exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/src" "$tmp/out" "$tmp/bin"
echo "Downloading MacTahoe $MACTAHOE_COMMIT ..."
"${fetch[@]}" "$MACTAHOE_URL/archive/$MACTAHOE_COMMIT.tar.gz" \
  | tar -xz -C "$tmp/src" --strip-components=1

# Upstream's installer ends every theme with a bare gtk-update-icon-cache, which
# aborts the install where that tool is missing, and a cache would be stale in
# vendor/ anyway: a stand-in that does nothing goes first on PATH. With
# DESKTOP_SESSION unset, Budgie's own status icons stay out of the shared copy.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/gtk-update-icon-cache"
chmod +x "$tmp/bin/gtk-update-icon-cache"
echo "Running MacTahoe's install.sh ..."
env -u DESKTOP_SESSION PATH="$tmp/bin:$PATH" \
  bash "$tmp/src/install.sh" -d "$tmp/out" -t default >/dev/null
for t in MacTahoe MacTahoe-dark; do
  if [ ! -f "$tmp/out/$t/index.theme" ] || [ ! -d "$tmp/out/$t/apps" ]; then
    echo "MacTahoe's install.sh did not produce $t." >&2; exit 1
  fi
  rm -f "$tmp/out/$t/icon-theme.cache"
done

old=""
[ -f "$VENDOR/VERSION" ] && read -r old < "$VENDOR/VERSION"
same=1
for t in MacTahoe MacTahoe-dark; do
  diff -rq --no-dereference "$tmp/out/$t" "$VENDOR/$t" >/dev/null 2>&1 || same=0
done
if [ "$same" -eq 1 ] && [ "$old" = "$MACTAHOE_COMMIT" ]; then
  echo "vendor/ already holds MacTahoe $MACTAHOE_COMMIT."
else
  mkdir -p "$VENDOR"
  rm -rf "${VENDOR:?}/MacTahoe" "${VENDOR:?}/MacTahoe-dark"
  cp -a "$tmp/out/MacTahoe" "$tmp/out/MacTahoe-dark" "$VENDOR/"
  echo "$MACTAHOE_COMMIT" > "$VENDOR/VERSION"
  echo "vendor/ updated: MacTahoe ${old:-(none)} -> $MACTAHOE_COMMIT"
fi

[ "$REBUILD" -eq 1 ] || exit 0
if "$REPO_DIR/setup.sh" --check >/dev/null 2>&1; then
  echo "prebuilt/ already matches it."
else
  echo "Rebuilding prebuilt/ with setup.sh --rebuild (about 9 minutes on 8 cores) ..."
  "$REPO_DIR/setup.sh" --rebuild
fi

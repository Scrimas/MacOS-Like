#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# lint.sh — shellcheck the shell, ruff the Python, including the <<'PYEOF'
# heredocs embedded in setup.sh (reported at their real line numbers), and
# check that vendor/ and prebuilt/ match what the scripts say they should be.
#
# Usage:  ./lint.sh

set -uo pipefail
cd "$(dirname "$0")" || exit 2

WRAP=setup.sh
rc=0

shellcheck "$WRAP" install.sh lint.sh tools/update-mactahoe.sh || rc=1
ruff check --quiet matugen/recolor_folders.py screenshots/render.py || rc=1

# Each heredoc is padded with blank lines up to where it starts, so ruff's line
# numbers are setup.sh's line numbers.
while IFS=: read -r marker _; do
  awk -v s="$marker" 'NR <= s { print ""; next } /^PYEOF$/ { exit } { print }' "$WRAP" \
    | ruff check --quiet --stdin-filename "$WRAP.py" - || rc=1
done < <(grep -n "<<'PYEOF'" "$WRAP")

# vendor/ must be the MacTahoe commit tools/update-mactahoe.sh pins, and
# prebuilt/ what setup.sh --rebuild makes of it now.
pin=$(sed -n 's/^MACTAHOE_COMMIT=\([0-9a-f]*\).*/\1/p' tools/update-mactahoe.sh)
have=$(cat vendor/VERSION 2>/dev/null)
if [ "$pin" != "$have" ]; then
  echo "vendor/ is MacTahoe '$have', tools/update-mactahoe.sh pins '$pin': run it" >&2
  rc=1
fi
./setup.sh --check >/dev/null || rc=1

exit "$rc"

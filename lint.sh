#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# lint.sh — shellcheck the shell, ruff the Python, including the <<'PYEOF'
# heredocs embedded in setup.sh (reported at their real line numbers).
#
# Usage:  ./lint.sh

set -uo pipefail
cd "$(dirname "$0")" || exit 2

WRAP=setup.sh
rc=0

shellcheck "$WRAP" lint.sh || rc=1
ruff check --quiet matugen/recolor_folders.py screenshots/render.py || rc=1

# Each heredoc is padded with blank lines up to where it starts, so ruff's line
# numbers are setup.sh's line numbers.
while IFS=: read -r marker _; do
  awk -v s="$marker" 'NR <= s { print ""; next } /^PYEOF$/ { exit } { print }' "$WRAP" \
    | ruff check --quiet --stdin-filename "$WRAP.py" - || rc=1
done < <(grep -n "<<'PYEOF'" "$WRAP")

exit "$rc"

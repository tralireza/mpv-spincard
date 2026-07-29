#!/usr/bin/env bash
# Run all spincard unit tests. From the repo root:  ./tests/run.sh  (or: bash tests/run.sh)
# Needs luajit on PATH. Exit 0 iff every assert-based test passes.
set -u
cd "$(dirname "$0")/.." || exit 1   # tests set package.path relative to the repo root
fail=0
for f in tests/test_*.lua; do
    name=$(basename "$f")
    out=$(luajit "$f" 2>&1)
    if printf '%s' "$out" | grep -qiE 'ALL PASS|passed, 0 failed'; then
        printf '  PASS   %s\n' "$name"
    elif [ "$name" = "test_card_fonts.lua" ]; then
        printf '  AUDIT  %s (font-tier dump — eyeball, no assertions)\n' "$name"
    else
        printf '  FAIL   %s\n' "$name"; printf '%s\n' "$out" | tail -4 | sed 's/^/         /'; fail=1
    fi
done
exit $fail

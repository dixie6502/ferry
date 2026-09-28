#!/usr/bin/env bash
#
# `.ferryignore` tests: what is excluded from transfers must be excluded from
# drift too, on both sides and in the prompt.
#
# Real rclone against a real backend: the cloud side is a plain directory
# addressed as `:local:<path>`, an rclone connection string. No mocks, and no
# way to reach the user's configured remotes.
#
# Usage: tests/test-ignore.sh       (from anywhere; scratch lands in tmp/)

set -uo pipefail

SUITE_TMP=ti
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

# The exit status and message of a run expected to fail.
refusal_of() { ferry "$@" 2>&1 >/dev/null | sed 's/.*— //'; }

printf '\n== a unit rule keeps files out of the transfer ==\n'
reset_tree
ferry new u >/dev/null
printf 'node_modules/\n*.log\n/build/\n' > "$WORK/u/.ferryignore"
printf 'x\n' > "$WORK/u/doc.txt"
printf 'x\n' > "$WORK/u/app.log"
mkdir -p "$WORK/u/node_modules/deep" "$WORK/u/build" "$WORK/u/sub/build"
printf 'x\n' > "$WORK/u/node_modules/deep/n.js"
printf 'x\n' > "$WORK/u/build/b.o"
printf 'x\n' > "$WORK/u/sub/build/kept.txt"
ferry push u >/dev/null 2>&1
check 'glob, directory and anchored rules all applied' '.ferryignore doc.txt sub/build/kept.txt ' "$(cloud_of u)"
check '  the unit reads as in sync' '=' "$(symbol_of u)"
check '  .ferryignore itself rides up' 'yes' "$([ -f "$CLOUD/u/.ferryignore" ] && echo yes || echo no)"

printf '\n== an anchored rule binds to the top of the unit only ==\n'
printf 'x\n' > "$WORK/u/sub/build/more.txt"
check 'a nested "build" is untouched by /build/' '>' "$(symbol_of u)"
check '  classified' 'local add sub/build/more.txt' "$(detail_of u)"

printf '\n== a directory rule does not hide a file of the same name ==\n'
reset_tree
ferry new u >/dev/null
printf 'cache/\n' > "$WORK/u/.ferryignore"
mkdir -p "$WORK/u/cache"; printf 'x\n' > "$WORK/u/cache/blob"
printf 'x\n' > "$WORK/u/sub-cache-file"
mkdir -p "$WORK/u/sub"; printf 'x\n' > "$WORK/u/sub/cache"
ferry push u >/dev/null 2>&1
check 'cache/ prunes the directory, keeps the file' '.ferryignore sub-cache-file sub/cache ' "$(cloud_of u)"

printf '\n== a pattern may hold whitespace ==\n'
reset_tree
ferry new u >/dev/null
printf 'scratch notes.txt\n' > "$WORK/u/.ferryignore"
printf 'x\n' > "$WORK/u/scratch notes.txt"
printf 'x\n' > "$WORK/u/doc.txt"
ferry push u >/dev/null 2>&1
check 'name with a space is excluded' '.ferryignore doc.txt ' "$(cloud_of u)"
check '  the unit reads as in sync' '=' "$(symbol_of u)"

printf '\n== the tree-root file applies to every unit, and a unit extends it ==\n'
reset_tree
printf '*.log\n' > "$WORK/.ferryignore"
ferry new a >/dev/null; ferry new b >/dev/null
printf 'x\n' > "$WORK/a/doc.txt"; printf 'x\n' > "$WORK/a/a.log"
printf 'x\n' > "$WORK/b/doc.txt"; printf 'x\n' > "$WORK/b/b.log"
ferry push >/dev/null 2>&1
check 'root rule reaches unit a' 'doc.txt ' "$(cloud_of a)"
check 'root rule reaches unit b' 'doc.txt ' "$(cloud_of b)"
printf 'tmp/\n' > "$WORK/a/.ferryignore"
mkdir -p "$WORK/a/tmp"; printf 'x\n' > "$WORK/a/tmp/t.bin"; printf 'x\n' > "$WORK/a/more.log"
ferry push a >/dev/null 2>&1
check 'unit rule adds to the root rule' '.ferryignore doc.txt ' "$(cloud_of a)"
check '  b keeps only the root rule' 'doc.txt ' "$(cloud_of b)"
check '  both units in sync' '=
=' "$(ferry status | awk '{print $1}')"

printf '\n== the cloud side is filtered too ==\n'
reset_tree
ferry new u >/dev/null
printf '*.log\n' > "$WORK/u/.ferryignore"
printf 'x\n' > "$WORK/u/doc.txt"
ferry push u >/dev/null 2>&1
printf 'x\n' > "$CLOUD/u/server.log"
check 'an ignored cloud file is not a "remote add"' '=' "$(symbol_of u)"
ferry pull u >/dev/null 2>&1
check '  and pull leaves it there, unfetched' 'no' "$([ -e "$WORK/u/server.log" ] && echo yes || echo no)"

printf '\n== a first pull obeys the cloud copy of the unit rules ==\n'
# The unit's .ferryignore is not local yet, so the cloud's is the rule set:
# otherwise the pull lists, hashes and fetches everything it keeps out.
mkdir -p "$CLOUD/c/.venv/lib"
printf '.venv/\n' > "$CLOUD/c/.ferryignore"
printf 'x\n' > "$CLOUD/c/doc.txt"
printf 'x\n' > "$CLOUD/c/.venv/lib/site.py"
ferry pull c >/dev/null 2>&1
check 'the ignored directory stays on the cloud' 'no' "$([ -e "$WORK/c/.venv" ] && echo yes || echo no)"
check '  the rules themselves come down' 'yes' "$([ -f "$WORK/c/.ferryignore" ] && echo yes || echo no)"
check '  the manifest holds only what crossed' '.ferryignore doc.txt' \
    "$(tail -n +2 "$(state_of c)/manifest" | cut -d' ' -f2- | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check '  the unit reads as in sync' '=' "$(symbol_of c)"

printf '\n== --mirror does not delete what it cannot see ==\n'
ferry push u --mirror >/dev/null 2>&1
check 'the ignored cloud file survives a mirrored push' 'yes' \
    "$([ -f "$CLOUD/u/server.log" ] && echo yes || echo no)"

printf '\n== a rule that stops applying hands the file back ==\n'
# Editing the rules is itself an edit to a synced file, so the unit diverges:
# the cloud's own copy of .ferryignore still holds the old rule.
: > "$WORK/u/.ferryignore"
check 'the cloud file reappears' '<>' "$(symbol_of u)"
check '  classified' 'local edit .ferryignore
remote add server.log' "$(detail_of u)"

printf '\n== sync converges without carrying ignored files ==\n'
# sync transfers through --files-from-raw, which rclone refuses to combine with
# any filter: the lists must already be free of ignored paths.
reset_tree
ferry new u >/dev/null
printf '*.log\n' > "$WORK/u/.ferryignore"
printf 'x\n' > "$WORK/u/doc.txt"
ferry push u >/dev/null 2>&1
printf 'mine\n' > "$WORK/u/doc.txt"
printf 'x\n' > "$WORK/u/local.log"
printf 'x\n' > "$CLOUD/u/theirs.txt"
printf 'x\n' > "$CLOUD/u/cloud.log"
ferry sync u >/dev/null 2>&1
check 'converged, ignored files left on their side' '.ferryignore cloud.log doc.txt theirs.txt ' "$(cloud_of u)"
check '  the cloud log did not come down' 'no' "$([ -e "$WORK/u/cloud.log" ] && echo yes || echo no)"
check '  in sync afterwards' '=' "$(symbol_of u)"

printf '\n== malformed patterns are refused, never half-applied ==\n'
reset_tree
ferry new u >/dev/null
printf 'x\n' > "$WORK/u/doc.txt"
printf '!keep.txt\n' > "$WORK/u/.ferryignore"
check 're-inclusion' "re-inclusion ('!') is not supported" "$(refusal_of status u)"
printf 'a/**\n' > "$WORK/u/.ferryignore"
check 'globstar' "'**' is not supported; a bare name already matches at any depth" "$(refusal_of status u)"
printf 'a/b\n' > "$WORK/u/.ferryignore"
check 'unanchored slash' "a pattern holding '/' must be anchored to the unit: write '/a/b'" "$(refusal_of status u)"
printf '/x*/y\n' > "$WORK/u/.ferryignore"
check 'glob in an anchored pattern' "an anchored pattern must be literal (no '*', '?' or '[')" "$(refusal_of status u)"
ferry push u >/dev/null 2>&1; rc=$?
check 'and the push is refused as well' '1' "$rc"
printf '*.{jpg,png}\n' > "$WORK/u/.ferryignore"
check 'alternation' "'{a,b}' alternation is not supported; write one pattern per line" "$(refusal_of status u)"
printf '[!b].jpg\n' > "$WORK/u/.ferryignore"
check '[!...] negation' "'[!...]' is not supported; write the negation as '[^...]'" "$(refusal_of status u)"
printf '# a comment\n\n*.log\n' > "$WORK/u/.ferryignore"
ferry push u >/dev/null 2>&1
check 'comments and blank lines are skipped' '=' "$(symbol_of u)"

printf '\n== [^...] negation means the same to find and rclone ==\n'
reset_tree
ferry new u >/dev/null
printf 'x\n' > "$WORK/u/a.jpg"; printf 'x\n' > "$WORK/u/b.jpg"
printf '[^b].jpg\n' > "$WORK/u/.ferryignore"
ferry push u >/dev/null 2>&1
check 'kept out of the transfer' '.ferryignore b.jpg ' "$(cloud_of u)"
check '  and out of drift' '=' "$(symbol_of u)"

printf '\n== the prompt applies the same rules ==\n'
# shellcheck source=/dev/null
source "$REPO/ferry-prompt.sh"
prompt_of() { (cd "$WORK/$1" && __ferry_ps1 '%s'); }

reset_tree
ferry new p >/dev/null
printf '*.log\nnode_modules/\n' > "$WORK/p/.ferryignore"
printf 'x\n' > "$WORK/p/doc.txt"
printf 'x\n' > "$WORK/p/app.log"
mkdir -p "$WORK/p/node_modules"; printf 'x\n' > "$WORK/p/node_modules/n.js"
ferry push p >/dev/null 2>&1
check 'clean after push: status' '=' "$(symbol_of p)"
check 'clean after push: prompt' '=' "$(prompt_of p)"

# Writes that move a pruned file's mtime, never its parent directory's — the
# case the prompt can answer exactly.
printf 'more\n' >> "$WORK/p/app.log"
check 'ignored file edited: status' '=' "$(symbol_of p)"
check 'ignored file edited: prompt' '=' "$(prompt_of p)"
printf 'more\n' > "$WORK/p/node_modules/n.js"
check 'ignored subtree written: status' '=' "$(symbol_of p)"
check 'ignored subtree written: prompt' '=' "$(prompt_of p)"

printf 'x\n' > "$WORK/p/real.txt"
check 'a tracked add still shows: status' '>' "$(symbol_of p)"
check 'a tracked add still shows: prompt' '>' "$(prompt_of p)"

report

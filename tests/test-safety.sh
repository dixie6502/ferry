#!/usr/bin/env bash
#
# Safety tests: commands that must refuse rather than damage the tree, the
# cloud or the sync state, and failures that must fail loudly.
#
# Real rclone against a real backend: the cloud side is a plain directory
# addressed as `:local:<path>`, an rclone connection string. No mocks, and no
# way to reach the user's configured remotes.
#
# Usage: tests/test-safety.sh       (from anywhere; scratch lands in tmp/)

set -uo pipefail

SUITE_TMP=tsf
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

yes_no() { if "$@"; then echo yes; else echo no; fi; }

printf '\n== the tree root is never a unit ==\n'
reset_tree
mkdir -p "$CLOUD/a"; printf 'x\n' > "$CLOUD/a/f.txt"
root_marker=$(cat "$WORK/.ferry")
root_refusal="is a tree root, not a unit; run without <dir> to act on every unit"
check 'pull . refused' "1|ferry: '.' $root_refusal" "$(failure_of pull .)"
check 'push ./ refused' "1|ferry: './' $root_refusal" "$(failure_of push ./)"
check '  the root marker still holds the base' "$root_marker" "$(cat "$WORK/.ferry")"
check '  nothing was downloaded' 'no' "$(yes_no test -e "$WORK/a")"
mkdir -p "$WORK/a"; printf ':local:%s\n' "$SANDBOX/elsewhere" > "$WORK/a/.ferry"
check 'a nested root is refused before anything moves' "1|ferry: 'a' $root_refusal" \
    "$(failure_of pull a --force)"
check '  nothing was downloaded into it' 'no' "$(yes_no test -e "$WORK/a/f.txt")"

printf '\n== a grouping node is never a unit ==\n'
mkdir -p "$CLOUD/g/u1" "$CLOUD/g/u2"
printf '1\n' > "$CLOUD/g/u1/a"; printf '2\n' > "$CLOUD/g/u2/b"
ferry pull g/u1 >/dev/null 2>&1
check 'pull of a grouping node refused' "1|ferry: 'g' is a grouping node; name one of its units" \
    "$(failure_of pull g --force)"
check '  no marker was put on it' 'no' "$(yes_no test -e "$WORK/g/.ferry")"
check '  its other unit stayed on the cloud' 'no' "$(yes_no test -e "$WORK/g/u2")"

printf '\n== a target names one node however it is spelled ==\n'
reset_tree
ferry new u >/dev/null
printf '/out/log\n' > "$WORK/u/.ferryignore"
mkdir -p "$WORK/u/out"; printf 'x\n' > "$WORK/u/out/log"; printf 'x\n' > "$WORK/u/doc.txt"
ferry push u/ >/dev/null 2>&1
check 'anchored rule holds with a trailing slash' '.ferryignore doc.txt ' "$(cloud_of u)"
check '  ./u reads the same state' '=' "$(symbol_of ./u)"
check '  and labels it plainly' 'u' "$(ferry status ./u/ 2>/dev/null | awk 'NR==1{print $2}')"

printf '\n== mv never merges into an existing cloud path ==\n'
reset_tree
synced_unit src
mkdir -p "$CLOUD/dst"; printf 'cloud only\n' > "$CLOUD/dst/doc.txt"
check 'mv onto a cloud-only path refused' "1|ferry: cloud target exists: :local:$CLOUD/dst" \
    "$(failure_of mv src dst)"
check '  the cloud copy is untouched' 'cloud only' "$(cat "$CLOUD/dst/doc.txt")"
check '  the source is untouched on both sides' 'yes yes' \
    "$(yes_no test -d "$WORK/src") $(yes_no test -d "$CLOUD/src")"
check 'mv into itself refused' '1|ferry: cannot move src into itself' "$(failure_of mv src src/deeper)"
mkdir -p "$WORK/src/sub"
check 'mv of a directory inside a unit refused' "1|ferry: inside unit 'src' — already materialized content" \
    "$(failure_of mv src/sub loose)"
rm -rf "$CLOUD/src"
check 'mv of a synced unit the cloud no longer shows refused' \
    "1|ferry: the cloud no longer answers for src, which it held at the last sync; refusing a local-only move" \
    "$(failure_of mv src moved)"

printf '\n== mv of a never-pushed unit moves it locally ==\n'
ferry new fresh >/dev/null
printf 'x\n' > "$WORK/fresh/doc.txt"
ferry mv fresh renamed >/dev/null 2>&1; rc=$?
check 'mv succeeds' '0' "$rc"
check '  the unit moved' 'no yes' "$(yes_no test -e "$WORK/fresh") $(yes_no test -f "$WORK/renamed/doc.txt")"
check '  its state moved with it' 'yes' "$(yes_no test -e "$(state_of renamed)/synced_at")"
check '  nothing appeared on the cloud' 'no' "$(yes_no test -e "$CLOUD/renamed")"

printf '\n== state keys are injective and locale-independent ==\n'
# shellcheck source=/dev/null
keys() { (source "$FERRY"; printf '%s %s' "$(state_key 'r:€')" "$(state_key 'r: AC')"); }
check 'a wide character and its hex lookalike differ' 'r%3A%E2%82%AC r%3A%20AC' "$(keys)"
check '  the same key in C and UTF-8 locales' \
    "$(LC_ALL=C bash -c "source '$FERRY'; state_key 'r:é'")" \
    "$(LC_ALL=C.UTF-8 bash -c "source '$FERRY'; state_key 'r:é'")"
# shellcheck source=/dev/null
prompt_key() { (source "$REPO/ferry-prompt.sh"; local key; __ferry_ps1_state_key "$1"; printf '%s' "$key"); }
check '  the prompt encodes as ferry does' \
    "$(LC_ALL=C.UTF-8 bash -c "source '$FERRY'; state_key 'r:Été €'")" \
    "$(LC_ALL=C.UTF-8 prompt_key 'r:Été €')"

printf '\n== state under the per-character key is adopted ==\n'
work2=$SANDBOX/work-accent
mkdir -p "$work2" "$SANDBOX/cloud/Été"
(cd "$work2" && "$FERRY" init ":local:$SANDBOX/cloud/Été" >/dev/null && "$FERRY" new u >/dev/null)
printf 'x\n' > "$work2/u/doc.txt"
(cd "$work2" && "$FERRY" push u >/dev/null 2>&1)
new_key=$(LC_ALL=C.UTF-8 bash -c "source '$FERRY'; state_key ':local:$SANDBOX/cloud/Été'")
old_key=$(LC_ALL=C.UTF-8 bash -c "source '$FERRY'; percent_encode ':local:$SANDBOX/cloud/Été'")
mv "$XDG_CACHE_HOME/ferry/$new_key" "$XDG_CACHE_HOME/ferry/$old_key"
check 'the unit still reads as in sync' '=' \
    "$(cd "$work2" && LC_ALL=C.UTF-8 "$FERRY" status u 2>/dev/null | awk 'NR==1{print $1}')"
check '  its state moved to the byte-wise key' 'no yes' \
    "$(yes_no test -e "$XDG_CACHE_HOME/ferry/$old_key") $(yes_no test -d "$XDG_CACHE_HOME/ferry/$new_key")"

printf '\n== a first pull through sync obeys the cloud rules ==\n'
reset_tree
mkdir -p "$CLOUD/c/.venv"
printf '.venv/\n' > "$CLOUD/c/.ferryignore"; printf 'x\n' > "$CLOUD/c/doc.txt"; printf 'x\n' > "$CLOUD/c/.venv/site.py"
mkdir -p "$WORK/c"; : > "$WORK/c/.ferry"          # a unit with no state here
ferry sync c >/dev/null 2>&1
check 'the ignored directory stays on the cloud' 'yes no' \
    "$(yes_no test -f "$WORK/c/doc.txt") $(yes_no test -e "$WORK/c/.venv")"

printf '\n== a unit that dies fails alone ==\n'
reset_tree
ferry new a >/dev/null; ferry new b >/dev/null
printf 'x\n' > "$WORK/a/doc.txt"; printf 'x\n' > "$WORK/b/doc.txt"
printf '!keep\n' > "$WORK/a/.ferryignore"
check 'the batch carries on past it' 'ferry: 1/2 ok, 1 failed: a' "$(ferry push 2>&1 >/dev/null | tail -1)"
check '  the other unit went up' 'doc.txt ' "$(cloud_of b)"

printf '\n== an error inside a target lookup is reported once ==\n'
check 'one message, not a cascade' "1|ferry: name must be relative, got '/abs'" "$(failure_of sync /abs)"
check 'list stops on it too' "1|ferry: name must be relative, got '/abs'" "$(failure_of list /abs)"

printf '\n== git history ==\n'
reset_tree
ferry new g >/dev/null
printf 'x\n' > "$WORK/g/doc.txt"
git -C "$WORK/g" init -q
ferry push g >/dev/null 2>&1; rc=$?
check 'a repository with no commits pushes, unbundled' '0 no' \
    "$rc $(yes_no test -e "$WORK/g/history.bundle")"

git -C "$WORK/g" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
rm -rf "$WORK/g/.git/objects/"??
printf 'y\n' > "$WORK/g/doc.txt"
ferry push g >/dev/null 2>&1; rc=$?
check 'a bundle that cannot be built fails the push' '1' "$rc"
check '  nothing went up' 'x' "$(cat "$CLOUD/g/doc.txt")"
check '  no bundle lock is left behind' 'no' "$(yes_no test -e "$WORK/g/history.bundle.lock")"

reset_tree
mkdir -p "$CLOUD/h"; printf 'x\n' > "$CLOUD/h/doc.txt"; printf 'not a bundle\n' > "$CLOUD/h/history.bundle"
out=$(ferry pull h 2>&1); rc=$?
check 'a bundle that cannot be restored still pulls' '0' "$rc"
check '  and says so' 'yes' "$(yes_no grep -q 'could not restore git history' <<<"$out")"
check '  no half-built .git is left to block a retry' 'no' "$(yes_no test -e "$WORK/h/.git")"
check '  the sync point was recorded' '=' "$(symbol_of h)"

reset_tree
mkdir -p "$CLOUD/w"; printf 'x\n' > "$CLOUD/w/doc.txt"; printf 'not a bundle\n' > "$CLOUD/w/history.bundle"
mkdir -p "$WORK/w"; : > "$WORK/w/.ferry"; printf 'gitdir: %s\n' "$SANDBOX/linked" > "$WORK/w/.git"
ferry pull w --force >/dev/null 2>&1
check 'a worktree link is never replaced by a restore' "gitdir: $SANDBOX/linked" "$(cat "$WORK/w/.git")"

reset_tree
synced_unit r
git -C "$WORK/r" init -q
git -C "$WORK/r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ferry push r >/dev/null 2>&1
rm -rf "$WORK/r"
ferry pull r >/dev/null 2>&1
check 'a sound bundle restores its history' 'init' "$(git -C "$WORK/r" log -1 --format=%s 2>&1)"
: > "$WORK/r/history.bundle.lock"                # what a killed `git bundle` leaves
ferry push r >/dev/null 2>&1; rc=$?
check 'a stale bundle lock neither blocks the push nor rides up' '0 no no' \
    "$rc $(yes_no test -e "$CLOUD/r/history.bundle.lock") $(yes_no test -e "$WORK/r/history.bundle.lock")"

report

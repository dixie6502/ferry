#!/usr/bin/env bash
#
# `ferry sync` tests: one verb converges a unit both ways — additive, toward
# the union — and leaves conflicts untouched on both sides.
#
# Real rclone against a real backend (`:local:`), same sandbox shape as the
# other suites.
#
# Usage: tests/test-sync.sh        (from anywhere; scratch lands in tmp/)

set -uo pipefail

SUITE_TMP=ts
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

printf '\n== first sync of a new unit is its first push ==\n'
reset_tree
ferry new n >/dev/null
printf 'v1\n' > "$WORK/n/doc.txt"
check 'sync exits 0' '0' "$(ferry sync n >/dev/null 2>&1; echo $?)"
check 'cloud materialized' 'v1' "$(cat "$CLOUD/n/doc.txt" 2>&1)"
check 'clean afterwards' '=' "$(symbol_of n)"

printf '\n== one run carries both directions ==\n'
reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/doc.txt"
printf 'theirs\n' > "$CLOUD/m/theirs.txt"
out=$(ferry sync m 2>&1); rc=$?
check 'sync exits 0' '0' "$rc"
check 'local edit went up' 'edited here' "$(cat "$CLOUD/m/doc.txt")"
check 'cloud file came down' 'theirs' "$(cat "$WORK/m/theirs.txt" 2>&1)"
check 'clean afterwards' '=' "$(symbol_of m)"

printf '\n== deletions do not propagate: the union returns ==\n'
reset_tree; synced_unit d
printf 'keep\n' > "$WORK/d/extra.txt"
ferry push d >/dev/null 2>&1
rm "$WORK/d/doc.txt"                  # deleted here
rm "$CLOUD/d/extra.txt"               # deleted there
check 'sync exits 0' '0' "$(ferry sync d >/dev/null 2>&1; echo $?)"
check 'local deletion restored' 'original' "$(cat "$WORK/d/doc.txt" 2>&1)"
check 'cloud deletion restored' 'keep' "$(cat "$CLOUD/d/extra.txt" 2>&1)"
check 'clean afterwards' '=' "$(symbol_of d)"

printf '\n== a conflict blocks only itself ==\n'
reset_tree; synced_unit c
printf 'safe\n' > "$WORK/c/clean.txt"
printf 'edited here\n' > "$WORK/c/doc.txt"
printf 'edited there\n' > "$CLOUD/c/doc.txt"
out=$(ferry sync c 2>&1); rc=$?
check 'sync exits non-zero' '1' "$rc"
check 'clean file still crossed' 'safe' "$(cat "$CLOUD/c/clean.txt" 2>&1)"
check 'local side untouched' 'edited here' "$(cat "$WORK/c/doc.txt")"
check 'cloud side untouched' 'edited there' "$(cat "$CLOUD/c/doc.txt")"
check 'conflict named' 'yes' "$(grep -q 'doc.txt' <<<"$out" && echo yes || echo no)"
check 'points at resolve' 'yes' "$(grep -q 'resolve' <<<"$out" && echo yes || echo no)"
# The carried ancestor keeps the conflict visible across the re-baseline.
check 'still classified a conflict' '<>' "$(symbol_of c)"
check '  as both' 'both edit doc.txt' "$(detail_of c)"
# resolve still stages the cloud side after the partial sync.
ferry resolve c >/dev/null 2>&1
check 'resolve still stages it' 'edited there' \
    "$(cat "$(state_of c)/conflict/doc.txt" 2>&1)"

printf '\n== a hand-reconciled conflict re-baselines on the next sync ==\n'
# Adopt the cloud version: content now agrees, but the manifest still holds the
# old ancestor. The next sync must refresh it, or the following edit would
# read 'both' against a stale ancestor.
cp "$CLOUD/c/doc.txt" "$WORK/c/doc.txt"
check 'sync after reconciling exits 0' '0' "$(ferry sync c >/dev/null 2>&1; echo $?)"
printf 'later edit\n' > "$WORK/c/doc.txt"
check 'next edit reads local, not both' 'local edit doc.txt' "$(detail_of c)"

# Same path, but with a `status` between the reconcile and the sync — the
# everyday order. `status` writes a clean prompt bit over agreeing content
# whatever the manifest holds, so the bit must not gate the re-record.
reset_tree; synced_unit s
printf 'edited here\n' > "$WORK/s/doc.txt"
printf 'edited there\n' > "$CLOUD/s/doc.txt"
ferry sync s >/dev/null 2>&1
cp "$CLOUD/s/doc.txt" "$WORK/s/doc.txt"       # reconcile by hand
symbol_of s >/dev/null                        # ... then look before syncing
ferry sync s >/dev/null 2>&1
printf 'later edit\n' > "$WORK/s/doc.txt"
check 'status before sync still re-records' 'local edit doc.txt' "$(detail_of s)"

printf '\n== awkward names and same-size edits survive the targeted transfers ==\n'
# sync moves explicit path lists (--files-from-raw on stdin, --ignore-times):
# names rclone's plain --files-from would drop must round-trip, and a cloud
# edit of the same size with a restored mtime must still come down.
reset_tree; synced_unit w
for n in 'spa ced.txt' ' lead.txt' '#hash.txt'; do printf 'a\n' > "$WORK/w/$n"; done
ferry push w >/dev/null 2>&1
for n in 'spa ced.txt' ' lead.txt' '#hash.txt'; do printf 'B\n' > "$WORK/w/$n"; done
touch -r "$CLOUD/w/doc.txt" "$SANDBOX/stamp"
printf 'ORIGINAL\n' > "$CLOUD/w/doc.txt"          # same 9 bytes as 'original'
touch -r "$SANDBOX/stamp" "$CLOUD/w/doc.txt"
check 'sync exits 0' '0' "$(ferry sync w >/dev/null 2>&1; echo $?)"
check 'same-size cloud edit came down' 'ORIGINAL' "$(cat "$WORK/w/doc.txt")"
check 'leading-space name went up' 'B' "$(cat "$CLOUD/w/ lead.txt" 2>&1)"
check 'hash-prefixed name went up' 'B' "$(cat "$CLOUD/w/#hash.txt" 2>&1)"
check 'spaced name went up' 'B' "$(cat "$CLOUD/w/spa ced.txt" 2>&1)"
check 'clean afterwards' '=' "$(symbol_of w)"

printf '\n== never synced from this machine: refused, with a way out ==\n'
reset_tree; synced_unit x
rm -rf "$(state_of x)"
out=$(ferry sync x 2>&1); rc=$?
check 'sync refuses' '1' "$rc"
check 'names the escape hatch' 'yes' "$(grep -q 'push --force' <<<"$out" && echo yes || echo no)"
check 'local untouched' 'original' "$(cat "$WORK/x/doc.txt")"

printf '\n== flags stay with the directional verbs ==\n'
reset_tree; synced_unit f
check '--mirror rejected' '1' "$(ferry sync --mirror f >/dev/null 2>&1; echo $?)"
check '--force rejected' '1' "$(ferry sync --force f >/dev/null 2>&1; echo $?)"

printf '\n== a git unit syncs its bundle ==\n'
reset_tree
ferry new g >/dev/null
git -C "$WORK/g" init -q
printf 'v1\n' > "$WORK/g/doc.txt"
git -C "$WORK/g" add doc.txt >/dev/null 2>&1
git -C "$WORK/g" -c user.email=t@t -c user.name=t commit -qm first >/dev/null 2>&1
check 'sync exits 0' '0' "$(ferry sync g >/dev/null 2>&1; echo $?)"
check 'bundle reached the cloud' 'yes' "$([ -f "$CLOUD/g/history.bundle" ] && echo yes || echo no)"

printf '\n== the walk converges every unit and tallies conflicts ==\n'
reset_tree; synced_unit u1; synced_unit u2
printf 'edited here\n' > "$WORK/u1/doc.txt"
printf 'edited here\n' > "$WORK/u2/doc.txt"
printf 'edited there\n' > "$CLOUD/u2/doc.txt"
out=$(ferry sync 2>&1); rc=$?
check 'walk exit status' '1' "$rc"
check 'walk tally' 'yes' "$(grep -q '1/2 ok' <<<"$out" && echo yes || echo no)"
check 'clean unit converged' 'edited here' "$(cat "$CLOUD/u1/doc.txt")"
check 'conflicted unit untouched' 'edited there' "$(cat "$CLOUD/u2/doc.txt")"

printf '\n== sync never enrols what it did not carry ==\n'
# A file landing on the cloud while sync runs (another machine's push) must
# not enter the manifest as shared: local never received it, and a shared
# entry would misread its absence as a local deletion. Rate-limit rclone so
# the mid-transfer window is real rather than a race the test usually loses.
reset_tree; synced_unit r
head -c 3000000 /dev/urandom > "$WORK/r/payload.bin"
( sleep 1; printf 'raced\n' > "$CLOUD/r/raced.txt" ) &
RCLONE_BWLIMIT=1M ferry sync r >/dev/null 2>&1
wait
check 'mid-sync arrival not enrolled as shared' 'no' \
    "$(grep -q ' raced.txt$' "$(state_of r)/manifest" && echo yes || echo no)"
check 'it reads as a cloud-side add' '<' "$(symbol_of r)"
check '  classified' 'remote add raced.txt' "$(detail_of r)"

report

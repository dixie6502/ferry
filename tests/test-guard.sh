#!/usr/bin/env bash
#
# Transfer-guard tests: a diverged unit must refuse to push or pull unless
# --force is given, and everything else must stay frictionless.
#
# Real rclone against a real backend (`:local:`), same sandbox as test-drift.sh.
#
# Usage: tests/test-guard.sh        (from anywhere; scratch lands in tmp/)

set -uo pipefail

SUITE_TMP=tg
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

printf '\n== a diverged unit refuses to transfer ==\n'
reset_tree; synced_unit m; diverge m
out=$(ferry push m 2>&1); rc=$?
check 'push exit status' '1' "$rc"
check 'push names the conflict' 'yes' "$(grep -q 'diverged' <<<"$out" && echo yes || echo no)"
check 'push lists the file' 'yes' "$(grep -q 'doc.txt' <<<"$out" && echo yes || echo no)"
check 'cloud left untouched' 'edited there' "$(cat "$CLOUD/m/doc.txt")"

reset_tree; synced_unit m; diverge m          # fresh conflict: the push above mutated one side
out=$(ferry pull m 2>&1); rc=$?
check 'pull exit status' '1' "$rc"
check 'local left untouched' 'edited here' "$(cat "$WORK/m/doc.txt")"

printf '\n== --force overrides ==\n'
reset_tree; synced_unit m; diverge m
ferry push --force m >/dev/null 2>&1
check 'forced push wins' 'edited here' "$(cat "$CLOUD/m/doc.txt")"

reset_tree; synced_unit m; diverge m
ferry pull --force m >/dev/null 2>&1
check 'forced pull wins' 'edited there' "$(cat "$WORK/m/doc.txt")"

printf '\n== non-diverged transfers stay frictionless ==\n'
reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/doc.txt"
ferry push m >/dev/null 2>&1
check 'local-ahead push' 'edited here' "$(cat "$CLOUD/m/doc.txt")"

reset_tree; synced_unit m
printf 'edited there\n' > "$CLOUD/m/doc.txt"
ferry pull m >/dev/null 2>&1
check 'cloud-ahead pull' 'edited there' "$(cat "$WORK/m/doc.txt")"

reset_tree
ferry new fresh >/dev/null
printf 'brand new\n' > "$WORK/fresh/doc.txt"
ferry push fresh >/dev/null 2>&1
check 'first push of a new unit' 'brand new' "$(cat "$CLOUD/fresh/doc.txt")"

reset_tree
mkdir -p "$CLOUD/cloudonly"; printf 'from the cloud\n' > "$CLOUD/cloudonly/doc.txt"
ferry pull cloudonly >/dev/null 2>&1
check 'first pull of a cloud-only unit' 'from the cloud' "$(cat "$WORK/cloudonly/doc.txt")"

printf '\n== a walk carries on past a diverged unit ==\n'
reset_tree; synced_unit u1; synced_unit u2
printf 'edited here\n' > "$WORK/u1/doc.txt"
diverge u2
out=$(ferry push 2>&1); rc=$?
check 'walk exit status' '1' "$rc"
check 'walk tally' 'yes' "$(grep -q '1/2 ok' <<<"$out" && echo yes || echo no)"
check 'clean unit still pushed' 'edited here' "$(cat "$CLOUD/u1/doc.txt")"
check 'diverged unit untouched' 'edited there' "$(cat "$CLOUD/u2/doc.txt")"

printf '\n== a transfer must run with the drift, mirror or not ==\n'
# `transfer` is an rclone copy: it overwrites the destination on any difference,
# newer or not, so going against the drift destroys the far side's work even
# without --mirror.
reset_tree; synced_unit m
printf 'unpushed work\n' > "$WORK/m/doc.txt"
out=$(ferry pull m 2>&1); rc=$?
check 'plain pull over a local edit' '1' "$rc"
check '  local work kept' 'unpushed work' "$(cat "$WORK/m/doc.txt")"

reset_tree; synced_unit m
printf 'their work\n' > "$CLOUD/m/doc.txt"
out=$(ferry push m 2>&1); rc=$?
check 'plain push over a cloud edit' '1' "$rc"
check '  cloud work kept' 'their work' "$(cat "$CLOUD/m/doc.txt")"

printf '\n== a plain copy cannot touch one-sided files, so they do not block ==\n'
# A pull overwrites only files that exist on both sides. A file deleted here is
# simply brought back; a file added here is not on the remote at all.
reset_tree; synced_unit m
printf 'keep\n' > "$WORK/m/other.txt"; ferry push m >/dev/null 2>&1
rm "$WORK/m/doc.txt"
out=$(ferry pull m 2>&1); rc=$?
check 'local delete does not block pull' '0' "$rc"
check '  the pull restored it' 'original' "$(cat "$WORK/m/doc.txt" 2>&1)"

reset_tree; synced_unit m
printf 'mine, unpushed\n' > "$WORK/m/new.txt"
printf 'theirs\n' > "$CLOUD/m/from-cloud.txt"
out=$(ferry pull m 2>&1); rc=$?
check 'local-only file does not block pull' '0' "$rc"
check '  it survived the pull' 'mine, unpushed' "$(cat "$WORK/m/new.txt")"
check '  and the cloud file arrived' 'theirs' "$(cat "$WORK/m/from-cloud.txt")"

reset_tree; synced_unit m
printf 'theirs\n' > "$CLOUD/m/from-cloud.txt"
out=$(ferry push m 2>&1); rc=$?
check 'cloud-only file does not block push' '0' "$rc"
check '  it survived the push' 'theirs' "$(cat "$CLOUD/m/from-cloud.txt")"

# The edit case must still block — that is the one a copy would destroy.
reset_tree; synced_unit m
printf 'unpushed edit\n' > "$WORK/m/doc.txt"
out=$(ferry pull m 2>&1); rc=$?
check 'local edit still blocks pull' '1' "$rc"
check '  the edit survived' 'unpushed edit' "$(cat "$WORK/m/doc.txt")"

# --mirror keeps the stronger rule: it deletes, so one-sided files matter.
reset_tree; synced_unit m
printf 'mine, unpushed\n' > "$WORK/m/new.txt"
out=$(ferry pull --mirror m 2>&1); rc=$?
check 'local-only file blocks pull --mirror' '1' "$rc"
check '  it survived' 'mine, unpushed' "$(cat "$WORK/m/new.txt")"

reset_tree; synced_unit m
printf 'theirs\n' > "$CLOUD/m/from-cloud.txt"
out=$(ferry push --mirror m 2>&1); rc=$?
check 'cloud-only file blocks push --mirror' '1' "$rc"
check '  it survived' 'theirs' "$(cat "$CLOUD/m/from-cloud.txt")"

printf '\n== --mirror follows the same rule ==\n'
# Deleting on the far side is only safe toward the side that is behind.
reset_tree; synced_unit m
printf 'edited there\n' > "$CLOUD/m/doc.txt"
out=$(ferry push --mirror m 2>&1); rc=$?
check 'push --mirror while cloud is ahead' '1' "$rc"
check '  cloud kept its version' 'edited there' "$(cat "$CLOUD/m/doc.txt")"

reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/doc.txt"
out=$(ferry pull --mirror m 2>&1); rc=$?
check 'pull --mirror while local is ahead' '1' "$rc"
check '  local kept its version' 'edited here' "$(cat "$WORK/m/doc.txt")"

reset_tree; synced_unit m
printf 'extra\n' > "$WORK/m/extra.txt"
ferry push --mirror m >/dev/null 2>&1
check 'push --mirror while local is ahead' 'extra' "$(cat "$CLOUD/m/extra.txt")"

reset_tree; synced_unit m
printf 'extra\n' > "$CLOUD/m/extra.txt"
ferry pull --mirror m >/dev/null 2>&1
check 'pull --mirror while cloud is ahead' 'extra' "$(cat "$WORK/m/extra.txt")"

printf '\n== drop warns from the same classifier ==\n'
reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/doc.txt"
out=$(ferry drop -y m 2>&1)
check 'unpushed local edit warns' 'yes' "$(grep -qi 'not on the cloud' <<<"$out" && echo yes || echo no)"

reset_tree; synced_unit m
printf 'edited there\n' > "$CLOUD/m/doc.txt"
out=$(ferry drop -y m 2>&1)
check 'cloud-only edit does not warn' 'no' "$(grep -qi 'not on the cloud' <<<"$out" && echo yes || echo no)"

printf '\n== destructive verbs never guess when the cloud is unreadable ==\n'
reset_tree; synced_unit m
chmod 000 "$CLOUD/m"
out=$(ferry rm -y m 2>&1); rc=$?
check 'rm refuses' '1' "$rc"
check '  says it cannot reach the cloud' 'yes' "$(grep -qi 'cannot reach the cloud' <<<"$out" && echo yes || echo no)"
check '  local copy kept' 'yes' "$([ -d "$WORK/m" ] && echo yes || echo no)"
chmod 755 "$CLOUD/m"
# The name exists on the cloud but cannot be listed: "not there" is not the
# answer, so `new` must not claim the name and write a sync baseline for it.
mkdir -p "$CLOUD/m2"; chmod 000 "$CLOUD/m2"
out=$(ferry new m2 2>&1); rc=$?
chmod 755 "$CLOUD/m2"
check 'new refuses' '1' "$rc"
check '  says it cannot reach the cloud' 'yes' "$(grep -qi 'cannot reach the cloud' <<<"$out" && echo yes || echo no)"
check '  created nothing' 'no' "$([ -d "$WORK/m2" ] && echo yes || echo no)"

report

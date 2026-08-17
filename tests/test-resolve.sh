#!/usr/bin/env bash
#
# `ferry resolve` tests: surface a conflict as files you can diff, without
# touching either side of it.
#
# Real rclone against a real backend (`:local:`), same sandbox shape as the
# other suites.
#
# Usage: tests/test-resolve.sh        (from anywhere; scratch lands in tmp/)

set -uo pipefail

SUITE_TMP=tr
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

stage_of() { printf '%s/conflict' "$(state_of "$1")"; }

printf '\n== resolve stages the cloud side of a conflict ==\n'
reset_tree; synced_unit m; diverge m
out=$(ferry resolve m 2>&1); rc=$?
check 'exit status' '0' "$rc"
check 'staged the cloud version' 'edited there' "$(cat "$(stage_of m)/doc.txt" 2>&1)"
check 'local side untouched' 'edited here' "$(cat "$WORK/m/doc.txt")"
check 'cloud side untouched' 'edited there' "$(cat "$CLOUD/m/doc.txt")"
check 'names the staging path' 'yes' "$(grep -qF "$(stage_of m)" <<<"$out" && echo yes || echo no)"
check 'lists the conflicting file' 'yes' "$(grep -q 'doc.txt' <<<"$out" && echo yes || echo no)"

printf '\n== staging never lands inside the unit ==\n'
check 'unit holds only its own files' 'doc.txt' \
    "$(cd "$WORK/m" && find . -type f ! -name .ferry -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"

printf '\n== resolving then pushing clears the conflict ==\n'
# Adopt the cloud version as the resolution, the way a user would after diffing.
cp "$(stage_of m)/doc.txt" "$WORK/m/doc.txt"
ferry push m >/dev/null 2>&1
check 'push now allowed' '0' "$?"
check 'cloud has the resolution' 'edited there' "$(cat "$CLOUD/m/doc.txt")"
check 'status is clean' '=' "$(ferry status m 2>/dev/null | awk 'NR==1{print $1}')"

printf '\n== nothing to resolve ==\n'
reset_tree; synced_unit c
out=$(ferry resolve c 2>&1); rc=$?
check 'clean unit exits 0' '0' "$rc"
check 'says there is no conflict' 'yes' "$(grep -qi 'no conflict' <<<"$out" && echo yes || echo no)"
check 'stages nothing' 'no' "$([ -d "$(stage_of c)" ] && echo yes || echo no)"

printf '\n== diverged on different files: stage what the cloud changed ==\n'
# Advising 'pull --force then push --force' here would revert the local edit:
# rclone copy overwrites on any difference, newer or not. Staging the cloud's
# file instead lets the user take it without losing their own.
reset_tree; synced_unit d
printf 'here\n' > "$WORK/d/mine.txt"
printf 'there\n' > "$CLOUD/d/theirs.txt"
out=$(ferry resolve d 2>&1); rc=$?
check 'exits 0' '0' "$rc"
check 'stages the cloud-changed file' 'there' "$(cat "$(stage_of d)/theirs.txt" 2>&1)"
check 'labels it as cloud-side' 'yes' "$(grep -q 'theirs.txt   (added on the cloud)' <<<"$out" && echo yes || echo no)"
check 'does not stage our own file' 'no' "$([ -e "$(stage_of d)/mine.txt" ] && echo yes || echo no)"
check 'leaves our edit alone' 'here' "$(cat "$WORK/d/mine.txt")"
check 'advises push --force' 'yes' "$(grep -q "push --force" <<<"$out" && echo yes || echo no)"

printf '\n== a second run does not keep stale files ==\n'
reset_tree; synced_unit m
printf 'here\n' > "$WORK/m/one.txt"; printf 'there\n' > "$CLOUD/m/one.txt"
ferry resolve m >/dev/null 2>&1
check 'first run staged one.txt' 'one.txt' "$(cd "$(stage_of m)" && find . -type f -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"
# Resolve that file, create a different conflict, resolve again.
cp "$(stage_of m)/one.txt" "$WORK/m/one.txt"; ferry push m >/dev/null 2>&1
printf 'here\n' > "$WORK/m/two.txt"; printf 'there\n' > "$CLOUD/m/two.txt"
ferry resolve m >/dev/null 2>&1
check 'second run staged only two.txt' 'two.txt' "$(cd "$(stage_of m)" && find . -type f -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"

printf '\n== drop takes the staging area with it ==\n'
ferry drop -y m >/dev/null 2>&1
check 'staging removed with the unit' 'no' "$([ -d "$(stage_of m)" ] && echo yes || echo no)"

printf '\n== a git unit gets its merge-base hint ==\n'
reset_tree
ferry new g >/dev/null
git -C "$WORK/g" init -q
printf 'v1\n' > "$WORK/g/doc.txt"
git -C "$WORK/g" add doc.txt >/dev/null 2>&1
git -C "$WORK/g" -c user.email=t@t -c user.name=t commit -qm first >/dev/null 2>&1
ferry push g >/dev/null 2>&1
# Both sides move on: a new commit here, a different bundle there.
printf 'v2\n' > "$WORK/g/doc.txt"
git -C "$WORK/g" -c user.email=t@t -c user.name=t commit -qam second >/dev/null 2>&1
printf 'other history\n' > "$CLOUD/g/history.bundle"
printf 'v3\n' > "$CLOUD/g/doc.txt"
out=$(ferry resolve g 2>&1)
check 'mentions the bundle' 'yes' "$(grep -q 'history.bundle' <<<"$out" && echo yes || echo no)"
check 'offers a git fetch' 'yes' "$(grep -q 'git -C' <<<"$out" && echo yes || echo no)"

printf '\n== filenames rclone would otherwise drop ==\n'
# Plain --files-from reads a leading '#' or ';' as a comment and trims spaces.
reset_tree
ferry new f >/dev/null
for n in 'plain.txt' '#hash.txt' ' lead.txt' 'spa ced.txt'; do printf 'v1\n' > "$WORK/f/$n"; done
ferry push f >/dev/null 2>&1
for n in 'plain.txt' '#hash.txt' ' lead.txt' 'spa ced.txt'; do
    printf 'here\n' > "$WORK/f/$n"; printf 'there\n' > "$CLOUD/f/$n"
done
ferry resolve f >/dev/null 2>&1
check 'every conflicting file staged' '4' "$(find "$(stage_of f)" -type f | wc -l)"
check '  hash-prefixed name' 'there' "$(cat "$(stage_of f)/#hash.txt" 2>&1)"
check '  leading-space name' 'there' "$(cat "$(stage_of f)/ lead.txt" 2>&1)"

printf '\n== a file deleted on the cloud is not announced as staged ==\n'
# rclone reports "nothing to transfer" as success, so trusting its exit status
# would have ferry point at a staging dir that never received the file.
reset_tree
ferry new b >/dev/null
git -C "$WORK/b" init -q
printf 'v1\n' > "$WORK/b/doc.txt"
git -C "$WORK/b" add doc.txt >/dev/null 2>&1
git -C "$WORK/b" -c user.email=t@t -c user.name=t commit -qm first >/dev/null 2>&1
ferry push b >/dev/null 2>&1
rm "$CLOUD/b/history.bundle"          # the cloud dropped the bundle
printf 'edited\n' > "$WORK/b/doc.txt"  # and we changed something here
out=$(ferry resolve b 2>&1); rc=$?
check 'exits 0' '0' "$rc"
check 'reports it as a cloud-side deletion' 'yes' "$(grep -q 'remote delete .*history.bundle' <<<"$out" && echo yes || echo no)"
check 'offers no broken git fetch' 'no' "$(grep -q 'git -C' <<<"$out" && echo yes || echo no)"

report

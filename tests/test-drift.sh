#!/usr/bin/env bash
#
# Drift-classification tests for `ferry status`.
#
# Real rclone against a real backend: the cloud side is a plain directory
# addressed as `:local:<path>`, an rclone connection string. No mocks, and no
# way to reach the user's configured remotes.
#
# Usage: tests/test-drift.sh        (from anywhere; scratch lands in tmp/)

set -uo pipefail

readonly REPO=$(cd "$(dirname "$0")/.." && pwd -P)
readonly FERRY=$REPO/ferry
readonly SANDBOX=$REPO/tmp/t
readonly WORK=$SANDBOX/work
readonly CLOUD=$SANDBOX/cloud/Projects

export XDG_CACHE_HOME=$SANDBOX/cache   # keep the real ~/.cache/ferry untouched

pass=0 fail=0

# Reset the whole sandbox and re-init the tree root.
reset_tree() {
    rm -rf "$SANDBOX"
    mkdir -p "$WORK" "$CLOUD"
    (cd "$WORK" && "$FERRY" init ":local:$CLOUD" >/dev/null)
}

ferry() { (cd "$WORK" && "$FERRY" "$@"); }

# ferry keys its state by remote base + unit path; mirror that here.
state_of() {
    local base=":local:$CLOUD" key='' i c
    for (( i = 0; i < ${#base}; i++ )); do
        c=${base:i:1}
        case $c in
            [A-Za-z0-9._-]) key+=$c ;;
            *) printf -v c '%%%02X' "'$c"; key+=$c ;;
        esac
    done
    printf '%s/ferry/%s%s' "$XDG_CACHE_HOME" "$key" "${1:+/$1}"
}

# The drift symbol ferry reports for a unit (first field of its status row).
symbol_of() { ferry status "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

# The per-file classification lines, "class path" each, sorted.
detail_of() { ferry status "$1" 2>/dev/null | awk 'NR>1{print $1, $2, $3}' | sort; }

check() {
    local label=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  ok    %-46s %s\n' "$label" "$got"
    else
        fail=$((fail + 1)); printf '  FAIL  %-46s want %-4s got %s\n' "$label" "$want" "$got"
    fi
}

# A unit pushed once, holding one file — the baseline every drift case starts from.
synced_unit() {
    local name=$1
    ferry new "$name" >/dev/null
    printf 'original\n' > "$WORK/$name/doc.txt"
    ferry push "$name" >/dev/null 2>&1
}

printf '\n== lifecycle ==\n'
reset_tree
ferry new demo >/dev/null
check 'new unit, empty, no cloud prefix' '=' "$(symbol_of demo)"
printf 'original\n' > "$WORK/demo/doc.txt"
check 'unpushed content, no cloud prefix' '>' "$(symbol_of demo)"
ferry push demo >/dev/null 2>&1
check 'after push' '=' "$(symbol_of demo)"
ferry pull demo >/dev/null 2>&1
check 'after pull' '=' "$(symbol_of demo)"

printf '\n== modification (the case that used to read as divergence) ==\n'
reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/doc.txt"
check 'local edit of an existing file' '>' "$(symbol_of m)"
check '  classified' 'local edit doc.txt' "$(detail_of m)"

reset_tree; synced_unit m
printf 'edited there\n' > "$CLOUD/m/doc.txt"
check 'cloud edit of an existing file' '<' "$(symbol_of m)"
check '  classified' 'remote edit doc.txt' "$(detail_of m)"

reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/doc.txt"
printf 'edited there\n' > "$CLOUD/m/doc.txt"
check 'both sides edit the same file' '<>' "$(symbol_of m)"
check '  classified' 'both edit doc.txt' "$(detail_of m)"

reset_tree; synced_unit m
printf 'edited here\n' > "$WORK/m/mine.txt"
printf 'edited there\n' > "$CLOUD/m/theirs.txt"
check 'each side edits a different file' '<>' "$(symbol_of m)"
check '  classified' 'local add mine.txt
remote add theirs.txt' "$(detail_of m)"

printf '\n== additions ==\n'
reset_tree; synced_unit a
printf 'new\n' > "$WORK/a/added.txt"
check 'file added locally' '>' "$(symbol_of a)"
check '  classified' 'local add added.txt' "$(detail_of a)"

reset_tree; synced_unit a
printf 'new\n' > "$CLOUD/a/added.txt"
check 'file added on the cloud' '<' "$(symbol_of a)"
check '  classified' 'remote add added.txt' "$(detail_of a)"

printf '\n== deletions ==\n'
reset_tree; synced_unit d
rm "$WORK/d/doc.txt"
check 'file deleted locally' '>' "$(symbol_of d)"
check '  classified' 'local delete doc.txt' "$(detail_of d)"

reset_tree; synced_unit d
rm "$CLOUD/d/doc.txt"
check 'file deleted on the cloud' '<' "$(symbol_of d)"
check '  classified' 'remote delete doc.txt' "$(detail_of d)"

printf '\n== no baseline on this machine ==\n'
reset_tree; synced_unit n
rm -rf "$(state_of n)"
check 'both sides populated, no baseline' '<>' "$(symbol_of n)"
reset_tree; synced_unit n
rm -rf "$(state_of n)" "$WORK/n"/*.txt
check 'nothing local to lose, no baseline' '<' "$(symbol_of n)"

printf '\n== a bare touch is not a change (content check rules) ==\n'
reset_tree; synced_unit t
touch "$WORK/t/doc.txt"
check 'touched but identical' '=' "$(symbol_of t)"

printf '\n== multiple units ==\n'
reset_tree
synced_unit u1; synced_unit u2
printf 'edited\n' > "$WORK/u2/doc.txt"
check 'walk reports each unit' '= u1
> u2' "$(ferry status 2>/dev/null | awk '{print $1, $2}')"

printf '\n== one-sided files are attributed from the sync manifest ==\n'
# A file created on another machine long ago and only pushed now: its mtime
# predates our baseline, so the surviving copy's mtime alone would call it a
# local deletion — and `push --mirror` would then delete it from the cloud.
reset_tree; synced_unit x
printf 'from the other machine\n' > "$CLOUD/x/late.txt"
touch -d '2020-01-01' "$CLOUD/x/late.txt"
check 'cloud file pushed late (old mtime)' '<' "$(symbol_of x)"
check '  classified' 'remote add late.txt' "$(detail_of x)"

# The mirror image: added here with a preserved mtime (cp -p, unzip, tar -x).
reset_tree; synced_unit x
printf 'extracted\n' > "$WORK/x/old.txt"
touch -d '2020-01-01' "$WORK/x/old.txt"
check 'local file with a preserved old mtime' '>' "$(symbol_of x)"
check '  classified' 'local add old.txt' "$(detail_of x)"

# Same file, but with unrelated local activity in the directory. A directory
# mtime is too coarse to attribute a specific file: one unrelated add stamps the
# directory for every file in it, which would forge the deletion verdict again.
reset_tree; synced_unit x
printf 'from the other machine\n' > "$CLOUD/x/late.txt"
touch -d '2020-01-01' "$CLOUD/x/late.txt"
printf 'unrelated\n' > "$WORK/x/mine.txt"          # stamps the unit directory
check 'cloud file + unrelated local add' '<>' "$(symbol_of x)"
check '  classified' 'local add mine.txt
remote add late.txt' "$(detail_of x)"

# A whole local subdirectory deleted: the directory that would carry the stamp
# no longer exists, so its files must be attributed from the manifest instead.
reset_tree
ferry new s >/dev/null
mkdir -p "$WORK/s/sub"; printf 'v1\n' > "$WORK/s/sub/deep.txt"; printf 'v1\n' > "$WORK/s/top.txt"
ferry push s >/dev/null 2>&1
rm -rf "$WORK/s/sub"
check 'local subdirectory deleted' '>' "$(symbol_of s)"
check '  classified' 'local delete sub/deep.txt' "$(detail_of s)"
ferry push --mirror s >/dev/null 2>&1
check '  push --mirror propagates it' 'no' "$([ -e "$CLOUD/s/sub/deep.txt" ] && echo yes || echo no)"

# A file added locally and never pushed must not read as a cloud deletion after
# a later sync records it: the manifest holds what was on BOTH sides, not ours.
reset_tree; synced_unit u
printf 'never pushed\n' > "$WORK/u/mine.txt"
ferry pull u >/dev/null 2>&1                       # syncs, but mine.txt never went up
check 'local-only file after a pull' '>' "$(symbol_of u)"
check '  classified' 'local add mine.txt' "$(detail_of u)"

# Deleted on the cloud AND edited here: a conflict, not a clean cloud deletion.
# Reading only the manifest would call it 'remote' and let a --mirror pull erase
# the local edit.
reset_tree; synced_unit e
rm "$CLOUD/e/doc.txt"
printf 'edited here, never pushed\n' > "$WORK/e/doc.txt"
check 'dropped there, edited here' '<>' "$(symbol_of e)"
check '  classified' 'both delete doc.txt' "$(detail_of e)"

# A file written *during* a transfer never crossed, so it must not enter the
# manifest as shared — the snapshot is taken before the transfer starts. Rate-limit
# rclone so the window is real rather than a race the test usually loses.
reset_tree
ferry new r >/dev/null
head -c 3000000 /dev/urandom > "$WORK/r/payload.bin"
( sleep 1; printf 'written mid-transfer\n' > "$WORK/r/during.txt" ) &
RCLONE_BWLIMIT=1M ferry push r >/dev/null 2>&1
wait
check 'file created during a push' '>' "$(symbol_of r)"
check '  classified' 'local add during.txt' "$(detail_of r)"

printf '\n== an unreadable cloud subtree is never read as sync ==\n'
reset_tree; synced_unit y
mkdir -p "$CLOUD/y/sub"; printf 'hidden\n' > "$CLOUD/y/sub/f.txt"
chmod 000 "$CLOUD/y/sub"
before=$(cat "$(state_of y)/remote")
check 'unreadable subtree reports unknown' '?' "$(symbol_of y)"
check '  stored bit left untouched' "$before" "$(cat "$(state_of y)/remote")"
chmod 755 "$CLOUD/y/sub"

printf '\n== paths with whitespace survive parsing ==\n'
reset_tree
ferry new z >/dev/null
printf 'a\n' > "$WORK/z/ lead.txt"
ferry push z >/dev/null 2>&1
printf 'b\n' > "$WORK/z/ lead.txt"
check 'leading space: symbol' '>' "$(symbol_of z)"
check 'leading space: path intact' '    local  edit    lead.txt' "$(ferry status z 2>/dev/null | sed -n '2p')"

printf '\n== the sync'"'"'s own writes are not post-sync changes ==\n'
# The baseline is stamped at completion: the marker, a restored .git, and (on
# backends that cannot set a destination modtime) the transferred objects all
# land after the transfer starts, and would read as drift from an earlier stamp.
reset_tree; synced_unit w
printf 'cloud side\n' > "$CLOUD/w/doc.txt"
ferry pull w >/dev/null 2>&1
check 'clean right after a pull' '=' "$(symbol_of w)"

reset_tree
ferry new v >/dev/null
printf 'v1\n' > "$WORK/v/doc.txt"
RCLONE_LOCAL_NO_SET_MODTIME=true ferry push v >/dev/null 2>&1
check 'clean after a modtime-less push' '=' "$(symbol_of v)"
printf 'edited here\n' > "$WORK/v/doc.txt"
check 'later local edit still reads local' '>' "$(symbol_of v)"

printf '\n== two remotes, one unit name, separate state ==\n'
# The key must be injective: substituting unsafe bytes with '_' maps the two
# bases below onto one directory, and each tree would answer with the other's
# manifest.
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX/w1" "$SANDBOX/w2" "$SANDBOX/c/a_b" "$SANDBOX/c/a/b"
(cd "$SANDBOX/w1" && "$FERRY" init ":local:$SANDBOX/c/a_b" >/dev/null \
    && "$FERRY" new p >/dev/null && printf 'one\n' > p/doc.txt && "$FERRY" push p >/dev/null 2>&1)
(cd "$SANDBOX/w2" && "$FERRY" init ":local:$SANDBOX/c/a/b" >/dev/null \
    && "$FERRY" new p >/dev/null && printf 'two\n' > p/doc.txt && printf 'x\n' > p/extra.txt \
    && "$FERRY" push p >/dev/null 2>&1)
check 'first tree still clean' '=' "$(cd "$SANDBOX/w1" && "$FERRY" status p 2>/dev/null | awk 'NR==1{print $1}')"
check 'second tree still clean' '=' "$(cd "$SANDBOX/w2" && "$FERRY" status p 2>/dev/null | awk 'NR==1{print $1}')"
check 'distinct state dirs' '2' "$(find "$XDG_CACHE_HOME/ferry" -maxdepth 1 -mindepth 1 -type d | wc -l)"

printf '\n== a side that cannot be listed fails the sync point ==\n'
# `ferry` runs main only when executed directly, so the helper can be exercised
# on its own. A failed listing must not quietly become an empty ancestor set.
# shellcheck source=/dev/null
( source "$FERRY"
  list_side remote ":local:$SANDBOX/definitely-not-here" >/dev/null 2>&1
  [ $? -ne 0 ] ) && r=ok || r=broken
check 'unlistable remote returns non-zero' 'ok' "$r"
( source "$FERRY"; list_side local "$SANDBOX/definitely-not-here" >/dev/null 2>&1; [ $? -ne 0 ] ) \
    && r=ok || r=broken
check 'unlistable local returns non-zero' 'ok' "$r"

printf '\n== prompt indicator agrees with status ==\n'
# shellcheck source=/dev/null
source "$REPO/ferry-prompt.sh"
prompt_of() { (cd "$WORK/$1" && __ferry_ps1 '%s'); }

reset_tree; synced_unit p
printf 'edited here\n' > "$WORK/p/doc.txt"
check 'local edit: status' '>' "$(symbol_of p)"
check 'local edit: prompt' '>' "$(prompt_of p)"

reset_tree; synced_unit p
printf 'edited there\n' > "$CLOUD/p/doc.txt"
check 'cloud edit: status' '<' "$(symbol_of p)"
check 'cloud edit: prompt' '<' "$(prompt_of p)"

ferry pull p >/dev/null 2>&1
check 'after pulling it: status' '=' "$(symbol_of p)"
check 'after pulling it: prompt' '=' "$(prompt_of p)"

reset_tree; synced_unit p
printf 'edited here\n' > "$WORK/p/doc.txt"
printf 'edited there\n' > "$CLOUD/p/doc.txt"
check 'diverged: status' '<>' "$(symbol_of p)"
check 'diverged: prompt' '<>' "$(prompt_of p)"

# A conflict only a content check can see: both sides differ, but neither file's
# mtime moved past the baseline. The prompt's own walk finds nothing — it must
# carry the 'diverged' bit `status` recorded instead of downgrading to '<'.
reset_tree; synced_unit p
printf 'edited there\n' > "$CLOUD/p/doc.txt"
touch -r "$(state_of p)/synced_at" -d '-1 hour' "$CLOUD/p/doc.txt" 2>/dev/null \
    || touch -d '-1 hour' "$CLOUD/p/doc.txt"
check 'same-mtime conflict: status' '<>' "$(symbol_of p)"
check 'same-mtime conflict: prompt keeps it' '<>' "$(prompt_of p)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

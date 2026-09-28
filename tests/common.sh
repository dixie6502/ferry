# Shared harness for the ferry test suites; each suite sets SUITE_TMP (its
# scratch subdir under tmp/) and sources this file.
#
# Real rclone against a real backend: the cloud side is a plain directory
# addressed as `:local:<path>`, an rclone connection string. No mocks, and no
# way to reach the user's configured remotes. XDG_CACHE_HOME is redirected
# into the sandbox so the real ~/.cache/ferry is untouched.

readonly REPO=$(cd "$(dirname "$0")/.." && pwd -P)
readonly FERRY=$REPO/ferry
readonly SANDBOX=$REPO/tmp/$SUITE_TMP
readonly WORK=$SANDBOX/work
readonly CLOUD=$SANDBOX/cloud/Projects

export XDG_CACHE_HOME=$SANDBOX/cache

pass=0 fail=0

# Reset the whole sandbox and re-init the tree root.
reset_tree() {
    rm -rf "$SANDBOX"
    mkdir -p "$WORK" "$CLOUD"
    (cd "$WORK" && "$FERRY" init ":local:$CLOUD" >/dev/null)
}

ferry() { (cd "$WORK" && "$FERRY" "$@"); }

# A unit's state dir, keyed the way ferry keys it — derived from ferry's own
# state_key (the script supports being sourced for exactly this) rather than
# re-encoding it here.
state_of() {
    local key
    key=$(source "$FERRY"; state_key ":local:$CLOUD")
    printf '%s/ferry/%s%s' "$XDG_CACHE_HOME" "$key" "${1:+/$1}"
}

# Every cloud file of a unit, one space-joined line.
cloud_of() { rclone lsf -R --files-only "$CLOUD/$1" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }

# The exit status and first stderr line of a run expected to fail, as
# "<status>|<line>".
failure_of() { local out rc=0; out=$(ferry "$@" 2>&1 >/dev/null) || rc=$?; printf '%s|%s' "$rc" "${out%%$'\n'*}"; }

# Rewrite a unit's manifest as v1: bare paths, no header, no hashes.
downgrade_manifest() { sed -E -i '1d; s/^[^ ]+ //' "$(state_of "$1")/manifest"; }

check() {
    local label=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  ok    %-46s %s\n' "$label" "$got"
    else
        fail=$((fail + 1)); printf '  FAIL  %-46s want %-4s got %s\n' "$label" "$want" "$got"
    fi
}

# A unit pushed once, holding one file — the baseline most cases start from.
synced_unit() {
    local name=$1
    ferry new "$name" >/dev/null
    printf 'original\n' > "$WORK/$name/doc.txt"
    ferry push "$name" >/dev/null 2>&1
}

# Both sides edit the same file: a genuine conflict.
diverge() {
    local name=$1
    printf 'edited here\n' > "$WORK/$name/doc.txt"
    printf 'edited there\n' > "$CLOUD/$name/doc.txt"
}

# The drift symbol ferry reports for a unit, and the classification behind it.
symbol_of() { ferry status "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
detail_of() { ferry status "$1" 2>/dev/null | awk 'NR>1{print $1, $2, $3}' | sort; }

report() {
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]
}

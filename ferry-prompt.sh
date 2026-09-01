# shellcheck shell=bash disable=SC2059   # $fmt is a caller-supplied printf format
# ferry prompt support — a git-prompt.sh analog for the `ferry` sync tool.
#
# Shows, in your shell prompt, how the working tree relates to its cloud copy,
# using the same compact vocabulary as git's upstream indicator:
#
#     =   in sync     — no local changes since last sync, and cloud not ahead
#     >   ahead       — you have local edits not yet pushed
#     <   behind      — the cloud has changes you have not pulled
#     <>  diverged    — both sides changed since the last sync
#     ?   unknown     — never synced from this machine (no baseline)
#
# Two facts drive it, mirroring how git stays fast and offline:
#
#   * The local side ('>') is computed live and offline, with no git: a single
#     `find` for anything newer than the synced_at marker that `ferry` drops at
#     each push/pull. Deleting a file bumps its parent directory's mtime, so
#     adds, deletes, renames and edits are all caught. This is git's index
#     stat-cache trick (size+mtime), not content hashing — fast enough to run on
#     every prompt. The cost: a bare `touch` reads as a change though `ferry
#     status` (which hashes) would call it identical, and the walk is O(tree)
#     when clean (no early exit). Both are acceptable for a prompt.
#
#   * The cloud side ('<') is only as fresh as your last `ferry status`, which
#     records a 'sync'/'behind'/'diverged' bit — exactly as git's '<' is only as fresh as
#     your last `git fetch`. A stale bit gets a trailing '?' once it is older
#     than FERRY_PS1_STALE seconds (default 86400 = 1 day; 0 disables the check),
#     so an '=' never silently lies about a cloud you have not checked lately.
#
# Unlike a fixed-depth layout, `ferry` discovers structure by markers: this
# function walks UP from $PWD to the nearest enclosing unit (an empty `.ferry`)
# and the tree root (a `.ferry` holding the remote base), the same two-walk model
# the `ferry` script uses. Output is empty unless $PWD is inside a unit.
#
# Enable (bash):
#     source /path/to/ferry-prompt.sh
#     PS1='\u@\h \W$(__ferry_ps1 " [%s]")\$ '
# Enable (zsh):
#     setopt PROMPT_SUBST
#     source /path/to/ferry-prompt.sh
#     PS1='%n@%m %c$(__ferry_ps1 " [%s]")%# '
#
# The argument is a printf format wrapping the symbol (%s); default " (%s)".

# Must match the constants in `ferry`; override only if you changed them there.
: "${FERRY_MARKER:=.ferry}"
: "${FERRY_IGNORE:=.ferryignore}"
: "${FERRY_STATE_ROOT:=${XDG_CACHE_HOME:-$HOME/.cache}/ferry}"
: "${FERRY_PS1_STALE:=86400}"

# Quote the characters `find -path` reads as glob metacharacters. Mirrors
# `ferry`'s escape_find_glob.
__ferry_ps1_escape() {
    local s=$1 out='' i c
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case $c in '\'|'['|']'|'*'|'?') out+='\' ;; esac
        out+=$c
    done
    printf '%s' "$out"
}

# Compile the tree-root and unit `.ferryignore` files into `find` prune
# predicates, appended to the caller's `prune` array.
#
# This duplicates `ferry`'s compile_ignore, deliberately and by the same
# reasoning that keeps the rest of this file standalone: the local half of the
# indicator must stay a single offline `find`, with no `ferry` process per
# prompt. Ignoring the rules instead is not an option — an ignored file would
# leave '>' stuck on a clean unit forever. The grammar is small enough that the
# two copies are checkable against each other; keep them in step. A line this
# cannot compile is skipped rather than reported — a prompt must never fail
# loudly, and `ferry` itself rejects it the next time it runs.
__ferry_ps1_ignore() {
    local root=$1 unit=$2 file line pat dironly
    for file in "$root/$FERRY_IGNORE" "$unit/$FERRY_IGNORE"; do
        [ -r "$file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%$'\r'}
            case $line in ''|'#'*|'!'*|*'**'*) continue ;; esac
            pat=$line dironly=0
            case $pat in */) dironly=1; pat=${pat%/} ;; esac
            case $pat in
                '') continue ;;
                /*) case $pat in *[][*?]*) continue ;; esac
                    prune+=(-path "$(__ferry_ps1_escape "$unit$pat")") ;;
                */*) continue ;;                      # unanchored '/' — rejected
                *)  prune+=(-name "$pat") ;;
            esac
            [ "$dironly" = 1 ] && prune+=(-type d)
            prune+=(-prune -o)
        done < "$file"
    done
}

# Print '>' if anything in the unit changed since the marker; nothing if clean.
# Prunes .git, history.bundle, the marker and everything `.ferryignore` keeps
# out — none of it is synced as content, so none of it is drift.
__ferry_ps1_local_changed() {
    local dir=$1 marker=$2 root=$3
    local -a prune=(-name .git -prune -o -name history.bundle -prune -o
                    -name "$FERRY_MARKER" -prune -o)
    __ferry_ps1_ignore "$root" "$dir"
    [ -n "$(find "$dir" "${prune[@]}" -newer "$marker" -print -quit 2>/dev/null)" ] && printf '>'
}

# Emit the indicator for the unit enclosing $PWD, wrapped in the format string
# ($1, default " (%s)"). Silent when not inside a unit (a grouping dir, the root
# with children, or outside any tree).
__ferry_ps1() {
    local fmt=${1:-" (%s)"}
    local d=$PWD unit="" root=""

    # Walk up: the nearest empty marker is the enclosing unit; a marker with
    # content is the root (and stops the walk). One root per tree, by invariant.
    while [ -n "$d" ] && [ "$d" != / ]; do
        if [ -f "$d/$FERRY_MARKER" ]; then
            if [ -s "$d/$FERRY_MARKER" ]; then root=$d; break; fi
            [ -z "$unit" ] && unit=$d
        fi
        d=${d%/*}
    done
    [ -n "$root" ] || return   # not inside a ferry tree

    # No enclosing empty-marker unit: only valid if the root is itself a leaf
    # (a single-unit tree). If the root has sub-markers, $PWD is in a grouping dir.
    if [ -z "$unit" ]; then
        [ -z "$(find "$root" -mindepth 2 -name "$FERRY_MARKER" -print -quit 2>/dev/null)" ] || return
        unit=$root
    fi

    # Keyed by the remote base as well as the unit path, exactly as `ferry` keys
    # it: two trees can hold the same unit name against different remotes. The
    # percent-encoding must match `ferry`'s state_key — it is injective, where a
    # plain substitution would map two different bases onto one directory.
    local spec=${unit#"$root"}; spec=${spec#/}
    local base key='' i c
    base=$(head -1 "$root/$FERRY_MARKER")
    for (( i = 0; i < ${#base}; i++ )); do
        c=${base:i:1}
        case $c in
            [A-Za-z0-9._-]) key+=$c ;;
            *) printf -v c '%%%02X' "'$c"; key+=$c ;;
        esac
    done
    local sd=$FERRY_STATE_ROOT/$key${spec:+/$spec}
    local marker=$sd/synced_at

    # No baseline yet (never pushed/pulled from here) → unknown.
    if [ ! -e "$marker" ]; then
        printf -- "$fmt" '?'
        return
    fi

    local ahead behind="" rstate rtime now
    ahead=$(__ferry_ps1_local_changed "$unit" "$marker" "$root")

    # Cloud bit from the last `ferry status` (written alongside the marker).
    # 'diverged' also forces the local half: `ferry status` compares content and
    # can see a conflict — two sides edited to different bytes with mtimes older
    # than the baseline — that this function's mtime walk never would.
    if [ -r "$sd/remote" ]; then
        read -r rstate rtime < "$sd/remote"
        case $rstate in
            behind)   behind='<' ;;
            diverged) behind='<'; ahead='>' ;;
        esac
    fi

    local sym
    case "$ahead$behind" in
        '><') sym='<>' ;;
        '>')  sym='>'  ;;
        '<')  sym='<'  ;;
        *)    sym='='  ;;
    esac

    # Flag a stale cloud bit: the '<'/'=' half may be out of date.
    if [ "${FERRY_PS1_STALE:-0}" -gt 0 ] && [ -n "${rtime:-}" ]; then
        now=$(date +%s)
        [ $((now - rtime)) -gt "$FERRY_PS1_STALE" ] && sym="$sym?"
    fi

    printf -- "$fmt" "$sym"
}

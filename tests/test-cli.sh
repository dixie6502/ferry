#!/usr/bin/env bash
#
# Command-line tests: every verb's arguments and flags are checked against one
# table, help and completion come from that table, and prompts fail safe.
#
# Real rclone against a real backend: the cloud side is a plain directory
# addressed as `:local:<path>`, an rclone connection string. No mocks, and no
# way to reach the user's configured remotes.
#
# Usage: tests/test-cli.sh       (from anywhere; scratch lands in tmp/)

set -uo pipefail

SUITE_TMP=tc
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

# The words bash completion offers for a command line (the last word is the one
# being completed).
completion_of() {
    (
        eval "$("$FERRY" completion bash)"
        COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
        _ferry
        [ ${#COMPREPLY[@]} -eq 0 ] || printf '%s\n' "${COMPREPLY[@]}" | LC_ALL=C sort | tr '\n' ' '
    )
}

reset_tree
ferry new u >/dev/null

printf '\n== arguments are counted ==\n'
check 'a second <dir> is refused, not dropped' '1|ferry: usage: ferry push [--mirror] [--force] [<dir>]' \
    "$(failure_of push u u2)"
check 'a missing argument is refused' '1|ferry: usage: ferry mv <old> <new>' "$(failure_of mv u)"
check 'an unknown verb is refused' '1|ferry: unknown command: frob (try: ferry help)' "$(failure_of frob)"

printf '\n== flags are checked per verb ==\n'
check 'a flag the verb does not take' \
    '1|ferry: status does not take --mirror (usage: ferry status [<dir>])' "$(failure_of status --mirror)"
check 'an unknown flag' '1|ferry: rm does not take --bogus (usage: ferry rm [-y|--yes] <dir>)' \
    "$(failure_of rm --bogus u)"
check 'a flag may come before the verb' '=' "$(ferry -v status u 2>/dev/null | awk 'NR==1{print $1}')"
check '-h after a verb prints help' '0' "$(ferry push -h >/dev/null 2>&1; echo $?)"
check '  even one that needs arguments' '0' "$(ferry mv -h >/dev/null 2>&1; echo $?)"
check 'an empty argument is refused' '1|ferry: empty argument' "$(failure_of push '')"
check 'push of a missing dir fails before the cloud' '1|ferry: no local dir: typo' "$(failure_of push typo)"
check 'help lists every verb' "$(bash -c "source '$FERRY'; echo \${#VERBS[@]}")" \
    "$(ferry help | grep -c '^  ferry ')"
check '  and the README shows the same list' "$(ferry help | sed -n '/^Commands:/,$p' | tail -n +2)" \
    "$(awk '/^## Usage/{on=1; next} on && /^```/{if (inside) exit; inside=1; next} inside' "$REPO/README.md")"

printf '\n== -- ends the flags ==\n'
mkdir -p "$WORK/-dash"; : > "$WORK/-dash/.ferry"
check 'a unit whose name starts with -' '-dash' "$(ferry status -- -dash 2>/dev/null | awk 'NR==1{print $2}')"

printf '\n== a prompt without an answer aborts ==\n'
out=$(ferry drop u 2>&1 </dev/null); rc=$?
check 'end of input aborts, and says so' '1 ferry: aborted' "$rc ${out##*\[y/N\] }"
check '  the unit is still there' 'yes' "$([ -d "$WORK/u" ] && echo yes || echo no)"

printf '\n== completion offers what the checks accept ==\n'
check 'verbs' 'pull push ' "$(completion_of ferry pu)"
check 'push flags' '--force --help --mirror --verbose -h -v ' "$(completion_of ferry push -)"
check 'rm flags' '--help --verbose --yes -h -v -y ' "$(completion_of ferry rm -)"
check 'status flags' '--help --verbose -h -v ' "$(completion_of ferry status -)"
check 'completion takes its literal word' 'bash ' "$(completion_of ferry completion '')"
check 'init completes nothing' '' "$(completion_of ferry init '')"
check 'a flag before the verb' 'pull push ' "$(completion_of ferry -v pu)"
check '  and its flags after it' '--force --help --mirror --verbose -h -v ' "$(completion_of ferry -v push -)"
check 'after --, a dash word is not a flag' '' "$(completion_of ferry status -- -)"

report

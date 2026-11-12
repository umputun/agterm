#!/bin/sh
# attach again, after a relaunch, the sessions from other Macs that were attached when agterm quit.
#
#   remote-restore record   hook for remote.opened and remote.closed: keeps the list current
#   remote-restore sync     hook for tree.changed: follows a row moved to another workspace
#   remote-restore replay   hook for app.launched: attaches every listed session again
#   remote-restore retry    attaches again the sessions a host that did not answer left waiting
#   remote-restore list     prints the list
#
# the list is one line per attached row: host, the origin's session id, window, workspace, and this
# Mac's session id, tab-separated. A quit sends no remote.closed, so the list survives it; closing a
# row or its window does, so those leave the list.
set -eu

AGTERMCTL=${AGTERMCTL:-agtermctl}
STATE=${AGT_REMOTE_RESTORE_DIR:-$HOME/.local/state/agterm-remote-restore}
ROWS=$STATE/rows
PENDING=$STATE/rows.replay
LOCK=$STATE/lock
RUNNING=$STATE/replaying
TAB=$(printf '\t')

# stdin closed: the replay loop reads the list on stdin, and nothing here takes input
agt() {
    if [ -n "${AGT_SOCKET:-}" ]; then
        "$AGTERMCTL" "$@" --socket "$AGT_SOCKET" </dev/null
    else
        "$AGTERMCTL" "$@" </dev/null
    fi
}

# a hook runs detached with its output discarded, so anything the reader must see is a banner
say() {
    agt notify "$1" --title "Remote restore" >/dev/null 2>&1 || true
}

# record and replay are separate hook lines and run concurrently; mkdir is the atomic step
lock() {
    tries=0
    until mkdir "$LOCK" 2>/dev/null; do
        tries=$((tries + 1))
        # a lock older than the longest rewrite is one a killed run left behind
        if [ "$tries" -ge 50 ]; then
            rmdir "$LOCK" 2>/dev/null || true
            tries=0
        fi
        sleep 0.1
    done
}

unlock() {
    rmdir "$LOCK" 2>/dev/null || true
}

# session id -> workspace id for every session of window $1, tab-separated
placement() {
    agt tree --window "$1" --json 2>/dev/null | jq -r '
        .result.tree.workspaces[] | .id as $ws | .sessions[] | [.id, $ws] | @tsv' 2>/dev/null
}

record() {
    # "-" stands for a missing field: a shell `read` on tabs folds empty fields together.
    # An older agterm sends no remoteSessionID, and a row without one cannot be attached again.
    line=$(jq -r '[.kind, .payload.host, .payload.remoteSessionID, .window, .workspace, .session]
        | map(. // "-" | if . == "" then "-" else . end) | @tsv') || exit 1
    IFS="$TAB" read -r kind host id window workspace session <<EOF
$line
EOF
    [ "$session" != - ] || exit 0
    # the event names the workspace the row was created in; the tree, read now, also has any move
    # made since, which a hook queued behind other events would otherwise miss
    if [ "$kind" = remote.opened ] && [ "$window" != - ]; then
        now=$(placement "$window" | awk -F '\t' -v s="$session" '$1 == s { print $2 }')
        [ -z "$now" ] || workspace=$now
    fi

    mkdir -p "$STATE"
    lock
    # a row is keyed by this Mac's session id: an undo re-opens the same one
    if [ -f "$ROWS" ]; then
        awk -F '\t' -v s="$session" '$5 != s' "$ROWS" > "$ROWS.tmp"
    else
        : > "$ROWS.tmp"
    fi
    if [ "$kind" = remote.opened ] && [ "$host" != - ] && [ "$id" != - ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$id" "$window" "$workspace" "$session" >> "$ROWS.tmp"
    fi
    mv "$ROWS.tmp" "$ROWS"
    unlock
}

# a move between workspaces sends no event of its own, only tree.changed for the window
sync() {
    window=$(jq -r '.window // empty') || exit 1
    [ -n "$window" ] && [ -s "$ROWS" ] || exit 0
    # most tree changes are in windows with no remote row; skip the tree read for those
    awk -F '\t' -v w="$window" '$3 == w { found = 1 } END { exit !found }' "$ROWS" || exit 0
    map=$(placement "$window")
    [ -n "$map" ] || exit 0
    lock
    if [ -f "$ROWS" ]; then
        printf '%s\n' "$map" | awk -F '\t' -v OFS='\t' -v w="$window" '
            NR == FNR { ws[$1] = $2; next }
            $3 == w && ($5 in ws) { $4 = ws[$5] }
            { print }' - "$ROWS" > "$ROWS.tmp"
        mv "$ROWS.tmp" "$ROWS"
    fi
    unlock
}

# keep a line for a later try; a row this run attaches records itself through record
keep() {
    lock
    printf '%s\n' "$1" >> "$ROWS"
    unlock
}

# one restore at a time: a retry started while the launch replay still runs would attach twice.
# The pid tells a live run from one a crash left behind.
claim() {
    if ! mkdir "$RUNNING" 2>/dev/null; then
        pid=$(cat "$RUNNING/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        rm -rf "$RUNNING"
        mkdir "$RUNNING" || return 1
    fi
    echo $$ > "$RUNNING/pid"
}

release() {
    rm -rf "$RUNNING"
}

# take the rows to attach into PENDING: every row at launch, only the ones kept for later on a retry,
# since the others are attached right now
take() {
    lock
    if [ -f "$ROWS" ]; then
        if [ "$1" = all ]; then
            cat "$ROWS" >> "$PENDING"
            rm -f "$ROWS"
        else
            awk -F '\t' '$5 == "-"' "$ROWS" >> "$PENDING"
            awk -F '\t' '$5 != "-"' "$ROWS" > "$ROWS.tmp"
            mv "$ROWS.tmp" "$ROWS"
        fi
    fi
    unlock
}

# one pass over PENDING; leaves attached, dropped, kept and reasons set
pass() {
    attached=0
    dropped=0
    kept=0
    reasons=
    windows=$(agt window list --json) || { say "could not read the window list"; return 1; }
    open=$(printf '%s' "$windows" | jq -r '.result.windows[] | select(.open) | .id')

    # the workspace each window shows now, to put back once the rows are in
    shown=$STATE/shown
    : > "$shown"
    for w in $open; do
        cur=$(agt tree --window "$w" --json 2>/dev/null \
            | jq -r '.result.tree.workspaces[] | select(.active) | .id' 2>/dev/null) || cur=
        [ -z "$cur" ] || printf '%s\t%s\n' "$w" "$cur" >> "$shown"
    done

    trees=$STATE/trees
    rm -rf "$trees"
    mkdir -p "$trees"

    # one attach per remote session and window, in the order they were opened, so a parent comes
    # before its companions and they join it
    awk -F '\t' '!seen[$1 FS $2 FS $3]++' "$PENDING" > "$PENDING.uniq"
    rm -f "$PENDING"
    while IFS="$TAB" read -r host id window workspace _; do
        [ -n "$host" ] && [ -n "$id" ] || continue
        line=$(printf '%s\t%s\t%s\t%s\t-' "$host" "$id" "$window" "$workspace")

        # ask the far side once per host. ssh failing says nothing about the session, so keep it
        tree=$trees/$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '_')
        if [ ! -e "$tree" ]; then
            agt zmx tree "$host" --json > "$tree" 2> "$tree.err" || true
            # the reason goes to the user: a hook's stderr reaches nobody
            if ! jq -e '.ok' "$tree" >/dev/null 2>&1; then
                why=$(jq -r '.error // empty' "$tree" 2>/dev/null || true)
                [ -n "$why" ] || why=$(tail -1 "$tree.err")
                reasons="$reasons; $host: ${why:-no answer}"
            fi
        fi
        if ! jq -e '.ok' "$tree" >/dev/null 2>&1; then
            keep "$line"; kept=$((kept + 1)); continue
        fi
        # listed means attachable now. Not listed is not proof it is gone: a far-side window that is
        # closed, or a launch that fell back from Live sessions, hides it too. This recipe drops it.
        if ! jq -e --arg id "$id" 'any(.result.remote.sessions[]; .id == $id)' "$tree" >/dev/null; then
            dropped=$((dropped + 1)); continue
        fi

        # a window that did not come back leaves the row to the frontmost window
        set -- zmx attach "$host" "$id" --json
        home=
        if printf '%s\n' "$open" | grep -qxF -- "$window"; then
            set -- "$@" --window "$window"
            home=$workspace
        fi
        if ! out=$(agt "$@" 2>/dev/null) || ! row=$(printf '%s' "$out" | jq -er '.result.id'); then
            reasons="$reasons; $host: could not attach $id"
            keep "$line"; kept=$((kept + 1)); continue
        fi
        attached=$((attached + 1))
        # an attach lands wherever the window's selection is, which a launch still settling can move;
        # put the row where it was. A companion has already joined its parent and stays with it.
        if [ -n "$home" ] && [ "$home" != - ] \
            && [ -z "$(printf '%s' "$out" | jq -r '.result.parent // empty')" ]; then
            agt session move "$home" --target "$row" --window "$window" >/dev/null 2>&1 || true
        fi
    done < "$PENDING.uniq"

    while IFS="$TAB" read -r w ws; do
        agt workspace select --target "$ws" --window "$w" >/dev/null 2>&1 || true
    done < "$shown"
    rm -rf "$trees" "$shown" "$PENDING.uniq"
}

# $1 is all at launch and kept for a retry
restore() {
    mkdir -p "$STATE"
    if ! claim; then
        say "a restore is already running"
        return 0
    fi
    trap release EXIT
    mode=$1
    while :; do
        take "$mode"
        if [ ! -s "$PENDING" ]; then
            rm -f "$PENDING"
            [ "$mode" = all ] || say "no remote session is waiting to be restored"
            return 0
        fi
        pass || return 1
        msg="attached $attached"
        [ "$dropped" -eq 0 ] || msg="$msg, dropped $dropped no longer listed"
        if [ "$kept" -eq 0 ]; then
            say "$msg"
            return 0
        fi

        # a host that did not answer gets a question rather than a banner, so the retry is one key away.
        # ask refuses every control character, a newline included, and an ssh error can carry one
        detail=$(printf '%s, %s waiting%s' "$msg" "$kept" "$reasons" | tr -d '\000-\037\177')
        answer=$(agt ask "Remote sessions not restored" --style gui --message "$detail" \
            --button retry=Retry --button later=Later --default retry 2>/dev/null) || answer=
        if [ "$(printf '%s' "$answer" | jq -r '.id // empty' 2>/dev/null)" != retry ]; then
            say "$kept still waiting: run remote-restore retry, or relaunch agterm"
            return 0
        fi
        mode=kept
    done
}

command -v jq >/dev/null 2>&1 || { say "jq is not on PATH"; exit 1; }
case ${1:-} in
    record) record ;;
    sync) sync ;;
    replay) restore all ;;
    retry) restore kept ;;
    list) [ ! -f "$ROWS" ] || cat "$ROWS" ;;
    *) echo "usage: remote-restore record|sync|replay|retry|list" >&2; exit 2 ;;
esac

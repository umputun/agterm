#!/bin/sh
# hud.sh — the panel painter agterm runs in a session's overlay slot for `session.hud.*`.
#
# One HUD-SPECIFIC environment variable, AGTERM_HUD_FILE, points at the rendered body the app writes (the
# surface also inherits the session environment and the overlay wrapper's own AGTERM_OVL_* pair):
#
#   <columns> <rows> <spinner> <pid>   the box the app sized the slot to; spinner 1 shows the glyph and
#                                      ticks faster; pid is the app process that owns this panel
#   message lines                wrapped by HudLayout
#   (one empty line)             the separator HudLayout guarantees, when a detail follows
#   detail lines                 rendered dimmed
#
# Everything an update may change lives in that file, re-read every tick, so `session.hud.update` repaints
# in place: a process cannot see its own environment change, and a re-spawn would blink the panel. The box
# is never measured here — no stty, tput, $COLUMNS or SIGWINCH — because the app computed it from the
# terminal font and sized the slot to match; measuring would race that resize and disagree.
#
# Removing the file is how every teardown path stops the loop. The pid is the second stop, and the only one
# a HARD-killed app has: no teardown deletes the file, and no SIGHUP arrives either, because the pty's
# session leader is the surviving `login`, not the app. Without it the loop repaints forever.
set -uf

# ${#line} counts CHARACTERS only under a UTF-8 locale and BYTES otherwise, while the app sized the box in
# characters — so without this every non-ASCII message centers wrong. A Dock-launched app inherits launchd's
# environment, which sets no LANG or LC_*, and an inherited LC_ALL would override LC_CTYPE.
unset LC_ALL
LC_CTYPE=UTF-8
export LC_CTYPE

file=${AGTERM_HUD_FILE:-}
[ -n "$file" ] || exit 0

esc=$(printf '\033')
csi="$esc["

# rows advance with CNL rather than a newline: it stops at the last line instead of scrolling, and it
# lands on column 1 without depending on the pty's ONLCR.
down="${csi}E"

trap 'printf "%s?25h%s0m" "$csi" "$csi"; exit 0' EXIT INT TERM HUP
# a resize reflows what is already on screen, so drop the cached frame and repaint once. This measures
# nothing — the box still comes from the body file — it only tells the tick below that the screen moved.
trap 'painted=' WINCH
printf '%s?25l' "$csi"

frame=0
painted=''
while [ -f "$file" ]; do
    case $frame in
        0) glyph='|' ;;
        1) glyph='/' ;;
        2) glyph='-' ;;
        *) glyph='\' ;;
    esac
    frame=$(( (frame + 1) % 4 ))

    # every tick starts from the built-in box, so a frame depends only on the file it just read
    cols=40
    rows=5
    spinner=0
    interval=0.5
    owner=''

    block=''
    sep=''
    attr=''
    count=0
    first=1
    header=1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$header" = 1 ]; then
            header=0
            # word splitting is the parse here; globbing is off (set -f), so a malformed header cannot expand
            set -- $line
            case ${1:-} in ''|*[!0-9]*) ;; *) cols=$1 ;; esac
            case ${2:-} in ''|*[!0-9]*) ;; *) rows=$2 ;; esac
            case ${3:-} in 1) spinner=1; interval=0.1 ;; esac
            case ${4:-} in ''|0|*[!0-9]*) ;; *) owner=$4 ;; esac
            continue
        fi
        count=$(( count + 1 ))
        block="$block$sep"
        sep="$down"
        if [ -z "$line" ]; then
            attr="${csi}2m"
            continue
        fi
        pre=''
        if [ "$spinner" = 1 ] && [ "$first" = 1 ]; then
            pre="$glyph "
        fi
        first=0
        left=$(( (cols - ${#line} - ${#pre}) / 2 ))
        if [ "$left" -gt 0 ]; then
            block="$block${csi}${left}C"
        fi
        block="$block$attr$pre$line"
    done 2>/dev/null < "$file"

    # kill is a shell builtin, so the liveness check costs no fork and does not slow the tick. A header
    # naming no owner keeps painting, which is what leaves the file the only stop.
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        exit 0
    fi

    top=$(( (rows - count) / 2 ))
    pad=''
    while [ "$top" -gt 0 ]; do
        pad="$pad$down"
        top=$(( top - 1 ))
    done

    # one write per tick: reset, home, erase down, then the whole frame, so a repaint cannot flicker. An
    # UNCHANGED frame is not written at all: every write wakes the app's renderer, and a spinner-less panel
    # is finished after its first paint — repainting it twice a second would be the continuous poll the
    # rendering rule forbids.
    out="${csi}0m${csi}H${csi}J$pad$block${csi}0m"
    if [ "$out" != "$painted" ]; then
        printf '%s' "$out"
        painted=$out
    fi
    sleep "$interval"
done

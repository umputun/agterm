#!/bin/sh
# hud.sh — the panel painter agterm runs in a session's overlay slot for `session.hud.*`.
#
# One environment variable, AGTERM_HUD_FILE, points at the rendered body the app writes:
#
#   <columns> <rows> <spinner>   the box the app sized the slot to; spinner 1 shows the glyph, ticks faster
#   message lines                wrapped by HudLayout
#   (one empty line)             the separator HudLayout guarantees, when a detail follows
#   detail lines                 rendered dimmed
#
# Everything an update may change lives in that file, re-read every tick, so `session.hud.update` repaints
# in place: a process cannot see its own environment change, and a re-spawn would blink the panel. The box
# is never measured here — no stty, tput, $COLUMNS or SIGWINCH — because the app computed it from the
# terminal font and sized the slot to match; measuring would race that resize and disagree.
#
# Removing the file is how every teardown path stops the loop.
set -uf

file=${AGTERM_HUD_FILE:-}
[ -n "$file" ] || exit 0

esc=$(printf '\033')
csi="$esc["

# rows advance with CNL rather than a newline: it stops at the last line instead of scrolling, and it
# lands on column 1 without depending on the pty's ONLCR.
down="${csi}E"

trap 'printf "%s?25h%s0m" "$csi" "$csi"; exit 0' EXIT INT TERM HUP
printf '%s?25l' "$csi"

frame=0
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

    top=$(( (rows - count) / 2 ))
    pad=''
    while [ "$top" -gt 0 ]; do
        pad="$pad$down"
        top=$(( top - 1 ))
    done

    # one write per tick: reset, home, erase down, then the whole frame, so a repaint cannot flicker
    printf '%s' "${csi}0m${csi}H${csi}J$pad$block${csi}0m"
    sleep "$interval"
done

#!/bin/sh
# hud.sh — the panel painter agterm runs in a session's overlay slot for `session.hud.*`.
#
# Driven entirely by the environment the app injects at spawn:
#   AGTERM_HUD_FILE        rendered body — wrapped message lines, ONE empty line, wrapped detail lines
#   AGTERM_HUD_COLS/_ROWS  the cell box the app sized the slot to
#   AGTERM_HUD_SPINNER=1   show the spinner and tick faster
#
# The box is never measured here — no stty, tput, $COLUMNS or SIGWINCH — because the app computed it
# from the terminal font and sized the slot to match; measuring would race that resize and disagree.
# A box change therefore needs a respawn, not a file rewrite.
#
# HudLayout.wrap drops blank lines, so the body's single empty line unambiguously starts the detail
# block, which renders dimmed. Removing the file is how every teardown path stops the loop.
set -u

file=${AGTERM_HUD_FILE:-}
[ -n "$file" ] || exit 0

cols=${AGTERM_HUD_COLS:-40}
rows=${AGTERM_HUD_ROWS:-5}
spinner=0
interval=0.5
if [ "${AGTERM_HUD_SPINNER:-}" = "1" ]; then
    spinner=1
    interval=0.1
fi

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

    block=''
    sep=''
    attr=''
    count=0
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
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

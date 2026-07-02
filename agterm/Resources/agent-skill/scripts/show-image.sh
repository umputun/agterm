#!/bin/bash
# show-image.sh — display an image inside the current agterm session.
#
# usage: bash show-image.sh <image> [size-percent]
#
# opens an agterm overlay (a real terminal surface with a pty) and renders the image there via the
# kitty graphics protocol, which ghostty — agterm's engine — draws natively. no kitty binary and no
# external image viewer are involved; the encoder is plain base64 + printf. this is the reliable way
# for a coding agent to show an image: emitting graphics escapes to the agent's own tool stdout does
# not work (the harness escapes the control bytes), and an image viewer cannot run in the agent's
# tool shell (no controlling terminal). the overlay sidesteps both.
#
# requires running inside agterm (AGTERM_ENABLED=1) with agtermctl on PATH.

# internal mode: emit the graphics escape into the overlay's pty, then wait for dismissal.
if [ "${1:-}" = "--emit" ]; then
  img="$2"
  clear
  data=$(base64 < "$img" | tr -d '\n')
  i=0; n=${#data}; first=1
  while [ "$i" -lt "$n" ]; do
    chunk=${data:i:4096}
    i=$((i + 4096))
    if [ "$i" -ge "$n" ]; then m=0; else m=1; fi
    if [ "$first" = 1 ]; then
      printf '\033_Ga=T,f=100,m=%d;%s\033\\' "$m" "$chunk"; first=0
    else
      printf '\033_Gm=%d;%s\033\\' "$m" "$chunk"
    fi
  done
  printf '\n\n  press Enter to close\n'
  read -r _
  exit 0
fi

img="${1:-}"
size="${2:-60}"
[ -n "$img" ] || { echo "usage: show-image.sh <image> [size-percent]" >&2; exit 2; }
[ -f "$img" ] || { echo "show-image.sh: no such file: $img" >&2; exit 1; }
command -v agtermctl >/dev/null 2>&1 || { echo "show-image.sh: agtermctl not on PATH" >&2; exit 1; }
[ "${AGTERM_ENABLED:-}" = "1" ] || { echo "show-image.sh: not inside agterm; try: open \"$img\"" >&2; exit 1; }

# resolve absolute paths so the overlay (which runs with a different cwd) finds both this script and
# the image regardless of where the agent invoked it from.
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
abs=$(cd "$(dirname "$img")" && pwd)/$(basename "$img")

# POSIX single-quote a string for safe embedding in the command below: wrap in '...' and replace each
# embedded ' with the '\'' sequence, so a path containing a quote can't break out of the quoting. The
# overlay command is run via `sh -c`, so an unescaped ' in the path would otherwise abort it.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# open an overlay that re-invokes this script in --emit mode inside the overlay's pty.
agtermctl session overlay open "/bin/bash $(sq "$self") --emit $(sq "$abs")" --size-percent "$size"

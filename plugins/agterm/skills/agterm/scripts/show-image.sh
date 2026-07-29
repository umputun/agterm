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

# ask the terminal for a geometry report and echo the two numeric fields it carries. $1 is the CSI
# request (14t -> ESC [ 4 ; height-px ; width-px t, 18t -> ESC [ 8 ; rows ; cols t). the request and
# the reply go over /dev/tty on fd 3, not stdout/stdin: the caller runs this in a command
# substitution, so a request written to stdout would land in that pipe and never reach the terminal.
# prints nothing when the terminal does not answer, so the caller falls back to unscaled output.
query_geom() {
  local old a b
  exec 3<>/dev/tty || return
  old=$(stty -g <&3 2>/dev/null) || { exec 3>&-; return; }
  stty raw -echo min 0 time 5 <&3 2>/dev/null
  printf '\033[%s' "$1" >&3
  IFS=';' read -r -d t -t 1 _ a b <&3
  stty "$old" <&3 2>/dev/null
  exec 3>&-
  case "$a$b" in ''|*[!0-9]*) return;; esac
  printf '%s %s' "$a" "$b"
}

# internal mode: emit the graphics escape into the overlay's pty, then wait for dismissal.
if [ "${1:-}" = "--emit" ]; then
  img="$2"
  clear

  # scale the image to the overlay's own size. the kitty protocol places the image at native pixel
  # size unless c= and r= give it a cell box, so a screenshot larger than the panel gets clipped.
  # cell size comes from the terminal's pixel and cell geometry; image size from sips (macOS-native).
  px=$(query_geom 14t)
  cells=$(query_geom 18t)
  iw=$(sips -g pixelWidth "$img" 2>/dev/null | awk '/pixelWidth:/{print $2}')
  ih=$(sips -g pixelHeight "$img" 2>/dev/null | awk '/pixelHeight:/{print $2}')
  box=""; padc=0; padr=0; promptcol=1
  if [ -n "$px" ] && [ -n "$cells" ] && [ -n "$iw" ] && [ -n "$ih" ]; then
    fit=$(awk -v px="$px" -v cells="$cells" -v iw="$iw" -v ih="$ih" 'BEGIN{
      split(px, p, " "); split(cells, c, " ")
      ph=p[1]; pw=p[2]; rows=c[1]; cols=c[2]
      if (pw<=0 || ph<=0 || rows<=0 || cols<=0 || iw<=0 || ih<=0) exit
      # image size expressed in cells, then the largest uniform scale that still fits. the close
      # prompt is pinned to the last row, so the image is centered in the rows above it and capped
      # three rows short of the height: a cap of exactly the free height would leave zero slack to
      # split, which is what makes a height-limited image look top-aligned rather than centered.
      needc=iw/(pw/cols); needr=ih/(ph/rows)
      avail=rows-3; if (avail<1) avail=1
      s=cols/needc; if (avail/needr < s) s=avail/needr
      # orow, not or: or() is a gawk builtin, so `or` as a variable is a syntax error there.
      oc=int(needc*s); orow=int(needr*s)
      if (oc<1) oc=1; if (orow<1) orow=1
      # leftover cells split evenly so the image sits centered in the overlay. the prompt column is
      # floored at 1: on an overlay narrower than the prompt it would otherwise go negative, and a
      # negative parameter makes the CUP escape malformed, so the terminal drops it and the prompt
      # lands on top of the image instead of the last row.
      pc=int((cols-20)/2)+1; if (pc<1) pc=1
      printf "%d %d %d %d %d", oc, orow, int((cols-oc)/2), int((rows-1-orow)/2), pc
    }')
    # C=1 keeps the cursor put, so a bottom-edge image cannot scroll the screen and shift itself up.
    [ -n "$fit" ] && read -r oc or padc padr promptcol <<<"$fit" && box="c=$oc,r=$or,C=1,"
  fi
  read -r termrows _ <<<"$cells"

  # place the cursor at the image's top-left corner before transmitting: a=T draws at the cursor, and
  # the chunked escapes below do not move it.
  k=0; while [ "$k" -lt "$padr" ]; do printf '\n'; k=$((k + 1)); done
  [ "$padc" -gt 0 ] && printf '\033[%dC' "$padc"

  data=$(base64 < "$img" | tr -d '\n')
  i=0; n=${#data}; first=1
  while [ "$i" -lt "$n" ]; do
    chunk=${data:i:4096}
    i=$((i + 4096))
    if [ "$i" -ge "$n" ]; then m=0; else m=1; fi
    if [ "$first" = 1 ]; then
      printf '\033_Ga=T,f=100,%sm=%d;%s\033\\' "$box" "$m" "$chunk"; first=0
    else
      printf '\033_Gm=%d;%s\033\\' "$m" "$chunk"
    fi
  done
  if [ -n "$box" ]; then
    printf '\033[%d;%dHpress Enter to close' "$termrows" "$promptcol"
  else
    printf '\n\n  press Enter to close\n'
  fi
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

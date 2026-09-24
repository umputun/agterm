#!/bin/sh
AGTERMCTL=${AGTERMCTL:-agtermctl}

[ -n "$AGT_SESSION_HOST" ] || exit 0
osascript -e 'clipboard info' | grep -q PNGf || { echo "no image on the clipboard" >&2; exit 1; }

f=$(mktemp /tmp/agt-clip.XXXXXX) || exit 1
trap 'rm -f "$f"' EXIT
osascript -e "set fh to open for access POSIX file \"$f\" with write permission" \
  -e 'write (the clipboard as «class PNGf») to fh' -e 'close access fh' >/dev/null || exit 1

scp -q -o BatchMode=yes "$f" "$AGT_SESSION_HOST:$f" || exit 1
# use sh syntax regardless of the remote account shell
ssh -o BatchMode=yes "$AGT_SESSION_HOST" sh -s -- "$f" <<'EOF' || exit 1
osascript -e "set the clipboard to (read (POSIX file \"$1\") as «class PNGf»)" >/dev/null
rc=$?
rm -f "$1"
exit $rc
EOF

"$AGTERMCTL" session hud open --socket "$AGT_SOCKET" --target "$AGT_SESSION_ID" --hide-after 3 \
  "image copied to $AGT_SESSION_HOST, press ctrl+v" >/dev/null

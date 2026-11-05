#!/bin/sh
AGTERMCTL=${AGTERMCTL:-agtermctl}

# Claude Code wraps long paths with an indent, so drop all whitespace before matching.
# the character class is also the quoting: the path passes through two shells over ssh, and
# terminal text is untrusted. a path with a space is not matched.
image_paths() {
  tr -d '[:space:]' | perl -ne 'print "$1\n" while m{(/[A-Za-z0-9._/\@+-]+?\.(?:png|jpe?g|gif|webp))}gi' | awk '!seen[$0]++'
}

# a scratch pane is a local shell even on an attached session
host=$AGT_SESSION_HOST
[ "$AGT_PANE" = scratch ] && host=
case "$host" in
  -*|*[!A-Za-z0-9._@-]*) echo "unsupported host name: $host" >&2; exit 1 ;;
esac

existing() {
  if [ -n "$host" ]; then
    # shellcheck disable=SC2086 # the paths hold no spaces or shell characters
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s -- $1 <<'REMOTE'
for p in "$@"; do [ -f "$p" ] && echo "$p"; done; exit 0
REMOTE
  else
    for p in $1; do [ -f "$p" ] && echo "$p"; done; return 0
  fi
}

# Claude Code draws its own mouse selection, which never reaches $AGT_SELECTION, so read the
# pane's visible screen when there is no terminal selection.
paths=$(printf '%s' "$AGT_SELECTION" | image_paths)
if [ -z "$paths" ]; then
  paths=$("$AGTERMCTL" session text --target "$AGT_SESSION_ID" --socket "$AGT_SOCKET" ${AGT_PANE:+--pane "$AGT_PANE"} | image_paths)
fi
[ -n "$paths" ] || { echo "no image path on the screen" >&2; exit 1; }
paths=$(existing "$paths") || { echo "cannot reach $host" >&2; exit 1; }
[ -n "$paths" ] || { echo "the image paths on the screen do not exist${host:+ on $host}" >&2; exit 1; }

dir=$(mktemp -d /tmp/agt-preview.XXXXXX) || exit 1
trap 'rm -rf "$dir"' EXIT

# the page reads local files only, so bring the images here. a number keeps equal names apart.
i=0; files=""
for p in $paths; do
  i=$((i + 1)); f="$i-${p##*/}"
  if [ -n "$host" ]; then
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$host:$p" "$dir/$f" || { echo "cannot copy $p from $host" >&2; exit 1; }
  else
    cp "$p" "$dir/$f" || exit 1
  fi
  files="$files\"$f\","
done

cat > "$dir/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>Image preview</title>
<style>
html,body{height:100%;margin:0;background:var(--agterm-background,#222);color:var(--agterm-foreground,#ddd);font:13px -apple-system,sans-serif}
body{display:flex;flex-direction:column}
#main{flex:1;min-height:0;display:flex;align-items:center;justify-content:center;padding:12px}
#main img{max-width:100%;max-height:100%;object-fit:contain}
#caption{text-align:center;opacity:.7;padding-bottom:6px}
#strip{display:flex;gap:8px;justify-content:safe center;overflow-x:auto;padding:0 12px 12px;flex:none}
#strip button{flex:none;padding:0;border:2px solid transparent;border-radius:6px;background:none;cursor:pointer;opacity:.6}
#strip button.on{border-color:var(--agterm-color-4,#6d82f3);opacity:1}
#strip img{display:block;height:84px;max-width:150px;object-fit:contain;border-radius:4px}
</style>
<div id="main"><img id="big" alt=""></div>
<div id="caption"></div>
<div id="strip"></div>
<script>
var files=[${files%,}], n=0, strip=document.getElementById('strip');
function name(f){return f.replace(/^\d+-/,'')}
function show(i){
  n=(i+files.length)%files.length;
  document.getElementById('big').src=files[n];
  document.getElementById('caption').textContent=name(files[n])+'  ('+(n+1)+' of '+files.length+')  arrows to move, Esc to close';
  [].forEach.call(strip.children,function(b,j){b.className=j==n?'on':''});
  strip.children[n].scrollIntoView({inline:'nearest',block:'nearest'});
}
files.forEach(function(f,i){
  var b=document.createElement('button'),m=document.createElement('img');
  m.src=f; m.alt=name(f); b.title=name(f); b.tabIndex=-1;
  b.onclick=function(){show(i)}; b.appendChild(m); strip.appendChild(b);
});
addEventListener('keydown',function(e){
  if(e.key=='ArrowRight'||e.key=='ArrowDown'){show(n+1)}
  else if(e.key=='ArrowLeft'||e.key=='ArrowUp'){show(n-1)}
  else if(e.key=='Escape'||e.key=='Enter'){window.close()}
  else return;
  e.preventDefault();
});
show(0); window.focus();
</script>
EOF

"$AGTERMCTL" session overlay open --html "$dir/index.html" --cwd "$dir" --js --chromeless --size-percent 90 --block \
  --target "$AGT_SESSION_ID" --socket "$AGT_SOCKET" >/dev/null
rc=$?
# 2 is a page closed unanswered, the normal way out of this one
[ "$rc" -eq 2 ] && exit 0
exit "$rc"

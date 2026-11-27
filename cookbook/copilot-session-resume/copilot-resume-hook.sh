#!/usr/bin/env bash
# Copilot CLI sessionStart hook for copilot-session-resume: record which conversation this agterm pane shows.
#
# Copilot fires sessionStart at the first prompt of a conversation, again after /clear starts a new
# one and after /resume switches to another, so the mapping follows what the pane shows. Copilot
# parses a hook's stdout as JSON, so this prints nothing.
set -u

payload=
[ -t 0 ] || IFS= read -r -d '' -t 2 payload || true

uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
pane=$(printf '%s' "${AGTERM_PANE_ID:-}" | tr '[:upper:]' '[:lower:]')
[[ $pane =~ $uuid ]] || exit 0

# The copilot that fired this hook is its nearest ancestor that is not a shell. Only one the copilot
# function started may move the mapping, and the function always passes its marker as the first
# argument. Copilot's /restart starts the new process by its full path with the same arguments, so
# a path before `copilot` is accepted too. A typed `copilot -p`, and a worker an
# agent starts, are the nearest copilot themselves, whether a shell sits between them and the marked
# one or not.
owner=
p=$PPID
for _ in 1 2 3 4; do
  [ "$p" -gt 1 ] 2>/dev/null || break
  line=$(ps -ww -o ppid= -o command= -p "$p" 2>/dev/null) || break
  read -r ppid cmd <<<"$line"
  first=${cmd%% *}
  first=${first##*/}
  case ${first#-} in
    sh | bash | zsh | dash | env) p=$ppid ;;
    *)
      owner=$cmd
      break
      ;;
  esac
done
# The marker must follow the program itself: either a bare `copilot`, or a path that names an
# executable, so a marker inside prompt text never counts, and a path with spaces still does.
needle='copilot --secret-env-vars=AGTERM_COPILOT_RESUME'
case $owner in *"$needle"*) ;; *) exit 0 ;; esac
prefix=${owner%%"$needle"*}
case ${owner#"$prefix$needle"} in '' | ' '*) ;; *) exit 0 ;; esac
case $prefix in
  '') ;;
  */) [ -x "${prefix}copilot" ] || exit 0 ;;
  *) exit 0 ;;
esac

[[ $payload =~ \"sessionId\"[[:space:]]*:[[:space:]]*\"([0-9a-fA-F-]{36})\" ]] || exit 0
id=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
[[ $id =~ $uuid ]] || exit 0

dir=${COPILOT_HOME:-$HOME/.copilot}/agterm
mkdir -p "$dir" && printf '%s\n' "$id" > "$dir/$pane.tmp.$$" && mv -f "$dir/$pane.tmp.$$" "$dir/$pane"

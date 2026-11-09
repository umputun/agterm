#!/bin/zsh

emulate -L zsh
setopt pipefail

AGTERMCTL=${AGTERMCTL:-agtermctl}
export AGTERMCTL
AGT_BIN_PATH=${AGT_BIN_PATH:-/opt/homebrew/bin:/usr/local/bin}
export PATH="$AGT_BIN_PATH:$PATH"
state_file="${XDG_STATE_HOME:-$HOME/.local/state}/agterm/project-session-picker.json"

agt() {
  local socket=${AGT_SOCKET:-${AGTERM_SOCKET:-}}
  if [[ -n $socket ]]; then
    "$AGTERMCTL" "$@" --socket "$socket"
  else
    "$AGTERMCTL" "$@"
  fi
}

record_origin() {
  local state_dir=${state_file:h}
  local temp_file
  mkdir -p "$state_dir" || return 1
  temp_file=$(mktemp "$state_dir/.project-session-picker.XXXXXX") || return 1
  if [[ -f $state_file ]]; then
    jq --arg session_id "$1" --arg project_dir "$2" '.[$session_id] = $project_dir' "$state_file" > "$temp_file" || {
      rm -f "$temp_file"
      return 1
    }
  else
    jq -n --arg session_id "$1" --arg project_dir "$2" '{($session_id): $project_dir}' > "$temp_file" || {
      rm -f "$temp_file"
      return 1
    }
  fi
  mv "$temp_file" "$state_file"
}

if [[ $1 == --list ]]; then
  window=$2
  agt tree --json --window "$window" | jq -r '
    [.result.tree.workspaces[] as $workspace
      | $workspace.sessions[]
      | select(.cwd != null and .content != "page")
      | {id, name, cwd, workspace: $workspace.name, recency: (.lastSelectedAt // 0)}]
    | sort_by(-.recency)
    | .[]
    | "S:\(.id)|● \(.name | gsub("[|\\t\\r\\n]"; " "))  ·  \(.workspace | gsub("[|\\t\\r\\n]"; " "))  ·  \(.cwd | gsub("[|\\t\\r\\n]"; " "))"
  ' || exit 1

  zoxide query -l | jq -Rr '
    select(length > 0)
    | "D:\(. | @base64)|Folder  ·  \(. | gsub("[|\\t\\r\\n]"; " "))"
  '
  exit
fi

window=$1
[[ -n $window ]] || exit 1

export AGT_PROJECT_PICKER_SCRIPT=${0:A}
export AGT_PROJECT_PICKER_WINDOW=$window

selection=$(tv \
  --source-command 'zsh "$AGT_PROJECT_PICKER_SCRIPT" --list "$AGT_PROJECT_PICKER_WINDOW"' \
  --source-display '{split:|:1}' \
  --source-output '{split:|:0}' \
  --no-sort) || exit 0

case $selection in
  S:*)
    agt session select --target "${selection#S:}" --window "$window"
    ;;
  D:*)
    project_dir=$(jq -nr --arg encoded "${selection#D:}" '$encoded | @base64d') || exit 1
    [[ -d $project_dir ]] || exit 1
    origins='{}'
    if [[ -f $state_file ]]; then
      origins=$(cat "$state_file") || exit 1
    fi
    session_id=$(agt tree --json --window "$window" | jq -r --arg cwd "$project_dir" --argjson origins "$origins" '
      [.result.tree.workspaces[].sessions[]
        | select(.content != "page")
        | select(($origins[.id] // .cwd) == $cwd)]
      | max_by([(.lastSelectedAt // 0), .active])
      | .id // empty
    ') || exit 1
    if [[ -z $session_id ]]; then
      session_id=$(agt session new --cwd "$project_dir" --workspace-name "${project_dir:t}" --create-workspace --no-select --window "$window") || exit 1
    fi
    record_origin "$session_id" "$project_dir" || print -u2 'Could not save the session origin'
    agt session select --target "$session_id" --window "$window"
    ;;
esac

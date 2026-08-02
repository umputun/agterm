#!/usr/bin/env zsh
# claude-recap.zsh — recap what the Claude Code session in an agterm session was working on.
#
# resolves the target session's cwd, finds the newest Claude Code transcript for that directory,
# condenses it to user prompts plus trimmed assistant replies, and asks a small model for a short
# newest-first list of what was done.
#
# usage: claude-recap.zsh [agterm-session-id] [pane]
# meant to run inside an agterm overlay: the arguments are needed because a fresh overlay pty does
# not inherit $AGT_*.

set -u

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# full id, not the "haiku" alias — that is not a recognized alias and silently falls back to the
# session's default model, which is far slower and dearer for what is six one-line items
RECAP_MODEL="${RECAP_MODEL:-claude-haiku-4-5-20251001}"
# Claude Code config dirs to search for transcripts, space separated. add a second one here if you
# run more than one config dir
CLAUDE_DIRS="${CLAUDE_DIRS:-$HOME/.claude}"
# where a status-line hook records the transcript path per pane; see Limits in the README
PANE_MAP_DIR="${PANE_MAP_DIR:-/tmp/claude/panes}"
MAX_DIGEST_BYTES=120000   # ~30k tokens of transcript fed to the model
ASSISTANT_TRIM=400        # per-reply cut, enough to show the outcome without the reasoning

bold=$'\033[1m'; dim=$'\033[2m'; age_c=$'\033[38;5;108m'; rst=$'\033[0m'

# the whole run is a few seconds of waiting, so the wait gets a spinner naming the current step.
# the phase lives in a file because the spinner runs in a background subshell that cannot see later
# assignments in this one
phase_file=$(mktemp /tmp/claude-recap.XXXXXX)
spinner_pid=""

cleanup() {
    [ -n "$spinner_pid" ] && kill "$spinner_pid" 2>/dev/null
    rm -f "$phase_file"
    printf '\033[?25h'   # cursor back, whatever the exit path
}
trap cleanup EXIT INT TERM

phase() {
    printf '%s' "$1" > "$phase_file"
    [ -n "$spinner_pid" ] && return
    (
        frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
        i=1
        while :; do
            printf '\r\033[2K  %s%s%s %s%s ...%s' \
                "$age_c" "$frames[i]" "$rst" "$dim" "$(cat "$phase_file")" "$rst"
            i=$(( i % $#frames + 1 ))
            sleep 0.08
        done
    ) &
    spinner_pid=$!
}

phase_stop() {
    [ -n "$spinner_pid" ] && kill "$spinner_pid" 2>/dev/null
    spinner_pid=""
    printf '\r\033[2K'
}

die() {
    phase_stop
    printf "\n  %s\n\n" "$1"
    read -k1 -s -r "?Press any key to close..."
    exit 0
}

printf '\033[?25l'
printf '\n  %sclaude recap%s\n\n' "$bold" "$rst"
phase "resolving session"

# session cwd: ask agterm for the focused pane's directory, fall back to the overlay's own cwd
sid="${1:-}"
pane="${2:-left}"
cwd=""
if [ -n "$sid" ] && command -v agtermctl >/dev/null 2>&1; then
    cwd=$(agtermctl tree --json 2>/dev/null | \
        jq -r --arg id "$sid" '.result.tree.workspaces[].sessions[] | select(.id==$id) | .cwd' 2>/dev/null | head -1)
fi
[ -n "$cwd" ] || cwd="$PWD"

# the exact transcript, recorded per pane by a status-line hook. this is the only source that
# survives a worktree: claude moves its transcript to the worktree's project dir while the pane's
# shell stays put, and two panes on the same repo have identical cwds
transcript=""
pane_map="$PANE_MAP_DIR/${sid}.${pane}"
[ -n "$sid" ] && [ -r "$pane_map" ] && transcript=$(head -1 "$pane_map")
[ -n "$transcript" ] && [ -f "$transcript" ] || transcript=""

# fallback with no pane map: newest transcript filed under the cwd, which Claude Code slugs by
# replacing every non-alphanumeric char with a dash
if [ -z "$transcript" ]; then
    slug=$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')
    candidates=()
    for dir in ${=CLAUDE_DIRS}; do
        candidates+=("$dir/projects/$slug"/*.jsonl(N))
    done
    [ ${#candidates} -gt 0 ] && transcript=$(ls -t -- "${candidates[@]}" 2>/dev/null | head -1)
fi
[ -n "$transcript" ] && [ -f "$transcript" ] || die "no claude code session found for $cwd"

phase "reading transcript"
now_epoch=$(date +%s)

# shared by the digest and the header — an iso timestamp to a relative age
ago_def='def ago: (try ($now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) catch null)
       | if . == null then "?"
         elif . < 60 then "just now"
         elif . < 3600 then "\(./60|floor)m ago"
         elif . < 86400 then "\(./3600|floor)h ago"
         else "\(./86400|floor)d ago" end;'

# last timestamp and last cwd, in one pass. the cwd is claude's own, which is the worktree it moved
# into rather than the pane's shell directory — report what the session was actually working in
meta=$(jq -r 'select(.timestamp or .cwd) | [(.timestamp // ""), (.cwd // "")] | @tsv' "$transcript" 2>/dev/null)
last_ts=$(printf '%s\n' "$meta" | cut -f1 | grep -v '^$' | tail -1)
last_cwd=$(printf '%s\n' "$meta" | cut -f2 | grep -v '^$' | tail -1)
[ -n "$last_cwd" ] && cwd="$last_cwd"

# how stale the recap is — the header states it outright instead of claiming a present tense the
# transcript cannot support
last_age=$(printf '%s' "$last_ts" | jq -Rr --argjson now "$now_epoch" "$ago_def"' ago' 2>/dev/null)

# condense the transcript: human prompts in full, assistant replies trimmed, tool traffic dropped.
# prompts carry a relative-age tag so the model can date each item without doing the arithmetic
digest=$(jq -rj --argjson trim "$ASSISTANT_TRIM" --argjson now "$now_epoch" "$ago_def"'
    def strip: gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
             | gsub("(?s)<local-command-caveat>.*?</local-command-caveat>"; "")
             | gsub("^[[:space:]]+|[[:space:]]+$"; "");

    if .type=="user" and (.message.content|type=="string") then
        (.message.content|strip) as $t
        | if ($t|length) == 0 or ($t|startswith("[Request interrupted")) then empty
          else "\n[" + (.timestamp // "" | ago) + "] USER: " + $t + "\n" end
    elif .type=="assistant" and (.message.content|type=="array") then
        ((.message.content | map(select(.type=="text").text) | join(" ") | strip)) as $t
        | if ($t|length) == 0 then empty else "CLAUDE: " + $t[0:$trim] + "\n" end
    else empty end
' "$transcript" 2>/dev/null)

[ -n "$digest" ] || die "transcript has no readable conversation: $transcript"

# keep the tail — the recent work is what the user is coming back to
digest=$(printf '%s' "$digest" | tail -c "$MAX_DIGEST_BYTES")

prompt='Below is a condensed Claude Code session transcript (oldest first) from the directory '"$cwd"'.
Summarize what was worked on so the user can pick the task back up.

Each user prompt is tagged with how long ago it was sent, e.g. "[3h ago] USER: ...".

Rules:
- split the session into distinct pieces of work, NEWEST FIRST, and cover ALL of it
- every distinct piece of work gets its own item — never merge unrelated work into one item, and
  never merge an investigation with the separate fix, review or merge that followed it
- 6 items maximum: if the session holds more, keep the 6 NEWEST and drop the older ones. produce
  fewer than 6 only when the session genuinely contains fewer distinct pieces of work
- "age" is the tag of the most recent prompt in that group, without its square brackets (e.g. "3h ago")
- "title" is at most 8 words
- "detail" is one sentence, at most 25 words, and never states the status
- "status" is judged from the WHOLE transcript, not from that group alone:
    done        the work reached a conclusion anywhere later in the transcript — committed,
                merged, pushed, verified, or a question answered. ALSO done when a later group
                continues it and that one concluded: an investigation whose fix was merged is done
    in progress no conclusion anywhere after it. normally only the newest group can be this
    blocked     it stopped on something unresolved and nothing after it resolved that
    abandoned   dropped with no conclusion and no later work on it
- when unsure between done and in progress, choose done — most work in a finished session concluded
- no markdown, no backticks, no quotes around names, lowercase prose throughout

Transcript:
'

schema='{"type":"object","properties":{
  "items":{"type":"array","maxItems":6,"items":{"type":"object","properties":{
    "age":{"type":"string"},"title":{"type":"string"},"detail":{"type":"string"},
    "status":{"type":"string","enum":["done","in progress","blocked","abandoned"]}},
    "required":["age","title","detail","status"]}}},
  "required":["items"]}'

phase "summarizing"
# MAX_THINKING_TOKENS=0 is the difference between seconds and a minute and a half: without it the
# model spends thousands of thinking tokens on what is six one-line items. --safe-mode drops
# CLAUDE.md, rules, skills, plugins, hooks and MCP, leaving a few hundred input tokens of harness
# context (--bare would go further but never reads OAuth or the keychain, so it cannot authenticate
# a subscription)
summary=$(printf '%s%s' "$prompt" "$digest" | \
    MAX_THINKING_TOKENS=0 "$CLAUDE_BIN" -p --model "$RECAP_MODEL" --safe-mode \
        --no-session-persistence --tools "" \
        --system-prompt "You summarize development session transcripts. Be terse and concrete. Write in lowercase prose. Never exceed a stated length limit." \
        --json-schema "$schema" 2>&1)

phase_stop
[ -n "$summary" ] || die "summary failed (empty response from claude)"
printf '%s' "$summary" | jq -e '.items' >/dev/null 2>&1 || die "unexpected response: $summary"

# render by hand rather than through a markdown pager: the two-line item shape (bold age + title,
# indented wrapped detail) is not something a markdown renderer keeps
width=${COLUMNS:-100}
[ "$width" -gt 110 ] && width=110
[ "$width" -lt 46 ] && width=46
body=$((width - 8))

# right-align the staleness against the header, dropping to its own line when they collide
stale="last active ${last_age:-?}"
head_left="claude recap  $cwd"
gap=$((width - 4 - ${#head_left} - ${#stale}))

clear
if [ "$gap" -ge 2 ]; then
    printf '\n  %sclaude recap%s  %s%s%*s%s%s\n' \
        "$bold" "$rst" "$dim" "$cwd" "$gap" '' "$stale" "$rst"
else
    printf '\n  %sclaude recap%s  %s%s%s\n  %s%s%s\n' \
        "$bold" "$rst" "$dim" "$cwd" "$rst" "$dim" "$stale" "$rst"
fi
printf '  %s%s%s\n\n' "$dim" "$(printf '%*s' $((width - 4)) '' | sed 's/ /─/g')" "$rst"

# sort here rather than trusting the model's "newest first" — it silently emits oldest-first often
# enough that the ordering has to be mechanical. the age string is parsed back into seconds
printf '%s' "$summary" | jq -r '
    def secs: if test("just now") then 0
              elif test("[0-9]+ *m") then (capture("(?<n>[0-9]+) *m").n | tonumber) * 60
              elif test("[0-9]+ *h") then (capture("(?<n>[0-9]+) *h").n | tonumber) * 3600
              elif test("[0-9]+ *d") then (capture("(?<n>[0-9]+) *d").n | tonumber) * 86400
              else 9999999999 end;
    .items
    | map(.age |= gsub("[\\[\\]]"; ""))
    | sort_by(.age | secs)
    | .[] | [.age, .title, .detail, (.status // "")] | @tsv' | \
while IFS=$'\t' read -r age title detail st; do
    case "$st" in
        done)          st_c=$'\033[38;5;108m' ;;
        "in progress") st_c=$'\033[38;5;179m' ;;
        blocked)       st_c=$'\033[38;5;167m' ;;
        *)             st_c="$dim" ;;
    esac
    printf '  %s%s%s %s—%s %s%s%s  %s%s%s\n' \
        "$age_c" "$age" "$rst" "$dim" "$rst" "$bold" "$title" "$rst" "$st_c" "$st" "$rst"
    printf '%s\n' "$detail" | fold -s -w "$body" | sed 's/^/      /'
    printf '\n'
done

read -k1 -s -r "?Press any key to close..."

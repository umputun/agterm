#!/bin/sh
# transcript-view.sh TRANSCRIPT TITLE [--follow] - page a subagent transcript in an agterm overlay.
# Claude Code JSONL and Codex rollouts render as turns and tool calls with their bookkeeping skipped; other
# JSONL renders role/content records as turns and the rest as indented JSON. JavaScript for Automation does
# the rendering because macOS 14 has no jq. --follow keeps appending a running subagent's new records.
# The pager holds a compact rendering that cuts long tool output and the full one, switched with :n and :p.
set -u
[ "$#" -ge 2 ] || { echo "usage: $0 TRANSCRIPT TITLE [--follow]" >&2; exit 2; }
transcript=$1
title=$2
follow=${3:-}

# render FROM UPTO HEADER MODE prints the complete lines [FROM, UPTO) of the transcript, see the header below
render() {
  /usr/bin/osascript -l JavaScript - "$transcript" "$title" "$1" "$2" "$3" "$4" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  // FROM and UPTO pick complete lines to render, so a follower appends only what is new; HEADER is
  // `header`, `follow-header` (a running subagent's first frame), or empty for an appended chunk; MODE
  // `compact` cuts a tool's output past a dozen lines
  const [path, title, fromArg, uptoArg, header, mode] = argv;
  const dim = s => '\x1b[2m' + s + '\x1b[0m';
  const bold = s => '\x1b[1m' + s + '\x1b[0m';
  const out = header ? [bold(title), dim('─'.repeat(Math.min(Math.max(title.length, 20), 80))), ''] : [];
  const raw = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (raw.isNil()) {
    if (header === 'follow-header') out.push(dim('Waiting for the agent to write this transcript…'));
    else if (header) out.push('The agent has not written this transcript yet.', dim(path));
    return out.join('\n');
  }
  // per line, so a style survives the pager scrolling into the middle of a long block
  const dimLines = s => String(s).split('\n').map(dim).join('\n');
  const toolOutput = s => {
    const rows = String(s).split('\n');
    if (mode !== 'compact' || rows.length <= 12) return dimLines(s);
    return dimLines(rows.slice(0, 8).join('\n') + '\n… ' + (rows.length - 8) + ' more lines · :n full output');
  };
  const text = c => typeof c === 'string' ? c : Array.isArray(c) ? c.map(p => p.text || '').join('\n') : '';
  // while following, an unterminated last line is a record the agent is still writing and waits for the next
  // pass; a finished transcript's last line counts even without its newline
  const split = raw.js.split('\n');
  const complete = header === 'header' ? split : split.slice(0, -1);
  const lines = complete.slice(0, uptoArg ? Math.min(Number(uptoArg), complete.length) : complete.length);
  const from = Number(fromArg || 0);
  const parse = line => { try { return JSON.parse(line); } catch (e) { return undefined; } };
  const entries = lines.map(parse);
  // a Claude transcript interleaves turns with bookkeeping records, which only make sense skipped
  const claude = entries.some(e => e && e.message && e.message.role);
  // a Codex rollout wraps everything readable in `response_item` records; the rest is bookkeeping
  const codex = !claude && entries.some(e => e && e.type === 'session_meta' && e.payload);
  if (codex) {
    // Codex hands messages between agents over encrypted; a page of base64 says nothing, so name it instead
    const compact = s => String(s).replace(/[A-Za-z0-9_\-+\/=]{200,}/g, m => '[encrypted ' + m.length + ' chars]');
    const texts = parts => (parts || []).map(p => p && typeof p.text === 'string' ? p.text : '').filter(t => t.trim()).join('\n');
    const outputText = o => {
      if (typeof o !== 'string') return text(o);
      try { const parsed = JSON.parse(o); return Array.isArray(parsed) ? texts(parsed) : o; } catch (e) { return o; }
    };
    // a subagent's rollout opens with a copy of its parent's conversation; its own work starts at its task.
    // A follower that has not seen the task yet skips the copy; a finished file without one shows everything.
    let start = from;
    const meta = entries.find(e => e && e.type === 'session_meta');
    if (meta && meta.payload && meta.payload.forked_from_id) {
      const task = entries.findIndex(e => e && e.type === 'response_item' && e.payload && e.payload.type === 'agent_message');
      if (task >= 0) start = Math.max(from, task);
      else if (header !== 'header') start = entries.length;
    }
    for (let i = start; i < entries.length; i++) {
      const entry = entries[i];
      const item = entry && entry.type === 'response_item' ? entry.payload : null;
      if (!item) continue;
      if (item.type === 'message' && (item.role === 'user' || item.role === 'assistant')) {
        const body = texts(item.content);
        // the environment block is Codex's own context, not something the user said
        if (body.trim() && !body.startsWith('<environment_context>')) out.push(bold('── ' + item.role + ' ──'), body.trim(), '');
      } else if (item.type === 'agent_message') {
        const body = texts(item.content);
        if (body.trim()) out.push(bold('── task ──'), body.trim(), '');
      } else if (item.type === 'custom_tool_call' || item.type === 'function_call') {
        out.push(bold('▸ ' + item.name) + ' ' + compact(item.input || item.arguments || ''));
      } else if (item.type === 'custom_tool_call_output' || item.type === 'function_call_output') {
        out.push(toolOutput(compact(outputText(item.output))), '');
      }
    }
    return out.join('\n');
  }
  for (let i = from; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const entry = entries[i];
    if (entry === undefined || entry === null || typeof entry !== 'object') { out.push(lines[i]); continue; }
    // Claude Code 2.1.299 also logs each API request (`api-request-blob`) with a role: the whole context, not a turn
    if (claude && entry.type !== 'user' && entry.type !== 'assistant') continue;
    const message = entry.message && entry.message.role ? entry.message : (entry.role ? entry : null);
    if (!message) {
      if (!claude) out.push(dimLines(JSON.stringify(entry, null, 2)), '');
      continue;
    }
    const parts = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : (message.content || []);
    for (const part of parts) {
      if (part.type === 'tool_use') {
        const input = part.input || {};
        // a tool whose only argument is text (a handback's `message`) reads better as that text than as JSON
        const values = Object.values(input);
        const lone = values.length === 1 && typeof values[0] === 'string' ? values[0] : null;
        const summary = input.command || input.file_path || input.pattern || input.description || lone || JSON.stringify(input);
        out.push(bold('▸ ' + part.name) + ' ' + summary);
      } else if (part.type === 'tool_result') {
        out.push(toolOutput(text(part.content)), '');
      } else if (typeof part.text === 'string') {
        // `text`, and the `input_text`/`output_text` parts OpenAI-style agents write. Claude Code injects its
        // own `<system-reminder>` blocks as user turns; they are not something anyone said
        const body = part.text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
        if (body) out.push(bold('── ' + message.role + ' ──'), body, '');
      }
    }
  }
  return out.join('\n');
}
JXA
}

complete_lines() { if [ -r "$transcript" ]; then wc -l < "$transcript" | tr -d ' '; else echo 0; fi; }

if [ ! -t 1 ]; then
  render 0 "" header full
  exit 0
fi

compact=$(mktemp -t agterm-transcript) || exit 1
full=$(mktemp -t agterm-transcript) || exit 1
# the picker reads this pid to tell its own overlay from another program's; a viewer it replaced exits after the
# new one wrote its pid, so the file is removed only while it still names this viewer
pid_file=${AGT_SUBAGENT_VIEWER_PID_FILE:-}
[ -n "$pid_file" ] && echo $$ > "$pid_file"
cleanup() {
  rm -f "$compact" "$full"
  [ -n "$pid_file" ] && [ "$(cat "$pid_file" 2>/dev/null)" = "$$" ] && rm -f "$pid_file"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
# less fills %x with the next file's name; the first file has one, the full rendering does not
keys='?x\:n full output:\:p compact view. · q back to the chat · ↑↓ Space scroll · / search · G end · h help'

if [ "$follow" != --follow ]; then
  render 0 "" header compact > "$compact"
  render 0 "" header full > "$full"
  LESS='' less -R -~ +g -Ps"$keys" "$compact" "$full"
  exit 0
fi

seen=$(complete_lines)
render 0 "$seen" follow-header compact > "$compact"
render 0 "$seen" follow-header full > "$full"
(
  # stops with the pager: $$ is this script, which outlives the follower only while less runs
  while kill -0 $$ 2>/dev/null; do
    sleep 1
    total=$(complete_lines)
    [ "$total" -gt "$seen" ] || continue
    for mode in compact full; do
      if [ "$mode" = compact ]; then target=$compact; else target=$full; fi
      chunk=$(render "$seen" "$total" "" "$mode")
      [ -n "$chunk" ] && printf '%s\n' "$chunk" >> "$target"
    done
    seen=$total
  done
) &
follower=$!
LESS='' less -R -~ +G -Ps"live · G for the latest output · $keys" "$compact" "$full"
kill "$follower" 2>/dev/null

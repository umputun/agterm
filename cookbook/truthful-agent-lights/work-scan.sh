#!/usr/bin/env bash
# work-scan.sh — classify the live work under an agent process.
#
#   work-scan.sh <agent-pid> [caller-pid]
#
# Prints one line: "agents=N machinery=M waiting=K remote=R watch=W".
#
#   agents    — a tool subtree containing another agent binary: a dispatched
#               worker or subagent that is still running
#   machinery — a tool subtree doing real work (tests, builds, a long-lived ssh
#               that IS a remote run)
#   waiting   — a tool subtree whose every leaf is wait-shaped (sleep, flock,
#               a poll loop, a short ssh probe), or that has no leaves at all
#   remote    — long-lived ssh/scp subtrees, counted separately so the caller
#               can treat a remote run as running work
#   watch     — pure log-watcher pipelines (tail/grep), which accompany a real
#               run and must not read as "queued for more"
#
# What makes this possible: Claude Code runs every tool command — foreground
# and background alike — under a recognizable wrapper shell, `zsh -c source
# …/shell-snapshots/snapshot-….sh && …`, as a child of the agent process, while
# MCP servers and harness helpers are direct children WITHOUT that wrapper. So
# "is a tool still running" is a question about wrapper subtrees, and the
# helpers never pollute the count. That wrapper shape is undocumented; see the
# recipe's Limits.
#
# ssh is disambiguated by age rather than by name: a reachability probe lives
# seconds, a remote build holds its pipe for minutes, so an ssh older than
# AGT_SSH_WORK_SECS counts as a run and a younger one as a wait.
#
# The caller's own process chain is excluded, so a hook never counts itself.
# Every ancestry walk is hop-capped: a cyclic ps row must spoil a count, never
# hang the hook.
#
# Set AGT_SCAN_PIDS=1 to get a second line, "pids=…", listing the members of
# the MACHINERY subtrees only — the caller can then measure whether the work it
# is about to report is really computing. Waiters and log watchers are left out
# on purpose: an `rg` burning cpu inside a watcher subtree would otherwise vouch
# for machinery that is doing nothing.
# Set AGT_SCAN_PS_FILE to a file of "pid ppid etime command" lines to classify
# canned input instead of live ps, which is how this is tested.
set -u
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lights-common.sh
. "$DIR/lights-common.sh"

root=${1:?agent pid required}
self=${2:-$$}

if [ -n "${AGT_SCAN_PS_FILE:-}" ]; then
  ps_out=$(cat "$AGT_SCAN_PS_FILE")
else
  ps_out=$(ps -axo pid=,ppid=,etime=,command=)
fi

# AGT_AGENT_PATTERN travels through the environment rather than -v, because awk
# interprets escape sequences in a -v value: a reader who escapes a regex
# metacharacter would get a different pattern here than in the grep that reads
# the same variable. The numeric -v values have nothing to escape.
printf '%s\n' "$ps_out" |
  AGT_AGENT_PATTERN="$AGT_AGENT_PATTERN" awk \
  -v root="$root" -v self="$self" -v sshwork="$AGT_SSH_WORK_SECS" '
BEGIN { agentre = "^(" ENVIRON["AGT_AGENT_PATTERN"] ")$" }
function base(pid,   b) {
  b = command[pid]; sub(/ .*/, "", b); sub(/.*\//, "", b)
  sub(/^\(/, "", b); sub(/\)$/, "", b)   # ps prints (name) when argv is unreadable
  return b
}
function etime_secs(e,   d, parts, hms, n, s, i) {
  d = 0
  if (e ~ /-/) { split(e, parts, "-"); d = parts[1]; e = parts[2] }
  n = split(e, hms, ":"); s = 0
  for (i = 1; i <= n; i++) s = s * 60 + hms[i]
  return d * 86400 + s
}
{
  pid = $1; ppid = $2; et = $3; cmd = ""
  for (i = 4; i <= NF; i++) cmd = cmd (i > 4 ? " " : "") $i
  parent[pid] = ppid; command[pid] = cmd; age[pid] = etime_secs(et)
}
END {
  CAP = 256   # hop cap on every upward walk

  # mark the caller chain so the hook never counts itself as work
  p = self; hops = 0
  while (p in parent && p != root && hops++ < CAP) { excluded[p] = 1; p = parent[p] }

  # the tool-wrapper shells that sit under the agent process
  for (pid in parent) {
    if (command[pid] !~ /shell-snapshots\/snapshot-/) continue
    if (pid in excluded) continue
    q = pid; under = 0; hops = 0
    while (q in parent && hops++ < CAP) {
      if (q in excluded) break
      if (parent[q] == root) { under = 1; break }
      q = parent[q]
    }
    if (under) wrappers[pid] = 1
  }

  # attribute every other process to its nearest wrapper ancestor
  for (pid in parent) {
    if (pid in wrappers) continue
    q = parent[pid]; hops = 0; w = ""
    while (q in parent && hops++ < CAP) {
      if (q in wrappers) { w = q; break }
      q = parent[q]
    }
    if (w == "") continue
    b = base(pid)
    # exact basename, both ends anchored: a prefix match would read `ping` and
    # `pip` as agents and pulse the row for a worker that is not there
    if (b ~ agentre) { agentwrap[w] = 1; continue }
    if (b ~ /^(zsh|bash|sh|dash|-zsh|-bash)$/) continue            # structure
    if (b ~ /^(ssh|scp)$/) {
      if (age[pid] >= sshwork) remotework[w] = 1; else waitq[w] = 1
      continue
    }
    if (b ~ /^(tail|tee|cat|grep|egrep|fgrep|zgrep|ugrep|ggrep|rg)$/) {
      watch[w] = 1; continue                                       # log watcher
    }
    if (b ~ /^(sleep|flock|inotifywait|fswatch|wait4path|caffeinate|pgrep|git|gh|jq|curl|date|stat|cut|tr|sort|head|wc|sed|awk|uname|hostname|ping|timeout|gtimeout)$/) {
      waitq[w] = 1; continue                                       # queue or probe
    }
    realwork[w] = 1                                                # actual work
  }

  agents = 0; machinery = 0; waiting = 0; remote = 0; watching = 0
  for (w in wrappers) {
    if (w in agentwrap)        agents++
    else if (w in realwork)    machinery++
    else if (w in remotework)  remote++
    else if (w in waitq)       waiting++
    else if (w in watch)       watching++
    else                       waiting++   # no leaves at all: an idling loop shell
  }
  printf "agents=%d machinery=%d waiting=%d remote=%d watch=%d\n", \
    agents, machinery, waiting, remote, watching

  if (ENVIRON["AGT_SCAN_PIDS"] == "1") {
    # machinery subtrees only: the same subtrees the machinery count is built
    # from, so a cpu measurement over them answers exactly the question asked
    out = ""
    for (pid in parent) {
      if (pid in wrappers) {
        if ((pid in realwork) && !(pid in agentwrap)) out = out " " pid
        continue
      }
      q = parent[pid]; hops = 0
      while (q in parent && hops++ < CAP) {
        if (q in wrappers) {
          if ((q in realwork) && !(q in agentwrap)) out = out " " pid
          break
        }
        q = parent[q]
      }
    }
    printf "pids=%s\n", out
  }
}'

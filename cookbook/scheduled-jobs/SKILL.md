---
name: cronn
description: Install cronn, then add, remove, list, report on and control the scheduled jobs it runs on this Mac, including jobs that open agterm sessions. Use when the user says "cronn", "cronn status", "schedule a job", "add a cron job", "run this every morning", "what jobs are scheduled", "what runs next", "run that job now", "disable that job", "did that job run", "why did the job fail", "show the cronn dashboard", or asks for a scheduled agent session in agterm.
---

# cronn

cronn runs as a launchd agent, schedules the jobs in one YAML file and serves a dashboard and a
read-only API on loopback. This skill's `scripts/` directory holds the installer and a job template;
paths below are relative to this skill's directory.

## Is it installed

Read the settings the installer recorded, then ask the API:

```bash
. "${CRONN_CONFIG_DIR:-$HOME/.config/cronn}/cronn.env"
curl -fsS "http://127.0.0.1:$CRONN_PORT/api/v1/status" >/dev/null && echo running
```

When `cronn.env` is missing, cronn is not set up here. Tell the user
what `scripts/install.sh` does and ask before running it: it installs the `umputun/apps/cronn`
Homebrew formula and a LaunchAgent that starts at every login. `scripts/install.sh --dry-run`
prints the plan and the rendered plist without changing anything. After the install, read
`cronn.env` again. When the installer refuses because the port is taken, report the pid it names
and let the user choose `CRONN_PORT`; never stop the other process.

When `cronn.env` exists but the API is down, the agent is installed and not serving; go to
*When something is not running*.

## Showing the dashboard

Inside agterm (`AGTERM_SESSION_ID` set), open it in an overlay:

```bash
agtermctl session overlay open --url "http://127.0.0.1:$CRONN_PORT/" --js --chromeless \
    --size-percent 80 --target "$AGTERM_SESSION_ID" --follow
```

`--js` is required: the page is htmx-driven, and without it the run and toggle buttons, the
filters and the 5s refresh do nothing. `--chromeless` drops the strip above the page; ⌘W closes
it. Leave it up for the user to close. Outside agterm, `open` the same URL.

## The jobs file

`$CRONN_CONFIG_DIR/crontab.yml` is the only file cronn reads, and it rereads it every 10s, so an
edit needs no restart and no reload command. The dashboard catches up within about 30s.

**A file that fails to parse leaves the previous schedule running.** cronn logs
`can't get list of jobs from ... failed to parse YAML` to `$CRONN_LOG_DIR/cronn.log` and keeps
the old jobs. After every edit, wait 15s and check both: no new parse warning in the log, and
the job present in `/api/v1/status`. A job that does not appear is an edit that did not land.

## Adding a job

```yaml
jobs:
  - spec: "0 3 * * *"
    command: "/opt/homebrew/bin/brew cleanup"
    name: "brew cleanup"
```

`spec` is a 5-field cron expression or an `@` descriptor (`@hourly`, `@daily`, `@every 1h15m`).
`sched: {minute: "0", hour: "3"}` is the structured alternative; the two are mutually exclusive.
`name` is optional and shows on the dashboard.

- **Commands run under `sh -c` with the PATH the LaunchAgent sets**, never a login shell: no
  `.zshrc`, aliases or functions. Spell binaries absolutely, or confirm they sit in that PATH
  (`plutil -p ~/Library/LaunchAgents/$CRONN_LABEL.plist`).
- **`{{.YYYYMMDD}}` and the other templates are expanded by cronn** before the command runs, so a
  command cannot contain a literal `{{`.
- **A job's id is the SHA256 of its command string.** Two jobs with the same command collide on
  one dashboard row whatever their schedules, and editing a command gives it a new id: it loses
  its history and comes back enabled.
- The agent runs with `--dedup`, so a run still going when its next slot arrives skips that slot.

Ask whether the job should post a notification and on which paths: success and failure, failure
only, or none. A scheduled job that fails silently looks the same as one that never ran.
`osascript -e 'display notification "..." with title "..."'` needs nothing installed.

## Writing a job script

Keep job scripts in `$CRONN_CONFIG_DIR/jobs/` and name them absolutely in the jobs file. A job is
a shell script when it is a few commands with fixed inputs; once it parses structured output,
retries or branches a lot, write it in Python. Use an agent only where the work needs judgment.

**A job can drive agterm through `agtermctl`.** `scripts/agent-session-job.sh` is the template:
copy it into `jobs/`, then set its variables on the command line.

```yaml
  - spec: "30 8 * * 1-5"
    command: "JOB_NAME=standup JOB_CWD=$HOME/src/myapp JOB_PROMPT='summarize what changed since yesterday' $HOME/.config/cronn/jobs/agent-session-job.sh"
    name: "standup summary"
```

The template follows four rules that any job driving agterm needs:

- Every `agtermctl` call defaults to the frontmost window. Find the window holding the target
  workspace (`window list --json`, then `tree --json --window`) and pass `--window`.
- A `--command` session starts with agterm's GUI PATH, not the job's. Wrap the program in
  `/usr/bin/env PATH=...` or spell it absolutely.
- `--command` is split into argv by libghostty, not by a shell. Anything with quotes, `$` or
  newlines goes through a script `/bin/sh` runs, as the template's launcher file does.
- `--no-select` keeps the new session from taking focus while the user is working.

The agent's working directory must already be trusted by that agent, or the session stops on the
trust prompt with nobody there to answer it. agterm must be running when the job fires; the
template fails with a notification when it is not.

## Removing a job

Delete it from the jobs file. It leaves the scheduler within 10s but stays on the dashboard until
the web side resyncs, usually 30s and sometimes over a minute; poll the status API until it is
gone. Its execution history stays in the database, and adding the identical command back later
reattaches that history.

## Reporting

```bash
curl -sS "http://127.0.0.1:$CRONN_PORT/api/v1/status" | jq -r '.jobs | sort_by(.next_run // "z") | .[] |
    [.command, .schedule,
     (if .is_running then "running" elif (.enabled | not) then "disabled"
      elif (.last_status // "") == "" then "idle" else .last_status end),
     (.last_run // "-"), (.next_run // "-")] | @tsv'
```

`status` lists every job with `id`, `command`, `schedule`, `enabled`, `is_running`,
`last_status`, `last_run` and `next_run`, plus a `stats` summary; the query above prints them in
the order they run next. The API has no job name: match `command` against the jobs file to report
the `name`. A `next_run` already in the past means the scheduler missed that slot, usually because
the Mac was asleep; the job runs at its next slot and does not catch up.

```bash
curl -sS "http://127.0.0.1:$CRONN_PORT/api/v1/jobs/<id>/history"
curl -sS "http://127.0.0.1:$CRONN_PORT/api/v1/jobs/<id>/executions/<exec_id>/logs"
```

`history` holds recent runs with exit codes; `logs` is the captured output of one run, which is
where "why did it fail" is answered. Take ids from the API rather than computing them.

## Run now, disable, enable

These are POSTs to the dashboard's own endpoints. Plain `curl` passes its cross-origin check; an
`Origin` header that does not match the host gets a 403, so do not add one.

```bash
curl -sS -X POST "http://127.0.0.1:$CRONN_PORT/api/jobs/<id>/run"      # 202 accepted
curl -sS -X POST "http://127.0.0.1:$CRONN_PORT/api/jobs/<id>/toggle"   # 200
```

**`toggle` flips the state, it does not set one.** To disable a job, read `enabled` from
`status`, POST `toggle` only when it is true, then read `status` again. **Never retry a `toggle`
that timed out or whose response you did not read**: it may have applied, and a second one flips
it back.

`run` answers 400 when the job is disabled (do not enable it to force a run without asking), 409
when it is already running, and 403 when manual runs are switched off.

## When something is not running

- `launchctl print gui/$(id -u)/$CRONN_LABEL`: whether the agent is loaded and its last exit.
- `$CRONN_LOG_DIR/cronn.log`: cronn's own log, including job output and parse warnings.
- `$CRONN_LOG_DIR/cronn.launchd.log`: launchd-level failures, plus the version line cronn prints
  at startup.
- `scripts/install.sh` again re-renders the agent and restarts it, along with any job running at
  that moment, so ask the user first. It reuses the port, label and log dir recorded in
  `cronn.env` and never touches the jobs file once it exists. For a newer cronn, run
  `brew upgrade umputun/apps/cronn` first, then the installer. `scripts/install.sh --uninstall`
  removes the agent and `cronn.env`, and keeps the jobs and history.

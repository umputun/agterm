# Scheduled jobs

Let a coding agent install [cronn](https://github.com/umputun/cronn), schedule and inspect jobs on your Mac, and run jobs that open agterm sessions for you.

## What it does

cronn is a cron replacement with a web dashboard and a local API. This recipe runs it as a per-user launchd agent and gives Claude Code a skill for it, so scheduling becomes a conversation:

- "schedule `brew cleanup` every night at 3" adds the job and checks that cronn picked it up.
- "cronn status" lists every job with its last result and when it runs next.
- "why did the backup job fail" reads that run's captured output.
- "show the cronn dashboard" opens it in an agterm overlay over the current session.
- "run that job now" and "disable that job" go through the dashboard's own endpoints.

When cronn is not installed, the skill says so, explains what the installer will change, and runs it once you agree.

Jobs can drive agterm too. `scripts/agent-session-job.sh` is a job template that opens a background session in a named workspace, starts an agent there on a prompt, sets the title-bar context and badges the row. A weekday 8:30 job can leave a Claude Code session with "summarize what changed since yesterday" already answered in a `scheduled` workspace, waiting for you to read it.

## Requirements

- agterm 0.37.0 or later, the release where `session overlay open --url --chromeless` began accepting a page served from this Mac, which the dashboard overlay uses. The job template needs only `session new`, `session context` and `notify`, all older.
- Homebrew. The installer adds the `umputun/apps` tap's `cronn` formula; the skill was written against cronn 1.16.2.
- Claude Code for the skill. The skill is plain instructions, so another agent that loads `SKILL.md` files works the same way.
- `jq` for the job template and the skill's status query, `curl` and `launchctl`, which macOS ships.
- `agtermctl` on the PATH the agent's jobs see. **Help ▸ Install Command Line Tool…** puts it in `/usr/local/bin`, which the installer includes.

## Setup

Install the skill with its scripts. The skill finds the installer and the job template in its own `scripts/` directory, so the two go together:

```sh
mkdir -p ~/.claude/skills/cronn/scripts
cp SKILL.md ~/.claude/skills/cronn/
cp scripts/install.sh scripts/cronn.plist.tmpl scripts/agent-session-job.sh ~/.claude/skills/cronn/scripts/
```

That is all the setup the recipe needs: the first time you ask about a job, the agent finds cronn missing and offers to install it. To install it yourself instead, preview first and then run:

```sh
~/.claude/skills/cronn/scripts/install.sh --dry-run
~/.claude/skills/cronn/scripts/install.sh
```

The installer reads four variables, each with a default:

| variable | default | what it sets |
|---|---|---|
| `CRONN_PORT` | `9095` | dashboard and API port, bound to `127.0.0.1` only |
| `CRONN_CONFIG_DIR` | `~/.config/cronn` | jobs file, job scripts, history database |
| `CRONN_LOG_DIR` | `~/Library/Logs` | `cronn.log` and `cronn.launchd.log` |
| `CRONN_LABEL` | `local.cronn` | launchd label and plist name |

It records the values in `$CRONN_CONFIG_DIR/cronn.env`, where the skill reads them, and a rerun or `--uninstall` reuses them unless the environment sets a value. If you move the config directory, export `CRONN_CONFIG_DIR` in your shell as well, so the agent looks in the right place. `CRONN_JOB_PATH` replaces the PATH jobs run with; the default is Homebrew's `bin` and `sbin`, `/usr/local/bin` and the system directories.

To use the job template, copy it next to your jobs and make it executable:

```sh
cp scripts/agent-session-job.sh ~/.config/cronn/jobs/ && chmod +x ~/.config/cronn/jobs/agent-session-job.sh
```

It takes its settings as variables in the job's command: `JOB_PROMPT` (required), `JOB_NAME` (`scheduled`; the session is named `<JOB_NAME>-MMDD`), `JOB_WORKSPACE` (`scheduled`), `JOB_CWD` (`$HOME`), `JOB_AGENT` (`claude`), `JOB_CONTEXT` for the title bar, `SPAWN_PATH` for the session's PATH, plus `AGTERMCTL` and `JQ` when those binaries are somewhere unusual.

## Usage

Ask the agent. A few phrasings the skill answers to: "cronn status", "schedule X every weekday at 9", "what runs next", "run the backup job now", "disable the cleanup job", "why did it fail", "show the cronn dashboard".

You can also edit `~/.config/cronn/crontab.yml` directly. cronn rereads it every 10 seconds, so nothing needs restarting:

```yaml
jobs:
  - spec: "0 3 * * *"
    command: "/opt/homebrew/bin/brew cleanup"
    name: "brew cleanup"

  - spec: "30 8 * * 1-5"
    command: "JOB_NAME=standup JOB_CWD=$HOME/src/myapp JOB_PROMPT='summarize what changed since yesterday' $HOME/.config/cronn/jobs/agent-session-job.sh"
    name: "standup summary"
```

The dashboard is at `http://127.0.0.1:9095`. Inside agterm the skill opens it with:

```sh
agtermctl session overlay open --url "http://127.0.0.1:9095/" --js --chromeless --size-percent 80 --target "$AGTERM_SESSION_ID" --follow
```

To remove the agent, keeping your jobs and history:

```sh
~/.claude/skills/cronn/scripts/install.sh --uninstall
```

## How it works

The `cronn` formula has no `service` block, so `brew services` cannot start it. The installer renders a LaunchAgent plist from `cronn.plist.tmpl` instead, because launchd expands no shell variables and every path in the plist has to be absolute when it lands. The agent runs cronn with `--update`, which rereads the jobs file every 10 seconds, `--dedup`, which skips a slot while the previous run of that job is still going, and the web dashboard on `127.0.0.1` only, so nothing off the machine can reach it and it needs no password.

`launchctl bootstrap` returning 0 means launchd accepted the job, not that cronn is serving. Any program already listening on the port answers a health check just as well, so the installer refuses up front when another process holds the port, and after bootstrap it requires three things together: the job has a live pid, that pid owns the listener, and the response carries the `App-Name: cronn` header cronn sets. Another gotcha it handles: `launchctl bootout` returns before launchd has dropped the job, and a bootstrap in that window fails with `5: Input/output error`, so a rerun waits for the old job to disappear first.

A jobs file that fails to parse does not empty the schedule. cronn logs `can't get list of jobs ... failed to parse YAML` to `cronn.log` and keeps the previous jobs running, which is easy to miss: the edit looks saved and nothing changes. The skill checks the log and the API after every edit for that reason.

cronn identifies a job by the SHA256 of its command string. Two jobs with the same command share one dashboard row whatever their schedules, and editing a command gives the job a new identity, so its history stays behind and it comes back enabled.

The dashboard's `toggle` endpoint flips a job's state rather than setting it. A retried toggle after a timeout can undo the first one, so the skill reads the state before and after and never retries blind.

A job runs under `sh -c` with the agent's PATH, and has no `AGTERM_*` variables because it is not inside a session. That is why the job template finds the window that holds its workspace before creating anything, since every `agtermctl` call otherwise lands in the frontmost window. The session it creates gets agterm's GUI PATH rather than the job's, so the template starts the agent through `/usr/bin/env PATH=...`.

`session new --command` is not shell input: libghostty splits the line into arguments itself, and a prompt carrying quotes, `$` or newlines would not survive that split as one argument. The template writes the quoted agent line into a one-shot launcher file that `/bin/sh` parses and deletes as it starts, so the session command is only `/bin/sh <launcher>`. It uses `--no-select` so a session appearing at 8:30 does not pull focus from whatever you are typing, and `--wait` so a failed start stays on screen instead of closing the tab.

## Limits

**The installer adds a LaunchAgent that starts cronn at every login and restarts it if it exits.** Rerunning the installer stops and restarts the agent, and with it any job running at that moment. `--uninstall` removes the agent, its plist and `cronn.env`; the formula, the jobs file, job scripts and history in `~/.config/cronn` stay until you delete them.

Jobs run whatever command you, or the agent on your behalf, put in the jobs file, with your user's permissions and no confirmation at run time. Read a job the agent adds before leaving it scheduled.

A job scheduled while the Mac sleeps is skipped, not caught up; it runs at its next slot.

The job template needs agterm running when it fires; otherwise it posts a failure notification and exits. Each run opens a new session, and sessions from earlier days stay until you close them. Because of `--wait`, closing one can take a key press after the agent exits. The agent's working directory must already be trusted by that agent, or the session stops on its trust prompt.

Under the **Re-run commands** restore mode, a scheduled session still open when agterm quits comes back at the next launch showing a `No such file or directory` error, because its launcher deleted itself on the first run. Close these sessions once you have read them.

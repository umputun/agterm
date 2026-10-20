#!/usr/bin/env bash
# installs cronn from Homebrew and runs it as a per-user launchd agent with its web dashboard on
# loopback. rerunning refreshes the agent; --dry-run prints what it would do, --uninstall removes it.
set -euo pipefail

CRONN_CONFIG_DIR="${CRONN_CONFIG_DIR:-$HOME/.config/cronn}"
env_file="$CRONN_CONFIG_DIR/cronn.env"

# a value recorded by an earlier install outranks the default, so a rerun or --uninstall acts on
# that agent; the environment outranks both. parsed, never sourced, so the file runs no code
recorded() {
    [ -f "$env_file" ] || return 0
    sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$env_file" | tail -1
}
CRONN_PORT="${CRONN_PORT:-$(recorded CRONN_PORT)}"
CRONN_LOG_DIR="${CRONN_LOG_DIR:-$(recorded CRONN_LOG_DIR)}"
CRONN_LABEL="${CRONN_LABEL:-$(recorded CRONN_LABEL)}"
CRONN_PORT="${CRONN_PORT:-9095}"
CRONN_LOG_DIR="${CRONN_LOG_DIR:-$HOME/Library/Logs}"
CRONN_LABEL="${CRONN_LABEL:-local.cronn}"
FORMULA="umputun/apps/cronn"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/cronn.plist.tmpl"
plist="$HOME/Library/LaunchAgents/$CRONN_LABEL.plist"
domain="gui/$(id -u)"

die() { echo "cronn install: $*" >&2; exit 1; }

usage() {
    echo "usage: install.sh [--dry-run | --uninstall]"
    echo "env: CRONN_PORT=$CRONN_PORT CRONN_CONFIG_DIR=$CRONN_CONFIG_DIR CRONN_LOG_DIR=$CRONN_LOG_DIR CRONN_LABEL=$CRONN_LABEL"
}

agent_pid() { launchctl print "$domain/$CRONN_LABEL" 2>/dev/null | awk '/^\tpid = /{print $3; exit}'; }
port_owner() { lsof -nP -iTCP:"$CRONN_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1; }

# bootout returns before launchd has removed the job, and a bootstrap inside that window fails
# with "5: Input/output error", leaving the agent unloaded
bootout_and_wait() {
    launchctl bootout "$domain/$CRONN_LABEL" 2>/dev/null || true
    for _ in $(seq 1 20); do
        launchctl print "$domain/$CRONN_LABEL" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    die "launchd still holds $CRONN_LABEL after bootout"
}

render_plist() {
    local cronn_bin="$1" job_path="$2"
    sed -e "s|@@LABEL@@|$CRONN_LABEL|g" \
        -e "s|@@CRONN_BIN@@|$cronn_bin|g" \
        -e "s|@@CONFIG_DIR@@|$CRONN_CONFIG_DIR|g" \
        -e "s|@@LOG_DIR@@|$CRONN_LOG_DIR|g" \
        -e "s|@@HOME@@|$HOME|g" \
        -e "s|@@PORT@@|$CRONN_PORT|g" \
        -e "s|@@JOB_PATH@@|$job_path|g" \
        "$template"
}

uninstall() {
    bootout_and_wait
    rm -f "$plist" "$env_file"
    echo "removed the $CRONN_LABEL agent, $plist and $env_file"
    echo "kept $CRONN_CONFIG_DIR (jobs, history) and the $FORMULA formula; remove them by hand if unwanted"
}

mode="${1:-install}"
case "$mode" in
    install | --dry-run) ;;
    --uninstall) uninstall; exit 0 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[ -f "$template" ] || die "missing $template; install.sh and cronn.plist.tmpl must sit in one directory"
brew_bin="$(command -v brew)" || die "Homebrew not found, install it from https://brew.sh first"
brew_prefix="$("$brew_bin" --prefix)"
# /usr/local/bin is where agterm's Install Command Line Tool puts agtermctl
job_path="${CRONN_JOB_PATH:-$brew_prefix/bin:$brew_prefix/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
# the opt path survives upgrades and cannot be shadowed by another cronn earlier on PATH
cronn_bin="$brew_prefix/opt/cronn/bin/cronn"

# a listener we do not own would answer every health check below just as well as cronn
owner="$(port_owner || true)"
ours="$(agent_pid || true)"
if [ -n "$owner" ] && [ "$owner" != "$ours" ]; then
    what="$(ps -p "$owner" -o comm= 2>/dev/null || echo unknown)"
    die "port $CRONN_PORT is already served by pid $owner ($what), not by $CRONN_LABEL; set CRONN_PORT to a free port, or remove that other service first"
fi

if [ "$mode" = "--dry-run" ]; then
    if [ -x "$cronn_bin" ]; then echo "cronn: installed at $cronn_bin"; else echo "cronn: would run brew install $FORMULA"; fi
    if [ -f "$CRONN_CONFIG_DIR/crontab.yml" ]; then
        echo "jobs file: $CRONN_CONFIG_DIR/crontab.yml exists, left as is"
    else
        echo "jobs file: would create $CRONN_CONFIG_DIR/crontab.yml with no jobs"
    fi
    echo "agent: would write $plist and load it into $domain, rendered as:"
    render_plist "$cronn_bin" "$job_path"
    exit 0
fi

if ! "$brew_bin" list --formula cronn >/dev/null 2>&1; then
    echo "installing cronn..."
    "$brew_bin" install "$FORMULA" ||
        die "brew install $FORMULA failed; if Homebrew refused the tap, run: brew trust umputun/apps"
fi
[ -x "$cronn_bin" ] || die "cronn binary not found at $cronn_bin"

mkdir -p "$CRONN_CONFIG_DIR/jobs" "$CRONN_LOG_DIR" "$(dirname "$plist")"
if [ ! -f "$CRONN_CONFIG_DIR/crontab.yml" ]; then
    cat > "$CRONN_CONFIG_DIR/crontab.yml" <<'YAML'
# cronn rereads this file every 10s, so an edit needs no restart. a file that fails to parse
# leaves the previous schedule running and logs "can't get list of jobs" to cronn.log.
# commands run under sh -c with the agent's PATH, never a login shell: spell binaries absolutely.
#
#   - spec: "0 9 * * 1-5"
#     command: "/opt/homebrew/bin/brew update"
#     name: "brew update"
jobs: []
YAML
fi

cat > "$env_file" <<ENV
CRONN_PORT="$CRONN_PORT"
CRONN_CONFIG_DIR="$CRONN_CONFIG_DIR"
CRONN_LOG_DIR="$CRONN_LOG_DIR"
CRONN_LABEL="$CRONN_LABEL"
ENV

render_plist "$cronn_bin" "$job_path" > "$plist"
plutil -lint "$plist" >/dev/null || die "rendered plist is invalid: $plist"
if grep -q '@@' "$plist"; then die "unrendered placeholder left in $plist"; fi

bootout_and_wait
launchctl bootstrap "$domain" "$plist" || die "launchctl bootstrap failed, see $CRONN_LOG_DIR/cronn.launchd.log"

# bootstrap returning 0 only means launchd accepted the job. success needs the job to have a live
# pid, that pid to own the listener, and the listener to name itself cronn in its App-Name header
for _ in $(seq 1 20); do
    pid="$(agent_pid || true)"
    if [ -n "$pid" ] && [ "$(port_owner || true)" = "$pid" ]; then
        headers="$(curl -fsSI --max-time 2 "http://127.0.0.1:$CRONN_PORT/api/v1/status" 2>/dev/null || true)"
        if printf '%s' "$headers" | grep -qi '^App-Name: *cronn'; then
            version="$(printf '%s' "$headers" | awk 'tolower($1)=="app-version:"{print $2}' | tr -d '\r')"
            echo "cronn ${version:-unknown} (pid $pid) serving on http://127.0.0.1:$CRONN_PORT"
            echo "jobs file: $CRONN_CONFIG_DIR/crontab.yml"
            exit 0
        fi
    fi
    sleep 1
done

echo "--- last 20 lines of $CRONN_LOG_DIR/cronn.launchd.log ---" >&2
tail -20 "$CRONN_LOG_DIR/cronn.launchd.log" >&2 2>/dev/null || echo "(no launchd log)" >&2
die "the agent did not come up as cronn on port $CRONN_PORT within 20s"

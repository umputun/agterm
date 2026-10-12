// agterm-opencode-status-plugin
//
// OpenCode lifecycle plugin installed by agterm's Help ▸ Install Agent Status Hooks… command.
// Reports agent status through the installed agterm wrapper; a clean no-op outside agterm.
//
// IMPORTANT: this module must export ONLY plugin function(s). OpenCode's legacy loader treats
// every export as a plugin and throws "Plugin export is not a function" on non-functions.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const ACTIVE = ["active", "--blink"];
const BLOCKED = ["blocked"];
const COMPLETED = ["completed", "--auto-reset"];

/**
 * Interrupts, never a failed turn: Esc routes through halt(DOMException AbortError), which is parsed
 * to MessageAbortedError — either name may surface. Reported as nothing, so the turn ends on the
 * following idle's completed --auto-reset, which self-clears on visit.
 */
const ABORT_ERROR_NAMES = new Set(["MessageAbortedError", "AbortError"]);

/**
 * Context overflow is ambiguous at error time: with auto-compaction on, the loop resumes and the next
 * event is busy; with compaction off (or once it gives up) the turn really ends and the next event is
 * idle. Decided on that following event instead of by name — see the `overflow` Set below.
 */
const OVERFLOW_ERROR_NAME = "ContextOverflowError";

function defaultWrapperPath() {
  return join(homedir(), ".config", "agterm", "agent-status", "agterm-agent-status.sh");
}

function errorName(error) {
  return typeof error?.name === "string" ? error.name : undefined;
}

/**
 * Serialize reports so a slow spawn cannot reorder status.
 * Status reporting is advisory and must never reject into OpenCode's Effect fiber.
 */
function createReportQueue(reportFn) {
  let chain = Promise.resolve();
  return function enqueue(args) {
    if (!args || args.length === 0) return Promise.resolve();
    const pending = chain.then(() => reportFn(args));
    chain = pending.catch(() => {});
    // Swallow rejection on the returned promise too — event may run under Effect.promise.
    return pending.catch(() => {});
  };
}

function spawnReport(wrapper, args) {
  // Bound wait with real process-group cancellation (detached + kill(-pid)), not the old 1s
  // abandonment that reordered reports under load while leaving agtermctl running.
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const child = spawn(wrapper, args, {
      stdio: "ignore",
      env: process.env,
      detached: true,
    });
    child.on("error", finish);
    child.on("close", finish);
    const timer = setTimeout(() => {
      try {
        if (child.pid != null) process.kill(-child.pid, "SIGTERM");
      } catch {
        /* already gone */
      }
      finish();
    }, 10_000);
  });
}

/**
 * OpenCode plugin entry. Named export — OpenCode loads plugins from ~/.config/opencode/plugins/.
 * This must remain the only export from this file.
 *
 * Every session of one OpenCode instance reports into the SAME agterm pane, so the three Sets below
 * track them together rather than per-session:
 * - `active`: sessionIDs that have seen busy/retry. Idle for one id is ignored until that id was
 *   busy; COMPLETED fires only when the set is empty after removing the id, so a task subagent's
 *   busy/idle pair cannot paint completed onto a still-busy parent (or another top-level session).
 * - `errored`: sessionIDs that hit a turn-ending session.error. Their own following idle (the one
 *   SessionProcessor.halt publishes right after) is swallowed and the id stays latched, so a SIBLING
 *   idling later cannot report completed over the blocked either. Cleared on the next busy/retry, or
 *   set-wide once everything is idle.
 * - `overflow`: sessionIDs that hit ContextOverflowError, whose meaning is only known from the next
 *   event — busy means auto-compaction resumed (no blocked), idle means the turn ended (blocked).
 * Abort/interrupt is never latched, so Esc ends on completed --auto-reset, which self-clears.
 */
export const AgtermStatusPlugin = async () => {
  if (!process.env.AGTERM_SESSION_ID) {
    return {};
  }

  const wrapper = process.env.AGTERM_STATUS_WRAPPER || defaultWrapperPath();
  const enqueue = createReportQueue((args) => spawnReport(wrapper, args));
  const active = new Set();
  const errored = new Set();
  const overflow = new Set();
  // request id → sessionID of prompts still waiting for an answer
  const pending = new Map();

  function mapEventToArgs(event) {
    const type = event?.type;
    const properties = event?.properties ?? {};
    const sessionID =
      typeof properties.sessionID === "string" && properties.sessionID
        ? properties.sessionID
        : undefined;

    switch (type) {
      case "session.status": {
        const kind =
          typeof properties.status === "string" ? properties.status : properties.status?.type;
        if (typeof kind !== "string") return null;
        switch (kind.toLowerCase()) {
          case "busy":
          case "retry":
            if (sessionID) {
              active.add(sessionID);
              errored.delete(sessionID);
              // Work resumed, so the earlier overflow was auto-compaction, not a failed turn.
              overflow.delete(sessionID);
            }
            return ACTIVE;
          case "idle":
            // an interrupted turn drops its prompts without a reply event, so idle is what clears them
            for (const [id, owner] of pending) {
              if (owner === sessionID) pending.delete(id);
            }
            if (!sessionID || !active.has(sessionID)) return null;
            active.delete(sessionID);
            if (overflow.has(sessionID)) {
              // Overflow with no resuming busy: the turn ended on it. Latch like any turn-ending error
              // so a sibling's idle cannot report completed over this blocked.
              overflow.delete(sessionID);
              errored.add(sessionID);
              return BLOCKED;
            }
            // Swallow the idle halt publishes right after the error, but KEEP the id latched: COMPLETED
            // is decided set-wide below, so a sibling idling later must still see that a turn failed.
            if (errored.has(sessionID)) return null;
            // Set-wide gate: another session (parent or sibling) still busy → stay active.
            if (active.size > 0) return null;
            // Everything idle, but some session ended in failure — leave its blocked standing.
            if (errored.size > 0) {
              errored.clear();
              return null;
            }
            return COMPLETED;
          default:
            return null;
        }
      }
      case "permission.asked":
      case "question.asked":
        if (typeof properties.id === "string") pending.set(properties.id, sessionID);
        return BLOCKED;
      case "session.error": {
        // Only for a session already reported busy (sessionID is optional on some publishers).
        if (!sessionID || !active.has(sessionID)) return null;
        const name = errorName(properties.error);
        if (name && ABORT_ERROR_NAMES.has(name)) return null;
        if (name === OVERFLOW_ERROR_NAME) {
          // Report nothing yet — the following busy (compaction resumed) or idle (turn ended) decides.
          overflow.add(sessionID);
          return null;
        }
        errored.add(sessionID);
        return BLOCKED;
      }
      // Clear blocked after the user answers; session.status(busy) may lag behind the reply.
      case "permission.replied":
      case "question.replied":
      case "question.rejected":
        pending.delete(properties.requestID);
        // tool calls run in parallel, so another prompt can still be waiting. Blocked is re-reported
        // because the keystroke that answered this one has already cleared the pane's status.
        return pending.size > 0 ? BLOCKED : ACTIVE;
      // deprecated: OpenCode also emits session.status(type=idle); handling both would double-fire completed
      case "session.idle":
        return null;
      default:
        return null;
    }
  }

  return {
    event: async ({ event }) => {
      const args = mapEventToArgs(event);
      if (args) await enqueue(args);
    },
  };
};

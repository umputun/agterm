// agterm-opencode-status-plugin
//
// OpenCode lifecycle plugin installed by agterm's Help ▸ Install Agent Status Hooks… command.
// Reports agent status through the installed agterm wrapper; a clean no-op outside agterm.
//
// Dual entrypoint, one pane, one state machine per loaded instance:
// - OpenCode v2 calls default.setup(ctx): events come from ctx.event.subscribe(). The public v2
//   stream never carries session.status, so the turn lifecycle is tracked from
//   session.execution.started / step.started (busy), session.execution.succeeded (turn ended OK),
//   session.execution.failed (turn ended in failure, error.type e.g. "provider.auth",
//   "context-overflow"), and session.execution.interrupted (Esc / shutdown / superseded / idle
//   timeout — an interrupt, never a failed turn). Questions arrive as form.created/replied/
//   cancelled. A failure report is debounced briefly because a retry
//   (session.retry.scheduled) or an auto-compaction resume can follow the same failed event;
//   any further activity for that session cancels the blocked report.
// - OpenCode v1 (>= 1.18.29) calls default.server(): the legacy bus DID carry session.status
//   busy/retry/idle, question.* events, and session.error with error.name
//   (AbortError/MessageAbortedError = interrupt, ContextOverflowError = ambiguous overflow).
//   That mapping is kept verbatim for the v1 path.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const ACTIVE = ["active", "--blink"];
const BLOCKED = ["blocked"];
const COMPLETED = ["completed", "--auto-reset"];

/**
 * v1 only: interrupts surface as session.error with these names (Esc routes through
 * halt(DOMException AbortError), parsed to MessageAbortedError — either name may surface).
 * Reported as nothing, so the turn ends on the following idle's completed --auto-reset, which
 * self-clears on visit. In v2 interrupts are their own session.execution.interrupted event.
 */
const ABORT_ERROR_NAMES = new Set(["MessageAbortedError", "AbortError"]);

/**
 * v1 only: context overflow is ambiguous at error time — with auto-compaction on, the loop
 * resumes and the next event is busy; with compaction off (or once it gives up) the turn really
 * ends and the next event is idle. Decided on that following event via the `overflow` Set.
 * In v2 the same ambiguity is absorbed by the failure debounce: a resuming step cancels the
 * pending blocked report, whatever the error type.
 */
const OVERFLOW_ERROR_NAMES = new Set(["ContextOverflowError"]);
const OVERFLOW_ERROR_TYPES = new Set(["context-overflow", "payload-too-large"]);

/** How long a session.execution.failed waits for a retry/compaction resume before reporting blocked. */
const FAILURE_DEBOUNCE_MS = Number(process.env.AGTERM_STATUS_FAILURE_DEBOUNCE_MS ?? 800) || 0;

function defaultWrapperPath() {
  return join(homedir(), ".config", "agterm", "agent-status", "agterm-agent-status.sh");
}

function errorName(error) {
  return typeof error?.name === "string" ? error.name : undefined;
}

function errorType(error) {
  return typeof error?.type === "string" ? error.type : undefined;
}

function isOverflowError(error) {
  const type = errorType(error);
  if (type !== undefined && OVERFLOW_ERROR_TYPES.has(type)) return true;
  const name = errorName(error);
  if (name !== undefined && OVERFLOW_ERROR_NAMES.has(name)) return true;
  // Belt and braces: providers phrase it in the message when the type is only
  // provider.invalid-request.
  return typeof error?.message === "string" && /context overflow/i.test(error.message);
}

function isAbortError(error) {
  const name = errorName(error);
  return name !== undefined && ABORT_ERROR_NAMES.has(name);
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
 * One reporter per loaded plugin instance. Every session of one OpenCode instance reports into the
 * SAME agterm pane, so the Sets below track them together rather than per-session:
 * - `active`: sessionIDs with a running turn. COMPLETED fires only when the set is empty after
 *   the turn ends, so a task subagent's busy/idle pair cannot paint completed onto a still-busy
 *   parent (or another top-level session).
 * - `errored`: sessionIDs whose turn ended in failure. Latched immediately so a SIBLING finishing
 *   later cannot report completed over the blocked; cleared on that session's next busy, or
 *   set-wide once everything is idle.
 * - `overflow` (v1 only): sessionIDs that hit ContextOverflowError, whose meaning is only known
 *   from the next event — busy means auto-compaction resumed (no blocked), idle means the turn
 *   ended (blocked).
 * Interrupts (v2 session.execution.interrupted, v1 abort-named session.error) are never latched,
 * so Esc ends on completed --auto-reset, which self-clears on visit.
 * `pendingBlocked` (v2 only): debounced blocked reports, canceled when the session resumes.
 */
function createReporter() {
  const wrapper = process.env.AGTERM_STATUS_WRAPPER || defaultWrapperPath();
  const enqueue = createReportQueue((args) => spawnReport(wrapper, args));
  const active = new Set();
  const errored = new Set();
  const overflow = new Set();
  const pendingBlocked = new Map();

  function cancelPendingBlocked(sessionID) {
    const entry = pendingBlocked.get(sessionID);
    if (entry === undefined) return false;
    clearTimeout(entry.timer);
    pendingBlocked.delete(sessionID);
    entry.settled();
    return true;
  }

  /**
   * Fire-and-forget failure debounce: BLOCKED is enqueued only if no further activity for the
   * session arrives within FAILURE_DEBOUNCE_MS. `settled` lets drain/cancel await the outcome.
   */
  function scheduleBlocked(sessionID) {
    let settled;
    const done = new Promise((resolve) => {
      settled = resolve;
    });
    const entry = {
      timer: setTimeout(() => {
        pendingBlocked.delete(sessionID);
        enqueue(BLOCKED).then(settled, settled);
      }, FAILURE_DEBOUNCE_MS),
      settled: () => settled(),
    };
    pendingBlocked.set(sessionID, entry);
    return done;
  }

  /** Flush armed debounces on unload instead of dropping them: the turn really did fail. */
  function drainPendingBlocked() {
    const entries = [...pendingBlocked.values()];
    pendingBlocked.clear();
    return Promise.all(
      entries.map((entry) => {
        clearTimeout(entry.timer);
        entry.settled();
        return enqueue(BLOCKED);
      }),
    );
  }

  /** v2: any sign of life ends the failure debounce and reasserts busy. */
  function noteBusy(sessionID) {
    const resumed = cancelPendingBlocked(sessionID);
    if (!sessionID) return null;
    const wasIdle = !active.has(sessionID);
    active.add(sessionID);
    errored.delete(sessionID);
    overflow.delete(sessionID);
    // A canceled debounce means the pane never left active — no report needed.
    if (resumed) return null;
    // Report only on the idle→busy transition — per-step noise must not spawn a report.
    return wasIdle ? ACTIVE : null;
  }

  /** Set-wide COMPLETED decision shared by every turn-ended-ok path. */
  function noteTurnEnded(sessionID) {
    if (!sessionID || !active.has(sessionID)) return null;
    active.delete(sessionID);
    // Another session (parent or sibling) still busy → stay active.
    if (active.size > 0) return null;
    // Everything idle, but some session ended in failure — leave its blocked standing.
    if (errored.size > 0) {
      errored.clear();
      return null;
    }
    return COMPLETED;
  }

  function mapV2EventToArgs(event) {
    const type = event?.type;
    const data = event?.data ?? {};
    const sessionID =
      typeof data.sessionID === "string" && data.sessionID ? data.sessionID : undefined;

    switch (type) {
      case "session.execution.started":
        return noteBusy(sessionID);
      // A running turn emits steps constantly; also covers attaching mid-turn (a plugin reload
      // between execution.started and the turn's end would otherwise never paint active).
      case "session.step.started":
      case "session.retry.scheduled":
        return noteBusy(sessionID);
      case "session.execution.succeeded":
        return noteTurnEnded(sessionID);
      case "session.execution.interrupted":
        // Esc / shutdown / superseded / inactivity: an interrupt, never a failed turn. The turn
        // DID end, so the pane moves to completed --auto-reset, which self-clears on visit.
        return noteTurnEnded(sessionID);
      case "session.execution.failed": {
        // Only for a session that had reported busy.
        if (!sessionID || !active.has(sessionID)) return null;
        active.delete(sessionID);
        errored.add(sessionID);
        // Debounced, fire-and-forget: a retry or an auto-compaction resume may follow this same
        // event, and any further activity for the session cancels the blocked report.
        scheduleBlocked(sessionID);
        return null;
      }
      case "permission.asked":
      case "form.created":
        return BLOCKED;
      // Clear blocked after the user answers; the resumed turn reasserts active on its own.
      case "permission.replied":
      case "form.replied":
      case "form.cancelled":
        return ACTIVE;
      // deprecated: also not on the public v2 stream; session.status(idle) semantics are carried
      // by execution.succeeded/interrupted/failed above.
      case "session.idle":
      case "session.status":
      default:
        return null;
    }
  }

  function mapV1EventToArgs(event) {
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
            if (!sessionID || !active.has(sessionID)) return null;
            active.delete(sessionID);
            if (overflow.has(sessionID)) {
              // Overflow with no resuming busy: the turn ended on it. Latch like any turn-ending
              // error so a sibling's idle cannot report completed over this blocked.
              overflow.delete(sessionID);
              errored.add(sessionID);
              return BLOCKED;
            }
            // Swallow the idle halt publishes right after the error, but KEEP the id latched:
            // COMPLETED is decided set-wide below, so a sibling idling later must still see that
            // a turn failed.
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
        return BLOCKED;
      case "session.error": {
        // Only for a session already reported busy (sessionID is optional on some publishers).
        if (!sessionID || !active.has(sessionID)) return null;
        const error = properties.error;
        if (isAbortError(error)) return null;
        if (isOverflowError(error)) {
          // Report nothing yet — the following busy (compaction resumed) or idle (turn ended)
          // decides.
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
        return ACTIVE;
      // deprecated: OpenCode also emits session.status(type=idle); handling both would
      // double-fire completed
      case "session.idle":
        return null;
      default:
        return null;
    }
  }

  return {
    async handleEvent(event, legacy) {
      const args = legacy ? mapV1EventToArgs(event) : mapV2EventToArgs(event);
      if (args) await enqueue(args);
    },
    async drain() {
      await drainPendingBlocked();
    },
  };
}

export default {
  id: "agterm-status",

  /**
   * OpenCode v2 entrypoint. Subscribes to the server event stream; the returned cleanup aborts
   * the subscription and resolves once the pump drained and debounced reports settled.
   */
  setup(ctx) {
    if (!process.env.AGTERM_SESSION_ID) return;
    if (typeof ctx?.event?.subscribe !== "function") return;
    const reporter = createReporter();
    const controller = new AbortController();
    const pump = (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          await reporter.handleEvent(event, false);
        }
      } catch {
        /* stream ended or aborted — status reporting is advisory, never reject into OpenCode */
      }
    })();
    return () => {
      controller.abort();
      return Promise.all([pump, reporter.drain()]);
    };
  },

  /**
   * OpenCode v1 (>= 1.18.29) entrypoint. Returns the legacy hooks object; the same reporter and
   * pane semantics drive it, fed v1 bus payloads.
   */
  async server() {
    if (!process.env.AGTERM_SESSION_ID) {
      return {};
    }
    const reporter = createReporter();
    return {
      event: async ({ event }) => {
        await reporter.handleEvent(event, true);
      },
    };
  },
};

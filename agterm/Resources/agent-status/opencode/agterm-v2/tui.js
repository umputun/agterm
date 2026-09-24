// agterm-opencode-v2-status-plugin
//
// OpenCode v2 CLI plugin installed by agterm's Help ▸ Install Agent Status Hooks… command.
// Reports agent status through the installed agterm wrapper; a clean no-op outside agterm.
//
// Runs in the terminal client, not the shared server: only the client has this pane's AGTERM_* env.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const ACTIVE = ["active", "--blink"];
const BLOCKED = ["blocked"];
const COMPLETED = ["completed", "--auto-reset"];
const IDLE = ["idle"];

function defaultWrapperPath() {
  return join(homedir(), ".config", "agterm", "agent-status", "agterm-agent-status.sh");
}

/** Serialize reports so a slow spawn cannot reorder status; failures must never reject into OpenCode. */
function createReportQueue(reportFn) {
  let chain = Promise.resolve();
  return function enqueue(args, generation) {
    if (!args || args.length === 0) return Promise.resolve();
    const pending = chain.then(() => reportFn(args, generation));
    chain = pending.catch(() => {});
    return pending.catch(() => {});
  };
}

function spawnReport(wrapper, args, env) {
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
      env,
      detached: true,
    });
    child.on("error", finish);
    child.on("close", finish);
    // Wait for the killed reporter to close before sending a newer status to the same pane.
    const timer = setTimeout(() => {
      try {
        if (child.pid != null) process.kill(-child.pid, "SIGKILL");
      } catch {
        /* already gone */
      }
    }, 10_000);
  });
}

function sessionState(info) {
  return {
    parentID: info.parentID,
    running: false,
    completed: info.outcome === "succeeded" || info.outcome === "interrupted",
    failed: info.outcome === "failed",
    idleAt: info.time?.idle,
    permissions: new Set(),
    forms: new Set(),
  };
}

function applyEvent(states, event) {
  const data = event.data ?? {};
  if (event.type === "session.created" && states.has(data.parentID)) {
    states.set(data.sessionID, sessionState(data));
  }
  const state = states.get(data.sessionID ?? data.form?.sessionID);
  if (!state) return;
  switch (event.type) {
    case "session.deleted": {
      const removed = new Set([data.sessionID]);
      for (const id of removed) {
        for (const [childID, child] of states) {
          if (child.parentID === id) removed.add(childID);
        }
        states.delete(id);
      }
      break;
    }
    case "session.execution.started":
      if (![...states.values()].some(item => item.running)) {
        for (const item of states.values()) {
          item.failed = false;
          item.completed = false;
        }
      }
      state.running = true;
      state.failed = false;
      state.completed = false;
      break;
    case "session.execution.failed":
    case "session.execution.succeeded":
    case "session.execution.interrupted":
      // Step failures can recover through retry/compaction; only execution boundaries settle a turn.
      if (event.type === "session.execution.failed" && !state.running) return;
      state.failed = event.type === "session.execution.failed";
      state.completed = !state.failed;
      if (event.type === "session.execution.interrupted" && ["shutdown", "superseded"].includes(data.reason)) {
        for (const item of states.values()) item.completed = false;
      }
      state.running = false;
      state.permissions.clear();
      state.forms.clear();
      break;
    case "permission.asked":
      state.permissions.add(data.id);
      break;
    case "permission.replied":
      state.permissions.delete(data.requestID);
      break;
    case "form.created":
      state.forms.add(data.form.id);
      break;
    case "form.replied":
    case "form.cancelled":
      state.forms.delete(data.id);
      break;
  }
}

function aggregate(states) {
  const values = [...states.values()];
  if (values.some(item => item.failed || item.permissions.size || item.forms.size)) return BLOCKED;
  if (values.some(item => item.running)) return ACTIVE;
  return values.some(item => item.completed) ? COMPLETED : IDLE;
}

// Walk descendants explicitly: data.session.family() also includes the selected session's ancestors.
async function loadFamily(client, sessionID, states, active, signal) {
  if (states.has(sessionID)) return;
  const [info, permissions, forms] = await Promise.all([
    client.session.get({ sessionID }, { signal }),
    client.permission.list({ sessionID }, { signal }),
    client.session.form.list({ sessionID }, { signal }),
  ]);
  const state = sessionState(info);
  state.running = Object.hasOwn(active, sessionID);
  if (state.running) {
    state.failed = false;
    state.completed = false;
  }
  state.permissions = new Set(permissions.map(item => item.id));
  state.forms = new Set(forms.map(item => item.id));
  states.set(sessionID, state);
  let cursor;
  do {
    const page = await client.session.list({ parentID: sessionID, cursor }, { signal });
    for (const child of page.data) await loadFamily(client, child.id, states, active, signal);
    cursor = page.cursor?.next;
  } while (cursor);
}

const EVENTS = new Set([
  "session.created", "session.deleted", "session.execution.started", "session.execution.succeeded",
  "session.execution.failed", "session.execution.interrupted", "permission.asked", "permission.replied",
  "form.created", "form.replied", "form.cancelled",
]);

/**
 * OpenCode v2 auto-discovers this TUI-only directory; v1's file loader ignores it.
 * Plugin.define is an identity function, so the plain definition needs no runtime SDK import.
 *
 * `states` covers the selected session and descendants, not every session on the shared server.
 * Pending requests and terminal failures hold BLOCKED across sibling completion; only a settled
 * family completes. Step errors may recover through retry/compaction and never settle a turn here.
 * Selection/reconnect replaces the snapshot, then replays events received during that read.
 * `generation` keeps queued reports from a previous selection or plugin lifetime off this pane.
 */
export default {
  id: "agterm.status",
  setup(ctx) {
    if (!process.env.AGTERM_SESSION_ID) {
      return;
    }
    const env = { ...process.env };
    const wrapper = env.AGTERM_STATUS_WRAPPER || defaultWrapperPath();
    let states = new Map();
    let selected;
    let generation = 0;
    let disposed = false;
    let hydration;
    let retryAt = 0;
    const enqueue = createReportQueue((args, version) => {
      if (version === generation) return spawnReport(wrapper, args, env);
    });
    let pendingReport = Promise.resolve();
    let last;

    const publish = (args = aggregate(states)) => {
      if (args === last) return;
      last = args;
      pendingReport = enqueue(args, generation);
    };

    function refresh() {
      hydration?.controller.abort();
      generation++;
      states = new Map();
      retryAt = 0;
      last = undefined;
      publish(IDLE);
      if (!selected) {
        hydration = undefined;
        return;
      }
      const pending = { controller: new AbortController(), events: [] };
      hydration = pending;
      const target = selected;
      const timer = setTimeout(() => pending.controller.abort(), 10_000);
      pending.controller.signal.addEventListener("abort", () => clearTimeout(timer), { once: true });
      void (async () => {
        const snapshot = new Map();
        try {
          const active = await ctx.client.session.active({ signal: pending.controller.signal });
          await loadFamily(ctx.client, target, snapshot, active, pending.controller.signal);
          if (disposed || hydration !== pending) return;
          const root = snapshot.get(target);
          if (root?.running) {
            // A previous turn's failed child must not block an already-running new parent turn.
            for (const item of snapshot.values()) {
              if (item.idleAt <= root.idleAt) item.failed = false;
            }
          }
          for (const event of pending.events) applyEvent(snapshot, event);
          states = snapshot;
        } catch {
          if (disposed || hydration !== pending) return;
          retryAt = Date.now() + 5_000;
        } finally {
          clearTimeout(timer);
        }
        hydration = undefined;
        publish();
      })();
    }

    function checkRoute() {
      if (disposed) return;
      const route = ctx.ui.router.current();
      const id = route.type === "session" ? route.sessionID : null;
      if (id !== selected) {
        selected = id;
        refresh();
      } else if (retryAt && Date.now() >= retryAt) {
        refresh();
      }
    }

    const stop = ctx.data.listen(({ details: event }) => {
      if (disposed) return;
      checkRoute();
      if (event.type === "server.connected") {
        refresh();
        return;
      }
      if (!EVENTS.has(event.type)) return;
      if (hydration) {
        hydration.events.push(event);
        return;
      }
      applyEvent(states, event);
      publish();
    });
    // The public router has no subscription. Only inspect local selection here; no polling RPC or process.
    const timer = setInterval(checkRoute, 250);
    checkRoute();
    return async () => {
      disposed = true;
      stop();
      clearInterval(timer);
      hydration?.controller.abort();
      generation++;
      last = undefined;
      publish(IDLE);
      await pendingReport;
    };
  },
};

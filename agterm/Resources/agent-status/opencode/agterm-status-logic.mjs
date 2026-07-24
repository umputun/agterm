// Shared pure helpers for the OpenCode status plugin. Not an OpenCode plugin entry —
// OpenCode only auto-loads `*.{js,ts}` from plugins/; this `.mjs` is imported by agterm-status.js.
// Installed beside the plugin so the relative import resolves under ~/.config/opencode/plugins/.

/** Child-session events that project onto the parent pane status (herdr whitelist). */
export const CHILD_EVENT_ARGS = new Map([
  ["permission.asked", ["blocked"]],
  ["question.asked", ["blocked"]],
  ["permission.replied", ["active", "--blink"]],
  ["question.replied", ["active", "--blink"]],
  ["question.rejected", ["active", "--blink"]],
]);

const ACTIVE = ["active", "--blink"];
const BLOCKED = ["blocked"];
const COMPLETED = ["completed", "--auto-reset"];

/**
 * Map OpenCode `session.status` payload to agtermctl args.
 * Only idle|busy|retry are recognized; anything else is a no-op.
 * @param {unknown} status
 * @returns {string[] | null}
 */
export function statusArgsFromSessionStatus(status) {
  const kind = typeof status === "string" ? status : status?.type;
  if (typeof kind !== "string") return null;
  switch (kind.toLowerCase()) {
    case "busy":
    case "retry":
      return ACTIVE;
    case "idle":
      return COMPLETED;
    default:
      return null;
  }
}

function sessionIDFromProperties(properties) {
  return typeof properties?.sessionID === "string" && properties.sessionID
    ? properties.sessionID
    : undefined;
}

/**
 * Pure event → status args mapper.
 * @param {{ type?: string, properties?: Record<string, unknown> }} event
 * @param {{ childSessions: Set<string> }} ctx
 * @returns {string[] | null}
 */
export function mapEventToArgs(event, ctx) {
  const type = event?.type;
  const properties = event?.properties ?? {};
  const sessionID = sessionIDFromProperties(properties);

  const info = properties.info;
  if (info && typeof info === "object" && info.id && info.parentID) {
    ctx.childSessions.add(String(info.id));
  }

  if (sessionID && ctx.childSessions.has(sessionID)) {
    return CHILD_EVENT_ARGS.get(type) ?? null;
  }

  switch (type) {
    case "session.status":
      return statusArgsFromSessionStatus(properties.status);
    case "tool.execute.before":
    case "tool.execute.after":
    case "permission.replied":
    case "question.replied":
    case "question.rejected":
    case "session.compacted":
      return ACTIVE;
    case "permission.asked":
    case "question.asked":
    case "session.error":
      return BLOCKED;
    // deprecated: OpenCode also emits session.status(type=idle); handling both would double-fire completed
    case "session.idle":
      return null;
    case "session.created":
    case "session.updated":
    case "session.deleted":
      return null;
    default:
      return null;
  }
}

/**
 * Root-session chat.message → active; child sessions ignored.
 * @param {string | undefined} sessionID
 * @param {Set<string>} childSessions
 * @returns {string[] | null}
 */
export function mapChatMessageToArgs(sessionID, childSessions) {
  if (sessionID && childSessions.has(sessionID)) return null;
  return ACTIVE;
}

/**
 * Sequential report queue (herdr requestChain). Inject `reportFn` in tests.
 * @param {(args: string[]) => Promise<void>} reportFn
 */
export function createReportQueue(reportFn) {
  let chain = Promise.resolve();
  return function enqueue(args) {
    if (!args || args.length === 0) return Promise.resolve();
    const pending = chain.then(() => reportFn(args));
    chain = pending.catch(() => {});
    return pending;
  };
}

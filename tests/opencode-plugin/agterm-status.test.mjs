import assert from "node:assert/strict";
import { describe, it } from "node:test";
// Reaches into the bundled plugin resources (kept OUT of the app bundle so the test never ships).
// The adjacent opencode/package.json marks that dir as ESM, so node loads the `.js` as a module.
import * as pluginModule from "../../agterm/Resources/agent-status/opencode/agterm-status.js";
import {
  CHILD_EVENT_ARGS,
  createReportQueue,
  mapChatMessageToArgs,
  mapEventToArgs,
  statusArgsFromSessionStatus,
} from "../../agterm/Resources/agent-status/opencode/agterm-status-logic.mjs";

/**
 * Mimic OpenCode's legacy plugin loader: every ESM export is treated as a plugin and must be a function.
 * @see https://github.com/anomalyco/opencode — getLegacyPlugins / "Plugin export is not a function"
 */
function assertOpenCodeLoaderCompatible(mod) {
  const entries = Object.entries(mod);
  assert.ok(entries.length >= 1, "plugin module must export at least one plugin");
  for (const [name, value] of entries) {
    assert.equal(
      typeof value,
      "function",
      `OpenCode loader rejects non-function export "${name}" (got ${typeof value})`,
    );
  }
}

describe("OpenCode loader compatibility", () => {
  it("agterm-status.js exports only plugin functions", () => {
    assertOpenCodeLoaderCompatible(pluginModule);
    assert.equal(typeof pluginModule.AgtermStatusPlugin, "function");
    assert.equal(
      Object.keys(pluginModule).sort().join(","),
      "AgtermStatusPlugin",
      "exactly one export — AgtermStatusPlugin",
    );
  });

  it("AgtermStatusPlugin returns hooks when AGTERM_SESSION_ID is set", async () => {
    const prev = process.env.AGTERM_SESSION_ID;
    process.env.AGTERM_SESSION_ID = "test-session";
    try {
      const hooks = await pluginModule.AgtermStatusPlugin();
      assert.equal(typeof hooks.event, "function");
      assert.equal(typeof hooks["chat.message"], "function");
    } finally {
      if (prev === undefined) delete process.env.AGTERM_SESSION_ID;
      else process.env.AGTERM_SESSION_ID = prev;
    }
  });

  it("AgtermStatusPlugin is a no-op outside agterm", async () => {
    const prev = process.env.AGTERM_SESSION_ID;
    delete process.env.AGTERM_SESSION_ID;
    try {
      const hooks = await pluginModule.AgtermStatusPlugin();
      assert.deepEqual(hooks, {});
    } finally {
      if (prev !== undefined) process.env.AGTERM_SESSION_ID = prev;
    }
  });
});

describe("statusArgsFromSessionStatus", () => {
  it("maps busy and retry to active --blink", () => {
    assert.deepEqual(statusArgsFromSessionStatus({ type: "busy" }), ["active", "--blink"]);
    assert.deepEqual(statusArgsFromSessionStatus({ type: "retry" }), ["active", "--blink"]);
    assert.deepEqual(statusArgsFromSessionStatus("BUSY"), ["active", "--blink"]);
  });

  it("maps idle to completed --auto-reset", () => {
    assert.deepEqual(statusArgsFromSessionStatus({ type: "idle" }), [
      "completed",
      "--auto-reset",
    ]);
  });

  it("ignores unknown status types", () => {
    assert.equal(statusArgsFromSessionStatus({ type: "running" }), null);
    assert.equal(statusArgsFromSessionStatus({}), null);
    assert.equal(statusArgsFromSessionStatus(undefined), null);
  });
});

describe("mapEventToArgs", () => {
  it("maps root lifecycle events", () => {
    const ctx = { childSessions: new Set() };
    assert.deepEqual(
      mapEventToArgs({ type: "session.status", properties: { status: { type: "busy" } } }, ctx),
      ["active", "--blink"],
    );
    assert.deepEqual(
      mapEventToArgs({ type: "session.status", properties: { status: { type: "idle" } } }, ctx),
      ["completed", "--auto-reset"],
    );
    assert.deepEqual(mapEventToArgs({ type: "permission.asked" }, ctx), ["blocked"]);
    assert.deepEqual(mapEventToArgs({ type: "session.error" }, ctx), ["blocked"]);
    assert.deepEqual(mapEventToArgs({ type: "session.compacted" }, ctx), ["active", "--blink"]);
  });

  it("ignores deprecated session.idle to avoid double completed", () => {
    const ctx = { childSessions: new Set() };
    assert.equal(mapEventToArgs({ type: "session.idle", properties: { sessionID: "s1" } }, ctx), null);
  });

  it("tracks child sessions and applies whitelist only", () => {
    const ctx = { childSessions: new Set() };
    mapEventToArgs(
      {
        type: "session.created",
        properties: { info: { id: "child-1", parentID: "root" }, sessionID: "child-1" },
      },
      ctx,
    );
    assert.ok(ctx.childSessions.has("child-1"));

    assert.deepEqual(
      mapEventToArgs(
        { type: "permission.asked", properties: { sessionID: "child-1" } },
        ctx,
      ),
      ["blocked"],
    );
    assert.deepEqual(
      mapEventToArgs(
        { type: "question.replied", properties: { sessionID: "child-1" } },
        ctx,
      ),
      ["active", "--blink"],
    );
    assert.equal(
      mapEventToArgs(
        { type: "session.status", properties: { sessionID: "child-1", status: { type: "busy" } } },
        ctx,
      ),
      null,
    );
    assert.equal(
      mapEventToArgs(
        { type: "tool.execute.before", properties: { sessionID: "child-1" } },
        ctx,
      ),
      null,
    );
  });

  it("child whitelist matches herdr", () => {
    assert.deepEqual(
      [...CHILD_EVENT_ARGS.keys()].sort(),
      [
        "permission.asked",
        "permission.replied",
        "question.asked",
        "question.rejected",
        "question.replied",
      ].sort(),
    );
  });
});

describe("mapChatMessageToArgs", () => {
  it("activates root chat and ignores child chat", () => {
    const children = new Set(["child-1"]);
    assert.deepEqual(mapChatMessageToArgs("root", children), ["active", "--blink"]);
    assert.equal(mapChatMessageToArgs("child-1", children), null);
  });
});

describe("createReportQueue", () => {
  it("runs reports strictly in order via injectable fake", async () => {
    const started = [];
    const finished = [];
    let releaseFirst;
    const firstGate = new Promise((resolve) => {
      releaseFirst = resolve;
    });

    const report = async (args) => {
      started.push(args.join(" "));
      if (args[0] === "blocked") await firstGate;
      finished.push(args.join(" "));
    };

    const enqueue = createReportQueue(report);
    const p1 = enqueue(["blocked"]);
    const p2 = enqueue(["completed", "--auto-reset"]);

    // give the queue a turn to start the first report
    await Promise.resolve();
    await Promise.resolve();
    assert.deepEqual(started, ["blocked"]);
    assert.deepEqual(finished, []);

    releaseFirst();
    await Promise.all([p1, p2]);
    assert.deepEqual(finished, ["blocked", "completed --auto-reset"]);
  });
});

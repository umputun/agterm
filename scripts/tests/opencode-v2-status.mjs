import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setImmediate as nextTurn, setTimeout as delay } from "node:timers/promises";
import plugin from "../../agterm/Resources/agent-status/opencode/agterm-v2/tui.js";

async function fixture(run, { selected = "root", sessions, active = {}, env = {}, configure } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "agterm-v2-"));
  const output = join(directory, "calls");
  const wrapper = join(directory, "wrapper");
  writeFileSync(output, "");
  writeFileSync(wrapper, '#!/bin/sh\nprintf "%s|%s|%s|%s|%s\\n" "$AGTERM_SESSION_ID" "$AGTERM_PANE" "$AGTERM_PANE_ID" "$AGTERM_SOCKET" "$*" >> "$AGTERM_TEST_OUTPUT"\n', { mode: 0o755 });
  const original = { ...process.env };
  Object.assign(process.env, {
    AGTERM_SESSION_ID: "pane-a", AGTERM_PANE: "right", AGTERM_PANE_ID: "stable-a",
    AGTERM_SOCKET: join(directory, "isolated.sock"), AGTERM_STATUS_WRAPPER: wrapper, AGTERM_TEST_OUTPUT: output,
    ...env,
  });
  const records = new Map((sessions ?? [{ id: "root" }, { id: "child", parentID: "root" }, { id: "other" }]).map(info => [info.id, info]));
  const handlers = new Set();
  const permissions = new Map();
  const forms = new Map();
  let route = selected ? { type: "session", sessionID: selected } : { type: "home" };
  const context = {
    ui: { router: { current: () => route } },
    data: { listen: (handler) => { handlers.add(handler); return () => handlers.delete(handler); } },
    client: {
      session: {
        get: async ({ sessionID }) => records.get(sessionID),
        list: async ({ parentID }) => ({ data: [...records.values()].filter(info => info.parentID === parentID), cursor: {} }),
        active: async () => active,
        form: { list: async ({ sessionID }) => forms.get(sessionID) ?? [] },
      },
      permission: { list: async ({ sessionID }) => permissions.get(sessionID) ?? [] },
    },
  };
  let cleanup;
  const calls = () => readFileSync(output, "utf8").trim().split("\n").filter(Boolean);
  const statuses = () => calls().map(line => line.split("|").at(-1));
  async function waitFor(expected) {
    for (let attempt = 0; attempt < 500; attempt++) {
      if (statuses().at(-1) === expected) return;
      await delay(10);
    }
    assert.equal(statuses().at(-1), expected, JSON.stringify(statuses()));
  }
  try {
    configure?.({ context, permissions, forms });
    cleanup = await plugin.setup(context);
    await nextTurn();
    await run({
      context, records, permissions, forms, active, calls, statuses, waitFor, handlers,
      select: (id) => { route = id ? { type: "session", sessionID: id } : { type: "home" }; },
      event: (type, data = {}) => { for (const handler of handlers) handler({ details: { type, data } }); },
      dispose: async () => { await cleanup?.(); cleanup = undefined; },
    });
  } finally {
    await cleanup?.();
    process.env = original;
    rmSync(directory, { recursive: true, force: true });
  }
}

test("selected session and descendants report to the client's pane", async () => {
  await fixture(async ({ event, waitFor, statuses, calls }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    event("session.execution.started", { sessionID: "child" });
    event("session.execution.succeeded", { sessionID: "child" });
    event("session.execution.failed", { sessionID: "other", error: { type: "unknown" } });
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    event("permission.replied", { sessionID: "root", requestID: "p1" });
    await waitFor("active --blink");
    event("session.execution.succeeded", { sessionID: "root" });
    await waitFor("completed --auto-reset");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "active --blink", "completed --auto-reset"]);
    assert.ok(calls().every(line => line.startsWith("pane-a|right|stable-a|") && line.includes("isolated.sock|")));
  });
});

test("pending requests stay blocked until the last permission or form settles", async () => {
  await fixture(async ({ event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("permission.asked", { sessionID: "root", id: "p1" });
    event("form.created", { form: { sessionID: "child", id: "f1" } });
    await waitFor("blocked");
    event("session.retry.scheduled", { sessionID: "root" });
    event("permission.replied", { sessionID: "root", requestID: "p1" });
    event("session.execution.succeeded", { sessionID: "root" });
    event("form.cancelled", { sessionID: "child", id: "f1" });
    await waitFor("completed --auto-reset");
    event("form.created", { form: { sessionID: "global", id: "unattributed" } });
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "completed --auto-reset", "active --blink"]);
  });
});

test("a failed child allows ongoing work but blocks completion until the next run", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("session.execution.started", { sessionID: "child" });
    await waitFor("active --blink");
    event("session.execution.failed", { sessionID: "child", error: { type: "provider.authentication" } });
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    event("permission.replied", { sessionID: "root", requestID: "p1" });
    await waitFor("active --blink");
    event("session.created", { sessionID: "sibling", parentID: "root" });
    event("session.execution.started", { sessionID: "sibling" });
    event("session.execution.succeeded", { sessionID: "root" });
    event("permission.asked", { sessionID: "sibling", id: "p2" });
    await waitFor("blocked");
    event("permission.replied", { sessionID: "sibling", requestID: "p2" });
    await waitFor("active --blink");
    event("session.execution.succeeded", { sessionID: "sibling" });
    await waitFor("blocked");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    event("session.execution.succeeded", { sessionID: "root" });
    await waitFor("completed --auto-reset");
  });
});

test("recoverable step overflow and retry do not block, terminal overflow does", async () => {
  await fixture(async ({ event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    event("session.step.failed", { sessionID: "root", error: { type: "context.overflow" } });
    event("session.compaction.started", { sessionID: "root" });
    event("session.retry.scheduled", { sessionID: "root" });
    event("session.execution.succeeded", { sessionID: "root" });
    await waitFor("completed --auto-reset");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "completed --auto-reset", "active --blink"]);
    event("session.execution.failed", { sessionID: "root", error: { type: "context.overflow" } });
    await waitFor("blocked");
  });
});

test("interrupt completes the family and removes abandoned requests", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    event("session.execution.interrupted", { sessionID: "root", reason: "user" });
    await waitFor("completed --auto-reset");
  });
});

test("selecting a child excludes its parent and siblings", async () => {
  await fixture(async ({ event, waitFor, statuses }) => {
    await waitFor("idle");
    event("permission.asked", { sessionID: "root", id: "parent-permission" });
    event("session.execution.started", { sessionID: "other" });
    event("session.execution.started", { sessionID: "child" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink"]);
  }, { selected: "child" });
});

test("initial hydration includes running descendants and existing requests", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("blocked");
    event("permission.replied", { sessionID: "child", requestID: "p1" });
    await waitFor("active --blink");
    event("session.execution.succeeded", { sessionID: "child" });
    await waitFor("completed --auto-reset");
  }, { active: { child: {} }, configure: ({ permissions }) => permissions.set("child", [{ id: "p1" }]) });
});

test("slow RPCs hydrate a large family with a pending permission", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("blocked");
    event("permission.replied", { sessionID: "child-49", requestID: "p1" });
    await waitFor("active --blink");
  }, {
    sessions: [{ id: "root" }, ...Array.from({ length: 50 }, (_, index) => ({ id: `child-${index}`, parentID: "root" }))],
    active: { root: {} },
    configure: ({ context, permissions }) => {
      permissions.set("child-49", [{ id: "p1" }]);
      for (const [owner, name] of [[context.client.session, "active"], [context.client.session, "get"],
        [context.client.session, "list"], [context.client.permission, "list"], [context.client.session.form, "list"]]) {
        const original = owner[name];
        owner[name] = async (args, options) => {
          await delay(110, undefined, { signal: options?.signal ?? args?.signal });
          return original(args, options);
        };
      }
    },
  });
});

test("switching to another session or home clears the previous blocked status without a server event", async () => {
  await fixture(async ({ event, waitFor, select, statuses }) => {
    await waitFor("idle");
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    select("other");
    await waitFor("idle");
    event("permission.asked", { sessionID: "root", id: "p2" });
    event("session.execution.started", { sessionID: "other" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "blocked", "idle", "active --blink"]);
    select(null);
    await waitFor("idle");
  });
});

test("reconnect replaces lost requests and busy state with a fresh snapshot", async () => {
  await fixture(async ({ event, waitFor, records }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    records.set("root", { id: "root", outcome: "succeeded" });
    event("server.connected");
    await waitFor("completed --auto-reset");
  });
});

for (const [outcome, status] of [["failed", "blocked"], ["succeeded", "completed --auto-reset"]]) {
  test(`reconnect does not resend an unchanged ${status} status`, async () => {
    await fixture(async ({ event, waitFor, statuses }) => {
      await waitFor(status);
      event("server.connected");
      await nextTurn();
      event("session.execution.started", { sessionID: "root" });
      await waitFor("active --blink");
      assert.deepEqual(statuses(), ["idle", status, "active --blink"]);
    }, { sessions: [{ id: "root", outcome }] });
  });
}

test("reconnect preserves a queued report for the same selection", async () => {
  await fixture(async ({ event, waitFor, records, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    records.set("root", { id: "root", outcome: "failed" });
    event("session.execution.failed", { sessionID: "root" });
    event("server.connected");
    await waitFor("blocked");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "active --blink"]);
  });
});

test("failed reconnect keeps pending permissions blocked and continues tracking live events", async () => {
  await fixture(async ({ context, event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    context.client.session.active = async () => { throw new Error("temporary RPC failure"); };
    event("server.connected");
    await nextTurn();
    event("permission.asked", { sessionID: "root", id: "p2" });
    event("permission.replied", { sessionID: "root", requestID: "p1" });
    event("permission.replied", { sessionID: "root", requestID: "p2" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "active --blink"]);
  });
});

test("failed reconnect replays buffered events and aborts remaining hydration RPCs", async () => {
  await fixture(async ({ context, event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    const get = context.client.session.get;
    let fail;
    let waiting = false;
    let aborted = false;
    context.client.session.get = (args, { signal }) => {
      if (args.sessionID === "child") return new Promise((_, reject) => { fail = reject; });
      if (args.sessionID === "sibling") return new Promise((_, reject) => {
        signal.addEventListener("abort", () => { aborted = true; reject(signal.reason); }, { once: true });
        waiting = true;
      });
      return get(args);
    };
    event("server.connected");
    for (let attempt = 0; !waiting && attempt < 100; attempt++) await delay(10);
    assert.equal(waiting, true);
    event("permission.asked", { sessionID: "root", id: "p1" });
    fail(new Error("child RPC failed"));
    await waitFor("blocked");
    assert.equal(aborted, true);
    event("permission.replied", { sessionID: "root", requestID: "p1" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "active --blink"]);
  }, { sessions: [{ id: "root" }, { id: "child", parentID: "root" }, { id: "sibling", parentID: "root" }] });
});

test("overlapping reconnects preserve buffered permission requests", async () => {
  await fixture(async ({ context, event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    context.client.session.active = ({ signal }) => new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
    event("server.connected");
    event("permission.asked", { sessionID: "root", id: "pending" });
    context.client.session.active = async () => { throw new Error("reconnect RPC failed"); };
    event("server.connected");
    await nextTurn();
    event("permission.asked", { sessionID: "root", id: "barrier" });
    await waitFor("blocked");
    event("permission.replied", { sessionID: "root", requestID: "barrier" });
    event("session.deleted", { sessionID: "root" });
    await waitFor("idle");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "idle"]);
  });
});

test("overlapping reconnects preserve buffered permission replies", async () => {
  await fixture(async ({ context, event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("permission.asked", { sessionID: "root", id: "pending" });
    await waitFor("blocked");
    context.client.session.active = ({ signal }) => new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
    event("server.connected");
    event("permission.replied", { sessionID: "root", requestID: "pending" });
    context.client.session.active = async () => { throw new Error("reconnect RPC failed"); };
    event("server.connected");
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "blocked", "active --blink"]);
  });
});

for (const buffered of ["permission.asked", "session.execution.started"]) {
  test(`a successful reconnect snapshot supersedes an earlier buffered ${buffered}`, async () => {
    await fixture(async ({ context, records, event, waitFor, statuses }) => {
      await waitFor("idle");
      if (buffered === "permission.asked") {
        event("session.execution.started", { sessionID: "root" });
        await waitFor("active --blink");
      }
      context.client.session.active = ({ signal }) => new Promise((_, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
      event("server.connected");
      event(buffered, { sessionID: "root", id: "answered-during-disconnect" });
      records.set("root", { id: "root", outcome: "succeeded", time: { idle: 30 } });
      context.client.session.active = async () => ({});
      event("server.connected");
      await waitFor("completed --auto-reset");
      assert.deepEqual(statuses(), buffered === "permission.asked"
        ? ["idle", "active --blink", "completed --auto-reset"] : ["idle", "completed --auto-reset"]);
    });
  });
}

test("a selection change discards the previous family's buffered events", async () => {
  await fixture(async ({ context, event, select, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    context.client.session.active = ({ signal }) => new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
    event("server.connected");
    event("permission.asked", { sessionID: "child", id: "stale" });
    select("child");
    context.client.session.active = async () => ({ child: {} });
    event("server.connected");
    await nextTurn();
    event("permission.asked", { sessionID: "child", id: "barrier" });
    await waitFor("blocked");
    event("permission.replied", { sessionID: "child", requestID: "barrier" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink", "idle", "active --blink", "blocked", "active --blink"]);
  });
});

test("hydration keeps an idle root's failed last run blocked", async () => {
  await fixture(async ({ waitFor }) => {
    await waitFor("blocked");
  }, { sessions: [{ id: "root", outcome: "failed" }] });
});

test("hydration completes a succeeded root despite an older failed child", async () => {
  await fixture(async ({ waitFor, statuses }) => {
    await waitFor("completed --auto-reset");
    assert.ok(!statuses().includes("blocked"));
  }, {
    sessions: [{ id: "root", outcome: "succeeded", time: { idle: 20 } },
      { id: "child", parentID: "root", outcome: "failed", time: { idle: 10 } }],
  });
});

test("hydration leaves a root interrupted by shutdown idle", async () => {
  await fixture(async ({ event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink"]);
  }, { sessions: [{ id: "root", outcome: "interrupted" }] });
});

test("hydration leaves an interrupted root idle despite an older succeeded child", async () => {
  await fixture(async ({ event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink"]);
  }, {
    sessions: [{ id: "root", outcome: "interrupted", time: { idle: 20 } },
      { id: "child", parentID: "root", outcome: "succeeded", time: { idle: 10 } }],
  });
});

test("new descendants are included, deleted descendants cannot leave stale blocked", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("idle");
    event("session.execution.started", { sessionID: "root" });
    event("session.created", { sessionID: "new-child", parentID: "root" });
    event("form.created", { form: { sessionID: "new-child", id: "f1" } });
    await waitFor("blocked");
    event("session.deleted", { sessionID: "new-child" });
    await waitFor("active --blink");
    event("session.deleted", { sessionID: "root" });
    await waitFor("idle");
  });
});

test("events arriving during hydration win over the older snapshot", async () => {
  let release;
  await fixture(async ({ event, waitFor }) => {
    for (let attempt = 0; !release && attempt < 100; attempt++) await delay(10);
    assert.equal(typeof release, "function");
    event("session.execution.started", { sessionID: "root" });
    event("permission.asked", { sessionID: "root", id: "new" });
    release([]);
    await waitFor("blocked");
  }, { configure: ({ context }) => {
    context.client.permission.list = ({ sessionID }) => sessionID === "root"
      ? new Promise(resolve => { release = resolve; }) : Promise.resolve([]);
  } });
});

test("cleanup unsubscribes and clears the status", async () => {
  await fixture(async ({ event, waitFor, dispose, handlers, statuses }) => {
    await waitFor("idle");
    event("permission.asked", { sessionID: "root", id: "p1" });
    await waitFor("blocked");
    await dispose();
    assert.equal(handlers.size, 0);
    assert.equal(statuses().at(-1), "idle");
    event("session.execution.started", { sessionID: "root" });
    assert.deepEqual(statuses(), ["idle", "blocked", "idle"]);
  });
});

test("a late snapshot from the previous selection cannot overwrite the new session", async () => {
  let release;
  await fixture(async ({ select, event, waitFor, statuses }) => {
    for (let attempt = 0; !release && attempt < 100; attempt++) await delay(10);
    assert.equal(typeof release, "function");
    await waitFor("idle");
    select("other");
    event("session.execution.started", { sessionID: "other" });
    await waitFor("active --blink");
    release([{ id: "stale" }]);
    await nextTurn();
    event("session.execution.succeeded", { sessionID: "other" });
    await waitFor("completed --auto-reset");
    event("session.execution.started", { sessionID: "other" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "idle", "active --blink", "completed --auto-reset", "active --blink"]);
  }, { configure: ({ context }) => {
    context.client.permission.list = ({ sessionID }) => sessionID === "root"
      ? new Promise(resolve => { release = resolve; }) : Promise.resolve([]);
  } });
});

test("two CLI clients observing the same events keep independent pane ownership", async () => {
  await fixture(async first => {
    await first.waitFor("idle");
    await fixture(async second => {
      await second.waitFor("idle");
      for (const client of [first, second]) {
        client.event("session.execution.started", { sessionID: "root" });
        client.event("permission.asked", { sessionID: "root", id: "p1" });
        client.event("session.execution.started", { sessionID: "other" });
      }
      await first.waitFor("blocked");
      await second.waitFor("active --blink");
      assert.ok(first.calls().every(line => line.startsWith("pane-a|")));
      assert.ok(second.calls().every(line => line.startsWith("pane-b|")));
    }, { selected: "other", env: { AGTERM_SESSION_ID: "pane-b" } });
  });
});

test("outside agterm setup is a no-op", async () => {
  await fixture(async ({ handlers, calls }) => {
    assert.equal(handlers.size, 0);
    assert.deepEqual(calls(), []);
  }, { env: { AGTERM_SESSION_ID: "" } });
});

test("reporting failures do not reject into OpenCode", async () => {
  await fixture(async ({ event, dispose }) => {
    event("session.execution.started", { sessionID: "root" });
    await nextTurn();
    await assert.doesNotReject(dispose());
  }, { env: { AGTERM_STATUS_WRAPPER: "/nonexistent/agterm-test-wrapper" } });
});

test("paginated descendants hydrate through the public client API", async () => {
  await fixture(async ({ waitFor }) => {
    await waitFor("blocked");
  }, { configure: ({ context, permissions }) => {
    permissions.set("child", [{ id: "p1" }]);
    context.client.session.list = async ({ parentID, cursor }) => {
      if (parentID !== "root") return { data: [], cursor: {} };
      return cursor === "next" ? { data: [{ id: "child", parentID: "root" }], cursor: {} }
        : { data: [], cursor: { next: "next" } };
    };
  } });
});

test("children from different pages hydrate concurrently", async () => {
  const children = Array.from({ length: 3 }, (_, index) => ({ id: `child-${index}`, parentID: "root" }));
  await fixture(async ({ event, waitFor }) => {
    await waitFor("blocked");
    event("permission.replied", { sessionID: "child-2", requestID: "p1" });
    await waitFor("active --blink");
  }, {
    sessions: [{ id: "root" }, ...children],
    active: { root: {} },
    configure: ({ context, permissions }) => {
      permissions.set("child-2", [{ id: "p1" }]);
      let started = 0;
      let release;
      const allStarted = new Promise(resolve => { release = resolve; });
      const get = context.client.session.get;
      context.client.session.get = async args => {
        if (args.sessionID !== "root") {
          if (++started === children.length) release();
          await allStarted;
        }
        return get(args);
      };
      context.client.session.list = async ({ parentID, cursor }) => {
        if (parentID !== "root") return { data: [], cursor: {} };
        const index = Number(cursor ?? 0);
        return { data: [children[index]], cursor: { next: index < children.length - 1 ? String(index + 1) : undefined } };
      };
    },
  });
});

test("terminal errors unrelated to a running turn do not paint a blocked indicator", async () => {
  await fixture(async ({ event, waitFor, statuses }) => {
    await waitFor("idle");
    event("session.execution.failed", { sessionID: "root", error: { type: "unknown" } });
    event("session.execution.started", { sessionID: "root" });
    await waitFor("active --blink");
    assert.deepEqual(statuses(), ["idle", "active --blink"]);
  });
});

test("server shutdown or superseding a run is not reported as a completed turn", async () => {
  for (const reason of ["shutdown", "superseded"]) {
    await fixture(async ({ event, waitFor, statuses }) => {
      await waitFor("idle");
      event("session.execution.started", { sessionID: "root" });
      await waitFor("active --blink");
      event("session.execution.interrupted", { sessionID: "root", reason });
      await waitFor("idle");
      event("session.execution.started", { sessionID: "root" });
      await waitFor("active --blink");
      assert.deepEqual(statuses(), ["idle", "active --blink", "idle", "active --blink"]);
    });
  }
});

test("hydration does not revive a child failure from a previous parent turn", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("active --blink");
    event("session.execution.succeeded", { sessionID: "root" });
    await waitFor("completed --auto-reset");
  }, {
    active: { root: {} },
    sessions: [{ id: "root", outcome: "succeeded", time: { idle: 20 } },
      { id: "child", parentID: "root", outcome: "failed", time: { idle: 10 } }],
  });
});

test("hydration retains a child failure during the current parent turn", async () => {
  await fixture(async ({ event, waitFor }) => {
    await waitFor("active --blink");
    event("session.execution.succeeded", { sessionID: "root" });
    await waitFor("blocked");
  }, {
    active: { root: {} },
    sessions: [{ id: "root", outcome: "succeeded", time: { idle: 10 } },
      { id: "child", parentID: "root", outcome: "failed", time: { idle: 20 } }],
  });
});

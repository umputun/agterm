// agterm-opencode-status-plugin
//
// OpenCode lifecycle plugin installed by agterm's Help ▸ Install Agent Status Hooks… command.
// Reports agent status through the installed agterm wrapper; a clean no-op outside agterm.
//
// IMPORTANT: this module must export ONLY plugin function(s). OpenCode's legacy loader treats
// every export as a plugin and throws "Plugin export is not a function" on non-functions.
// Testable helpers live in agterm-status-logic.mjs (not auto-discovered: OpenCode globs *.{js,ts}).

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  createReportQueue,
  mapChatMessageToArgs,
  mapEventToArgs,
} from "./agterm-status-logic.mjs";

function defaultWrapperPath() {
  return join(homedir(), ".config", "agterm", "agent-status", "agterm-agent-status.sh");
}

function spawnReport(wrapper, args) {
  return new Promise((resolve) => {
    const child = spawn(wrapper, args, {
      stdio: "ignore",
      env: process.env,
    });
    const finish = () => resolve();
    child.on("error", finish);
    child.on("close", finish);
    setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
      finish();
    }, 1_000);
  });
}

/**
 * OpenCode plugin entry. Named export — OpenCode loads plugins from ~/.config/opencode/plugins/.
 * This must remain the only export from this file.
 */
export const AgtermStatusPlugin = async () => {
  if (!process.env.AGTERM_SESSION_ID) {
    return {};
  }

  const childSessions = new Set();
  const wrapper = process.env.AGTERM_STATUS_WRAPPER || defaultWrapperPath();
  const enqueue = createReportQueue((args) => spawnReport(wrapper, args));

  async function reportFromEvent(event) {
    const args = mapEventToArgs(event, { childSessions });
    if (args) await enqueue(args);
  }

  return {
    "chat.message": async ({ sessionID }) => {
      const args = mapChatMessageToArgs(sessionID, childSessions);
      if (args) await enqueue(args);
    },
    event: async ({ event }) => {
      await reportFromEvent(event);
    },
  };
};

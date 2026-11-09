#!/usr/bin/env python3
"""Answer plannotator-tui's delivery calls for agterm, in place of the `herdr` CLI it expects.

plannotator-tui hands feedback to an agent only through the Herdr multiplexer's CLI, by running
`$HERDR_BIN_PATH agent prompt <pane> <feedback>`. Herdr is not installed; annotate.py points
HERDR_BIN_PATH here, so the viewer's own Send button works in agterm. Three calls are answered:

    pane read <pane> ...           the text annotate.py captured (AGT_ANNOTATE_CAPTURE)
    pane get <pane>                the agent annotate.py saw in the pane, for the button label
    agent prompt <pane> <text>     appends the feedback to AGT_ANNOTATE_OUTBOX, one JSON string a line

The outbox is pasted by annotate.py after the overlay closes, never from here: the overlay sits on
top of the pane the paste goes to.

A refusal is the JSON envelope Herdr prints on stderr, so the TUI shows the reason in its footer and
keeps the notes pending. Any other call fails with an `unsupported` envelope rather than pretending:
if a plannotator-tui upgrade starts calling something new, the footer names it.

Needs Python 3.9 or later; under the overlay's small PATH, `env python3` finds /usr/bin/python3.
"""

import json
import os
import sys


def refuse(code, message):
    sys.stderr.write(json.dumps({"error": {"code": code, "message": message}}) + "\n")
    return 1


def main(argv):
    if argv[:2] == ["pane", "read"]:
        with open(os.environ["AGT_ANNOTATE_CAPTURE"], encoding="utf-8") as fh:
            sys.stdout.write(fh.read())
        return 0
    if argv[:2] == ["pane", "get"]:
        agent = os.environ.get("PLANNOTATOR_TUI_DELIVER_AGENT") or ""
        if not agent:
            return refuse("agent_not_found", "no agent known in this pane")
        sys.stdout.write(json.dumps({"result": {"pane": {"agent": agent}}}) + "\n")
        return 0
    if argv[:2] == ["agent", "prompt"] and len(argv) == 4:
        refusal = os.environ.get("AGT_ANNOTATE_REFUSE") or ""
        if refusal:
            return refuse("agent_not_found", refusal)
        if not argv[3].strip():
            return refuse("empty_agent_prompt", "nothing to send")
        with open(os.environ["AGT_ANNOTATE_OUTBOX"], "a", encoding="utf-8") as fh:
            fh.write(json.dumps(argv[3]) + "\n")
        return 0
    return refuse("unsupported", "agterm's herdr stand-in has no: herdr " + " ".join(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

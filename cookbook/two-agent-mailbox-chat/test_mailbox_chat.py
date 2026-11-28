#!/usr/bin/env python3
"""Regression checks for the mailbox chat transport."""

import importlib.util
import io
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("mailbox_chat", Path(__file__).with_name("mailbox-chat.py"))
mc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mc)

SID = "S1"
LEFT = "PL"
RIGHT = "PR"


def done(code=0, out="", err=""):
    return subprocess.CompletedProcess([], code, out, err)


def tree(*surfaces):
    return {"windows": [{"workspaces": [{"sessions": [{"id": SID, "surfaces": list(surfaces)}]}]}]}


SPLIT = tree({"kind": "left", "paneID": LEFT}, {"kind": "right", "paneID": RIGHT})


class FakeRun:
    """records every command and answers agtermctl and codex calls from scripted state."""

    def __init__(self, tree_value=SPLIT, mailboxes=None, queue_code=0, windows=None):
        self.tree = tree_value
        self.windows = windows
        self.mailboxes = mailboxes or {}
        self.queue_code = queue_code
        self.calls = []
        self.sent = []
        self.queued = []

    def __call__(self, args, timeout=30, stdin=None, alive=None):
        self.calls.append(list(args))
        if os.path.basename(args[0]) == "codex":
            if self.queue_code:
                return done(self.queue_code, err="queue refused")
            self.queued.append(args[args.index("--message") + 1])
            return done()
        cmd = args[1:3]
        if cmd == ["tree", "--json"]:
            if self.windows is None:
                return done(out=json.dumps(self.tree))
            window = args[args.index("--window") + 1] if "--window" in args else next(iter(self.windows))
            return done(out=json.dumps(self.windows[window]))
        if cmd == ["window", "list"]:
            listed = [{"id": w, "open": True} for w in self.windows or {}]
            return done(out=json.dumps({"result": {"windows": listed}}))
        identity = args[args.index("--as") + 1] if "--as" in args else ""
        if cmd == ["msg", "send"]:
            to = args[args.index("--to") + 1]
            self.sent.append((to, stdin))
            mid = f"M{len(self.sent)}"
            self.mailboxes.setdefault(to, []).append({"id": mid, "from": f"{SID}:{os.environ['AGTERM_PANE_ID']}",
                                                      "body": stdin})
            return done(out=json.dumps({"result": {"messageID": mid}}))
        if cmd == ["msg", "read"]:
            return done(out=json.dumps({"result": {"messages": list(self.mailboxes.get(identity, []))}}))
        if cmd == ["msg", "ack"]:
            rest = args[args.index("--as") + 2:]
            ids = set(rest[:rest.index("--socket")] if "--socket" in rest else rest)
            self.mailboxes[identity] = [m for m in self.mailboxes.get(identity, []) if m["id"] not in ids]
            return done()
        raise AssertionError(f"unexpected command {args}")


class StateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patches = [
            mock.patch.object(mc, "STATE_DIR", self.tmp.name),
            mock.patch.object(mc, "AGTERMCTL", "agtermctl"),
            mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": SID, "AGTERM_PANE_ID": LEFT}, clear=False),
            mock.patch.object(mc, "find_codex_pid", return_value=None),
            # the real reader calls macOS sysctl, which the Linux CI runner's libc lacks
            mock.patch.object(mc, "process_argv", return_value=None),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        for name in ("AGTERM_SOCKET", "AGTERM_WINDOW_ID"):
            os.environ.pop(name, None)

    def use(self, fake):
        p = mock.patch.object(mc, "run", fake)
        p.start()
        self.addCleanup(p.stop)
        return fake

    def register_codex(self, pane, pid=None, executable="/opt/codex/bin/codex"):
        mc.Courier(SID, pane).register("T1", pid or os.getpid(), executable)

    def listen_claude(self, pane, pid=None):
        mc.write_json(mc.state_path(f"claude-{pane}.json"), {"pid": pid or os.getpid()})


class ComposeTest(unittest.TestCase):
    def test_compose_adds_label_and_reply_line(self):
        self.assertEqual(mc.compose("  hello\nsecond line  "), f"{mc.LABEL} hello\nsecond line\n\n{mc.REPLY_LINE}")

    def test_compose_does_not_double_label_or_reply_line(self):
        once = mc.compose("hello")
        self.assertEqual(mc.compose(once), once)

    def test_compose_refuses_empty_message(self):
        for text in ("", "   ", mc.LABEL, f"{mc.LABEL}\n\n{mc.REPLY_LINE}"):
            with self.subTest(text=text), self.assertRaises(mc.ChatError):
                mc.compose(text)

    def test_compose_counts_label_and_reply_line_against_limit(self):
        mc.compose("x" * (mc.BODY_LIMIT - len(mc.LABEL) - len(mc.REPLY_LINE) - 3))
        with self.assertRaises(mc.ChatError):
            mc.compose("x" * (mc.BODY_LIMIT - len(mc.LABEL) - len(mc.REPLY_LINE) - 2))

    def test_render_passes_chat_mail_through(self):
        body = mc.compose("hello")
        self.assertEqual(mc.render({"id": "M1", "from": f"{SID}:{LEFT}", "body": body}), body)

    def test_render_marks_other_mail_with_sender(self):
        cases = [({"body": "build done", "from": "S2:P9"}, "from S2:P9:\nbuild done"),
                 ({"body": "build done"}, "from outside agterm:\nbuild done")]
        for message, tail in cases:
            with self.subTest(message=message):
                text = mc.render(message)
                self.assertTrue(text.startswith("[agterm mailbox, not a peer chat message]"))
                self.assertTrue(text.endswith(tail))
                self.assertFalse(text.startswith(mc.LABEL))


class PaneTest(StateTest):
    def test_other_pane_is_across_the_split_both_ways(self):
        self.use(FakeRun())
        self.assertEqual(mc.other_pane(SID, LEFT), RIGHT)
        self.assertEqual(mc.other_pane(SID, RIGHT), LEFT)

    def test_other_pane_finds_session_in_a_background_window(self):
        other = tree({"kind": "left", "paneID": "QL"}, {"kind": "right", "paneID": "QR"})
        other["windows"][0]["workspaces"][0]["sessions"][0]["id"] = "S2"
        self.use(FakeRun(windows={"W1": other, "W2": SPLIT}))
        for window in ("", "W1"):
            with self.subTest(window=window), mock.patch.dict(os.environ, {"AGTERM_WINDOW_ID": window}):
                self.assertEqual(mc.other_pane(SID, LEFT), RIGHT)

    def test_other_pane_refuses_unsplit_session(self):
        self.use(FakeRun(tree_value=tree({"kind": "left", "paneID": LEFT})))
        with self.assertRaisesRegex(mc.ChatError, "no split"):
            mc.other_pane(SID, LEFT)

    def test_other_pane_refuses_pane_outside_session(self):
        self.use(FakeRun())
        with self.assertRaisesRegex(mc.ChatError, "not the left or right pane"):
            mc.other_pane(SID, "PX")

    def test_other_pane_refuses_unknown_session(self):
        self.use(FakeRun())
        with self.assertRaisesRegex(mc.ChatError, "not in any open agterm window"):
            mc.other_pane("S9", LEFT)

    def test_tree_read_names_callers_window_and_socket(self):
        fake = self.use(FakeRun())
        with mock.patch.dict(os.environ, {"AGTERM_WINDOW_ID": "W1", "AGTERM_SOCKET": "/tmp/s.sock"}):
            mc.other_pane(SID, LEFT)
        self.assertEqual(fake.calls[0], ["agtermctl", "tree", "--json", "--window", "W1", "--socket", "/tmp/s.sock"])

    def test_agtermctl_override_is_used(self):
        fake = self.use(FakeRun())
        with mock.patch.object(mc, "AGTERMCTL", "/opt/agterm/agtermctl"):
            mc.other_pane(SID, LEFT)
        self.assertEqual(fake.calls[0][0], "/opt/agterm/agtermctl")

    def test_missing_identity_is_refused(self):
        with mock.patch.dict(os.environ, {"AGTERM_PANE_ID": ""}), self.assertRaisesRegex(mc.ChatError, "Setup"):
            mc.own_identity()


class ReceiverTest(StateTest):
    def test_receiver_by_live_registration(self):
        self.register_codex(RIGHT)
        self.listen_claude(LEFT)
        self.assertEqual(mc.receiver(SID, RIGHT), "codex")
        self.assertEqual(mc.receiver(SID, LEFT), "claude")
        self.assertEqual(mc.receiver(SID, "PX"), "none")

    def test_dead_codex_registration_is_ignored(self):
        with mock.patch.object(mc, "pid_alive", return_value=False):
            self.register_codex(RIGHT, pid=999999)
            self.assertEqual(mc.receiver(SID, RIGHT), "none")

    def test_registration_from_another_session_is_ignored(self):
        mc.write_json(mc.state_path(f"codex-{RIGHT}.json"), {"session": "S2", "thread": "T1", "pid": os.getpid()})
        self.assertIsNone(mc.Courier(SID, RIGHT).registration())

    def test_registration_held_by_the_codex_daemon_is_ignored(self):
        # regression: a thread the shared app-server registered under the pane that started it took that pane's mail
        self.register_codex(RIGHT)
        with mock.patch.object(mc, "is_codex_daemon", return_value=True) as daemon:
            self.assertEqual(mc.receiver(SID, RIGHT), "none")
            self.assertIsNone(mc.Courier(SID, RIGHT).registration())
        daemon.assert_called_with(os.getpid())


class SayTest(StateTest):
    def test_say_to_codex_leaves_delivery_to_the_event_hook(self):
        fake = self.use(FakeRun())
        self.register_codex(RIGHT)
        result = mc.say("check this")
        self.assertEqual(result, {"sent": len(mc.compose("check this").encode("utf-8")), "receiver": "codex"})
        self.assertEqual(fake.queued, [])
        self.assertEqual([m["body"] for m in fake.mailboxes[f"{SID}:{RIGHT}"]], [mc.compose("check this")])

    def test_say_to_claude_reports_listening_peer_state(self):
        fake = self.use(FakeRun())
        self.listen_claude(RIGHT)
        result = mc.say("hello")
        self.assertEqual(result["receiver"], "claude")
        self.assertFalse(result["peerBusy"])
        self.assertEqual(fake.sent, [(f"{SID}:{RIGHT}", mc.compose("hello"))])
        self.assertEqual(fake.queued, [])

    def test_say_from_right_pane_reaches_left(self):
        fake = self.use(FakeRun())
        with mock.patch.dict(os.environ, {"AGTERM_PANE_ID": RIGHT}):
            result = mc.say("hello")
        self.assertEqual(fake.sent[0][0], f"{SID}:{LEFT}")
        self.assertEqual(result["receiver"], "none")

    def test_refused_send_is_an_error(self):
        self.use(lambda args, timeout=30, stdin=None, alive=None: done(out=json.dumps(SPLIT)) if args[1:3] == ["tree", "--json"]
                 else done(1, err="mailbox full"))
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("hello")), mock.patch("sys.stdout", out):
            self.assertEqual(mc.main(["say", "--stdin"]), 1)
        self.assertIn("mailbox full", json.loads(out.getvalue())["error"])

    def say_file(self, path):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            code = mc.main(["say", "--file", path])
        return code, json.loads(out.getvalue())

    def test_say_file_sends_its_text_and_keeps_the_file(self):
        fake = self.use(FakeRun())
        path = os.path.join(self.tmp.name, "msg.txt")
        Path(path).write_text("from a file\n", encoding="utf-8")
        code, result = self.say_file(path)
        self.assertEqual(code, 0)
        self.assertEqual(result["receiver"], "none")
        self.assertEqual(fake.sent, [(f"{SID}:{RIGHT}", mc.compose("from a file"))])
        self.assertTrue(os.path.exists(path))

    def test_say_file_keeps_the_file_when_the_send_is_refused(self):
        self.use(lambda args, timeout=30, stdin=None, alive=None: done(out=json.dumps(SPLIT)) if args[1:3] == ["tree", "--json"]
                 else done(1, err="mailbox full"))
        path = os.path.join(self.tmp.name, "msg.txt")
        Path(path).write_text("hello", encoding="utf-8")
        code, result = self.say_file(path)
        self.assertEqual(code, 1)
        self.assertIn("mailbox full", result["error"])
        self.assertTrue(os.path.exists(path))

    def test_say_file_refuses_unreadable_input_without_sending(self):
        oversized = os.path.join(self.tmp.name, "big.txt")
        Path(oversized).write_bytes(b"x" * (mc.BODY_LIMIT + 1))
        fifo = os.path.join(self.tmp.name, "fifo")
        os.mkfifo(fifo)
        binary = os.path.join(self.tmp.name, "bin")
        Path(binary).write_bytes(b"\xff\xfe")
        missing = os.path.join(self.tmp.name, "missing.txt")
        for path, want in ((oversized, "limit"), (fifo, "not a regular file"), (self.tmp.name, "not a regular file"),
                           (binary, "utf-8"), (missing, "No such file"), ("", "No such file")):
            with self.subTest(path=os.path.basename(path)):
                fake = self.use(FakeRun())
                code, result = self.say_file(path)
                self.assertEqual(code, 1)
                self.assertIn(want, result["error"])
                self.assertEqual(fake.sent, [])

    def test_say_takes_exactly_one_input(self):
        for argv in (["say"], ["say", "--stdin", "--file", "x"]):
            with self.subTest(argv=argv), mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                mc.main(argv)

    def test_identity_under_the_codex_daemon_is_refused(self):
        fake = self.use(FakeRun())
        with mock.patch.object(mc, "find_codex_pid", return_value=777), \
                mock.patch.object(mc, "is_codex_daemon", return_value=True):
            for call in (lambda: mc.say("hello"), mc.status):
                with self.subTest(call=call), self.assertRaisesRegex(mc.ChatError, "--no-daemon"):
                    call()
        self.assertEqual(fake.calls, [])

    def test_deliver_under_the_codex_daemon_is_refused(self):
        fake = self.use(FakeRun())
        for argv in (["deliver"], ["deliver", "--pane", RIGHT]):
            with self.subTest(argv=argv), mock.patch.object(mc, "find_codex_pid", return_value=777), \
                    mock.patch.object(mc, "is_codex_daemon", return_value=True), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                self.assertEqual(mc.main(argv), 1)
                self.assertIn("--no-daemon", json.loads(out.getvalue())["error"])
        self.assertEqual(fake.calls, [])

    def test_identity_under_an_interactive_codex_is_kept(self):
        with mock.patch.object(mc, "find_codex_pid", return_value=777), \
                mock.patch.object(mc, "is_codex_daemon", return_value=False):
            self.assertEqual(mc.own_identity(), (SID, LEFT))

    def test_status_reports_peer_receiver(self):
        self.use(FakeRun())
        self.listen_claude(RIGHT)
        mc.Waiter(SID, RIGHT).mark_busy()
        self.assertEqual(mc.status(), {"pane": LEFT, "peerPane": RIGHT, "receiver": "claude", "peerBusy": True})


class CourierTest(StateTest):
    def test_deliver_renders_other_mail_before_queueing(self):
        fake = self.use(FakeRun(mailboxes={f"{SID}:{RIGHT}": [{"id": "M1", "from": "S2:P9", "body": "ping"}]}))
        self.register_codex(RIGHT)
        self.assertEqual(mc.Courier(SID, RIGHT).deliver(), 1)
        self.assertEqual(fake.queued, [mc.render({"from": "S2:P9", "body": "ping"})])

    def test_deliver_without_registration_is_refused(self):
        self.use(FakeRun())
        with self.assertRaisesRegex(mc.ChatError, "no running codex"):
            mc.Courier(SID, RIGHT).deliver()

    def test_deliver_runs_the_registered_codex_executable(self):
        fake = self.use(FakeRun(mailboxes={f"{SID}:{RIGHT}": [{"id": "M1", "body": "ping"}]}))
        self.register_codex(RIGHT, executable="/home/u/.npm/bin/codex")
        mc.Courier(SID, RIGHT).deliver()
        self.assertEqual([c[0] for c in fake.calls if c[1] == "queue"], ["/home/u/.npm/bin/codex"])

    def test_codex_exit_mid_batch_leaves_the_rest_in_the_mailbox(self):
        fake = self.use(FakeRun(mailboxes={f"{SID}:{RIGHT}": [{"id": "M1", "body": "a"}, {"id": "M2", "body": "b"}]}))
        self.register_codex(RIGHT)
        with mock.patch.object(mc, "pid_alive", side_effect=lambda pid: not fake.queued), \
                self.assertRaisesRegex(mc.ChatError, "exited after 1 delivered"):
            mc.Courier(SID, RIGHT).deliver()
        self.assertEqual([m["id"] for m in fake.mailboxes[f"{SID}:{RIGHT}"]], ["M2"])

    def test_codex_gone_by_the_time_the_lock_is_taken_gets_nothing(self):
        fake = self.use(FakeRun(mailboxes={f"{SID}:{RIGHT}": [{"id": "M1", "body": "a"}]}))
        self.register_codex(RIGHT)
        alive = iter([True])
        with mock.patch.object(mc, "pid_alive", side_effect=lambda pid: next(alive, False)), \
                self.assertRaisesRegex(mc.ChatError, "exited before delivery"):
            mc.Courier(SID, RIGHT).deliver()
        self.assertEqual(fake.queued, [])


class AgtermHookTest(StateTest):
    def hook(self, event, socket="/tmp/test.sock"):
        err = io.StringIO()
        env = {"AGT_SOCKET": socket, "AGTERM_SOCKET": "/tmp/live.sock"}
        with mock.patch("sys.stdin", io.StringIO(json.dumps(event))), mock.patch.dict(os.environ, env), \
                mock.patch("sys.stderr", err):
            code = mc.agterm_hook()
        return code, err.getvalue()

    def event(self, pane=RIGHT):
        return {"kind": "message", "session": SID, "payload": {"paneID": pane, "messageID": "M1"}}

    def test_mail_to_registered_codex_is_delivered_over_the_event_socket(self):
        fake = self.use(FakeRun(mailboxes={f"{SID}:{RIGHT}": [{"id": "M1", "body": "ping"}]}))
        self.register_codex(RIGHT)
        self.assertEqual(self.hook(self.event()), (0, ""))
        self.assertEqual(fake.queued, [mc.render({"body": "ping"})])
        ctl = [c for c in fake.calls if c[0] == "agtermctl"]
        self.assertTrue(ctl)
        self.assertTrue(all(c[-2:] == ["--socket", "/tmp/test.sock"] for c in ctl))

    def test_mail_to_a_pane_without_codex_is_ignored(self):
        fake = self.use(FakeRun())
        for event in (self.event(LEFT), {"kind": "message"}, {}):
            with self.subTest(event=event):
                self.assertEqual(self.hook(event), (0, ""))
        self.assertEqual(fake.calls, [])

    def test_missing_event_socket_is_refused(self):
        fake = self.use(FakeRun())
        self.register_codex(RIGHT)
        code, err = self.hook(self.event(), socket="")
        self.assertEqual(code, 1)
        self.assertIn("AGT_SOCKET", err)
        self.assertEqual(fake.calls, [])

    def test_delivery_failure_exits_nonzero_and_keeps_mail(self):
        fake = self.use(FakeRun(queue_code=1, mailboxes={f"{SID}:{RIGHT}": [{"id": "M1", "body": "ping"}]}))
        self.register_codex(RIGHT)
        code, err = self.hook(self.event())
        self.assertEqual(code, 1)
        self.assertIn("queue refused", err)
        self.assertEqual([m["id"] for m in fake.mailboxes[f"{SID}:{RIGHT}"]], ["M1"])


class WaiterTest(StateTest):
    def waiter(self, pane=LEFT):
        return mc.Waiter(SID, pane)

    def test_user_prompt_marks_busy_without_serving(self):
        w = self.waiter()
        with mock.patch.object(w, "serve") as serve:
            self.assertEqual(w.run("UserPromptSubmit", ""), 0)
        serve.assert_not_called()
        self.assertTrue(w.busy())

    def test_compact_session_start_keeps_busy_mark(self):
        w = self.waiter()
        w.mark_busy()
        with mock.patch.object(w, "serve", return_value=0):
            w.run("SessionStart", "compact")
        self.assertTrue(w.busy())

    def test_stop_clears_busy_and_serves(self):
        w = self.waiter()
        w.mark_busy()
        with mock.patch.object(w, "serve", return_value=0) as serve:
            w.run("Stop", "")
        serve.assert_called_once()
        self.assertFalse(w.busy())

    def test_mail_wakes_claude_with_rendered_messages(self):
        chat = mc.compose("hello")
        fake = self.use(FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": chat},
                                                             {"id": "M2", "from": "S2:P9", "body": "ping"}]}))
        w = self.waiter()
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(w.run("Stop", ""), mc.WAKE)
        self.assertEqual(err.getvalue(), chat + "\n\n" + mc.render({"from": "S2:P9", "body": "ping"}) + "\n")
        self.assertEqual(fake.mailboxes[f"{SID}:{LEFT}"], [])
        self.assertTrue(w.busy())

    def test_failed_feedback_write_leaves_mail_unacked(self):
        # regression: the waiter acked before writing, so a closed hook pipe lost the message
        class Broken(io.StringIO):
            def __init__(self, fail):
                super().__init__()
                self.fail = fail

            def write(self, s):
                if self.fail == "write":
                    raise BrokenPipeError("pipe closed")
                return super().write(s)

            def flush(self):
                if self.fail == "flush":
                    raise BrokenPipeError("pipe closed")

        for fail in ("write", "flush"):
            with self.subTest(fail=fail):
                fake = self.use(FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": mc.compose("hello")}]}))
                w = self.waiter()
                with mock.patch("sys.stderr", Broken(fail)):
                    self.assertEqual(w.run("Stop", ""), 0)
                self.assertEqual([m["id"] for m in fake.mailboxes[f"{SID}:{LEFT}"]], ["M1"])
                self.assertFalse(w.busy())

    def test_claude_reads_as_listening_through_a_mail_woken_turn(self):
        # regression: the waiter's exit on wake made the peer report receiver none for that turn
        self.use(FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": "x"}]}))
        w = self.waiter()
        with mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(w.run("Stop", ""), mc.WAKE)
        self.assertTrue(w.listening())
        self.assertEqual(mc.receiver(SID, LEFT), "claude")

    def test_listening_ends_with_the_recorded_claude(self):
        w = self.waiter()
        mc.write_json(w.claude_path, {"pid": 999999})
        with mock.patch.object(mc, "pid_alive", side_effect=lambda pid: pid != 999999):
            self.assertFalse(w.listening())

    def test_every_hook_event_records_its_claude(self):
        w = self.waiter()
        with mock.patch.object(w, "serve", return_value=0):
            for event in ("SessionStart", "UserPromptSubmit", "Stop"):
                with self.subTest(event=event):
                    mc.remove(w.claude_path)
                    w.run(event, "")
                    self.assertEqual(mc.read_json(w.claude_path), {"pid": w.parent})

    def test_busy_turn_holds_mail_until_it_ends(self):
        self.use(FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": "x"}]}))
        w = self.waiter()
        w.mark_busy()
        sleeps = []

        def end_turn(seconds):
            sleeps.append(seconds)
            mc.remove(w.busy_path)

        with mock.patch.object(mc.time, "sleep", end_turn), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(w.serve(), mc.WAKE)
        self.assertEqual(sum(sleeps), w.BUSY_POLL_SECONDS)

    def test_waiter_exits_when_its_claude_is_gone(self):
        self.use(FakeRun())
        w = self.waiter()
        with mock.patch.object(mc.os, "getppid", return_value=w.parent + 1):
            self.assertEqual(w.serve(), 0)

    def test_claude_exit_during_wait_leaves_mail_in_mailbox(self):
        fake = self.use(FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": "x"}]}))
        w = self.waiter()
        parents = iter([w.parent])
        with mock.patch.object(mc.os, "getppid", side_effect=lambda: next(parents, w.parent + 1)):
            self.assertEqual(w.serve(), 0)
        self.assertEqual([m["id"] for m in fake.mailboxes[f"{SID}:{LEFT}"]], ["M1"])

    def test_second_waiter_for_a_served_claude_gives_up_after_the_handoff_wait(self):
        w = self.waiter()
        with open(w.lock_path, "a") as lock:
            mc.fcntl.flock(lock, mc.fcntl.LOCK_EX | mc.fcntl.LOCK_NB)
            mc.write_json(w.waiter_path, {"pid": 4242, "parent": w.parent})
            clock = iter([0, 1, 2, mc.Waiter.HANDOFF_SECONDS])
            with mock.patch.object(w, "loop") as loop, mock.patch.object(mc.time, "sleep") as sleep, \
                    mock.patch.object(mc.time, "monotonic", side_effect=lambda: next(clock)):
                self.assertEqual(w.serve(), 0)
        loop.assert_not_called()
        self.assertEqual(sleep.call_count, 2)

    def test_waiter_takes_over_once_the_old_one_frees_the_lock(self):
        # an in-place /restart keeps the claude pid, so its new waiter shares the old one's parent
        w = self.waiter()
        with open(w.lock_path, "a") as lock:
            mc.fcntl.flock(lock, mc.fcntl.LOCK_EX | mc.fcntl.LOCK_NB)
            mc.write_json(w.waiter_path, {"pid": 4242, "parent": w.parent})
            with mock.patch.object(w, "loop", return_value=0) as loop, \
                    mock.patch.object(mc.time, "sleep", side_effect=lambda _: mc.fcntl.flock(lock, mc.fcntl.LOCK_UN)):
                self.assertEqual(w.serve(), 0)
        loop.assert_called_once()

    def test_waiter_of_a_restarted_claude_waits_out_the_old_one(self):
        w = self.waiter()
        with open(w.lock_path, "a") as lock:
            mc.fcntl.flock(lock, mc.fcntl.LOCK_EX | mc.fcntl.LOCK_NB)
            mc.write_json(w.waiter_path, {"pid": 4242, "parent": w.parent + 1})

            def old_waiter_exits(_):
                mc.remove(w.waiter_path)
                mc.fcntl.flock(lock, mc.fcntl.LOCK_UN)

            with mock.patch.object(w, "loop", return_value=0) as loop, \
                    mock.patch.object(mc.time, "sleep", side_effect=old_waiter_exits):
                self.assertEqual(w.serve(), 0)
        loop.assert_called_once()
        self.assertFalse(os.path.exists(w.waiter_path))

    def test_waiter_gives_up_when_the_lock_never_frees(self):
        w = self.waiter()
        with open(w.lock_path, "a") as lock:
            mc.fcntl.flock(lock, mc.fcntl.LOCK_EX | mc.fcntl.LOCK_NB)
            mc.write_json(w.waiter_path, {"pid": 4242, "parent": w.parent + 1})
            clock = iter([0, 44, 45])
            with mock.patch.object(w, "loop") as loop, mock.patch.object(mc.time, "sleep") as sleep, \
                    mock.patch.object(mc.time, "monotonic", side_effect=lambda: next(clock)):
                self.assertEqual(w.serve(), 0)
        loop.assert_not_called()
        self.assertEqual(sleep.call_count, 1)

    def test_read_failure_never_wakes_claude(self):
        self.use(lambda args, timeout=30, stdin=None, alive=None: done(1, err="socket gone"))
        w = self.waiter()
        parents = iter([w.parent] * 5)
        with mock.patch.object(mc.time, "sleep"), \
                mock.patch.object(mc.os, "getppid", side_effect=lambda: next(parents, w.parent + 1)):
            self.assertEqual(w.run("Stop", ""), 0)
        with open(w.log_path, encoding="utf-8") as f:
            self.assertEqual(f.read().count("msg read failed: socket gone; retrying until agterm answers"), 1)

    def test_waiter_outlasts_an_agterm_restart(self):
        fake = FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": mc.compose("after restart")}]})
        outage = iter([done(1, err="connect failed: No such file or directory")] * 6
                      + [subprocess.TimeoutExpired("agtermctl", 45), OSError("agtermctl missing"), done(out="{")])

        gaps = [0.0]

        def restart(args, timeout=30, stdin=None, alive=None):
            if args[1:3] == ["msg", "read"]:
                gaps.append(0.0)
            step = next(outage, None)
            if isinstance(step, Exception):
                raise step
            return step or fake(args, timeout, stdin)

        def slept(seconds):
            gaps[-1] += seconds

        self.use(restart)
        w = self.waiter()
        err = io.StringIO()
        with mock.patch.object(mc.time, "sleep", slept), mock.patch("sys.stderr", err):
            self.assertEqual(w.run("Stop", ""), mc.WAKE)
        self.assertEqual(gaps[1:], [1, 2, 4, 8, 10, 10, 10, 10, 10, 0])
        self.assertEqual(err.getvalue(), mc.compose("after restart") + "\n")
        self.assertEqual(fake.mailboxes[f"{SID}:{LEFT}"], [])
        with open(w.log_path, encoding="utf-8") as f:
            log = f.read()
        self.assertEqual(log.count("retrying until agterm answers"), 1)
        self.assertIn("msg read works again", log)

    def test_claude_exit_during_an_outage_ends_the_waiter(self):
        self.use(lambda args, timeout=30, stdin=None, alive=None: done(1, err="connection refused"))
        w = self.waiter()
        parents = iter([w.parent])
        with mock.patch.object(mc.time, "sleep") as sleep, \
                mock.patch.object(mc.os, "getppid", side_effect=lambda: next(parents, w.parent + 1)):
            self.assertEqual(w.serve(), 0)
        sleep.assert_not_called()

    def test_closed_hook_pipe_cuts_the_backoff_short(self):
        self.use(lambda args, timeout=30, stdin=None, alive=None: done(1, err="connection refused"))
        w = self.waiter()
        sleeps = []
        parents = iter([w.parent] * 20)
        pipe = iter([True, True])
        with mock.patch.object(mc.time, "sleep", sleeps.append), \
                mock.patch.object(mc, "stderr_open", side_effect=lambda: next(pipe, False)), \
                mock.patch.object(mc.os, "getppid", side_effect=lambda: next(parents, w.parent + 1)):
            self.assertEqual(w.serve(), 0)
        self.assertEqual(sleeps, [mc.POLL_SECONDS])

    def test_closed_hook_pipe_cancels_a_blocked_read(self):
        stub = Path(self.tmp.name) / "agtermctl"
        stub.write_text("#!/bin/sh\nexec sleep 5\n")
        stub.chmod(0o755)
        w = self.waiter()
        hangup = time.monotonic() + 0.3
        start = time.monotonic()
        with mock.patch.object(mc, "AGTERMCTL", str(stub)), \
                mock.patch.object(mc, "stderr_open", side_effect=lambda: time.monotonic() < hangup):
            self.assertEqual(w.serve(), 0)
        self.assertLess(time.monotonic() - start, 2)

    def test_stderr_open_sees_a_closed_reader(self):
        r, wfd = os.pipe()
        with os.fdopen(wfd, "w") as pipe, mock.patch("sys.stderr", pipe):
            self.assertTrue(mc.stderr_open())
            os.close(r)
            self.assertFalse(mc.stderr_open())

    def test_claude_exit_during_a_failing_ack_leaves_no_busy_mark(self):
        for dies_after, attempts in (("sleep", 1), ("ack", 3)):
            with self.subTest(dies_after=dies_after):
                fake = FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": mc.compose("hello")}]})
                acks = []
                dead = []

                def no_ack(args, timeout=30, stdin=None, alive=None, fake=fake, acks=acks, dead=dead, dies_after=dies_after):
                    if args[1:3] == ["msg", "ack"]:
                        acks.append(1)
                        if dies_after == "ack" and len(acks) == 3:
                            dead.append(1)
                        return done(1, err="timed out")
                    return fake(args, timeout, stdin)

                def sleep(_, dead=dead, dies_after=dies_after):
                    if dies_after == "sleep":
                        dead.append(1)

                self.use(no_ack)
                w = self.waiter()
                with mock.patch.object(mc.time, "sleep", sleep), mock.patch("sys.stderr", io.StringIO()), \
                        mock.patch.object(mc.os, "getppid", side_effect=lambda w=w, dead=dead: w.parent + len(dead)):
                    self.assertEqual(w.serve(), 0)
                self.assertEqual(len(acks), attempts)
                self.assertFalse(w.busy())
                self.assertEqual([m["id"] for m in fake.mailboxes[f"{SID}:{LEFT}"]], ["M1"])

    def test_watched_run_never_starts_a_command_once_claude_is_gone(self):
        with mock.patch.object(mc.subprocess, "Popen") as popen, self.assertRaises(mc.Gone):
            mc.run(["agtermctl", "msg", "ack"], alive=lambda: False)
        popen.assert_not_called()

    def test_failed_ack_still_wakes_claude_once(self):
        for failure in (done(1, err="connection refused"), subprocess.TimeoutExpired("agtermctl", 30)):
            with self.subTest(failure=type(failure).__name__):
                fake = FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": mc.compose("hello")}]})
                acks = []

                def flaky_ack(args, timeout=30, stdin=None, alive=None, fake=fake, acks=acks, failure=failure):
                    if args[1:3] == ["msg", "ack"]:
                        acks.append(1)
                        if len(acks) == 1:
                            if isinstance(failure, Exception):
                                raise failure
                            return failure
                    return fake(args, timeout, stdin)

                self.use(flaky_ack)
                w = self.waiter()
                err = io.StringIO()
                with mock.patch.object(mc.time, "sleep"), mock.patch("sys.stderr", err):
                    self.assertEqual(w.run("Stop", ""), mc.WAKE)
                self.assertEqual(err.getvalue(), mc.compose("hello") + "\n")
                self.assertEqual(len(acks), 2)
                self.assertEqual(fake.mailboxes[f"{SID}:{LEFT}"], [])
                mc.remove(w.busy_path)

    def test_ack_that_never_succeeds_wakes_claude_and_keeps_the_mail(self):
        fake = FakeRun(mailboxes={f"{SID}:{LEFT}": [{"id": "M1", "body": mc.compose("hello")}]})

        def no_ack(args, timeout=30, stdin=None, alive=None):
            if args[1:3] == ["msg", "ack"]:
                return done(1, err="connection refused")
            return fake(args, timeout, stdin)

        self.use(no_ack)
        w = self.waiter()
        with mock.patch.object(mc.time, "sleep"), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(w.run("Stop", ""), mc.WAKE)
        self.assertTrue(w.busy())
        self.assertEqual([m["id"] for m in fake.mailboxes[f"{SID}:{LEFT}"]], ["M1"])
        with open(w.log_path, encoding="utf-8") as f:
            self.assertIn("msg ack failed 3 times, waking Claude anyway", f.read())

    def test_headless_claude_never_runs_the_waiter(self):
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"}), \
                mock.patch.object(mc, "Waiter") as waiter:
            self.assertEqual(mc.claude_hook(), 0)
        waiter.assert_not_called()


class CodexHookTest(StateTest):
    def hook(self, event, pid=4242, exec_run=False, daemon=False):
        with mock.patch("sys.stdin", io.StringIO(json.dumps(event))), \
                mock.patch.object(mc, "find_codex_pid", return_value=pid), \
                mock.patch.object(mc, "is_codex_exec", return_value=exec_run), \
                mock.patch.object(mc, "is_codex_daemon", return_value=daemon), \
                mock.patch.object(mc, "executable_path", return_value="/opt/codex/bin/codex"), \
                mock.patch.object(mc.subprocess, "Popen") as popen:
            self.assertEqual(mc.codex_hook(), 0)
        return popen

    def test_interactive_codex_registers_and_delivers(self):
        popen = self.hook({"session_id": "T7", "transcript_path": "/r/T7.jsonl"})
        self.assertEqual(mc.read_json(mc.state_path(f"codex-{LEFT}.json")),
                         {"session": SID, "thread": "T7", "pid": 4242, "codex": "/opt/codex/bin/codex"})
        self.assertEqual(popen.call_args.args[0][-1], "deliver")
        self.assertEqual(popen.call_args.kwargs["stdout"].name, mc.state_path(f"codex-{LEFT}.log"))
        self.assertEqual(popen.call_args.kwargs["stderr"], mc.subprocess.STDOUT)

    def test_codex_exec_and_missing_thread_do_not_register(self):
        started = {"session_id": "T7", "transcript_path": "/r/T7.jsonl"}
        for event, pid, exec_run in ((started, 4242, True), ({}, 4242, False), (started, None, False)):
            with self.subTest(event=event, pid=pid, exec_run=exec_run):
                popen = self.hook(event, pid, exec_run)
                self.assertIsNone(mc.read_json(mc.state_path(f"codex-{LEFT}.json")))
                popen.assert_not_called()

    def test_codex_daemon_start_does_not_register(self):
        popen = self.hook({"session_id": "T7", "transcript_path": "/r/T7.jsonl"}, daemon=True)
        self.assertIsNone(mc.read_json(mc.state_path(f"codex-{LEFT}.json")))
        popen.assert_not_called()

    def test_start_without_transcript_keeps_the_registered_thread(self):
        # regression: codex's background memory session starts with no transcript and took the pane's thread
        self.hook({"session_id": "T7", "transcript_path": "/r/T7.jsonl"})
        for transcript in (None, ""):
            with self.subTest(transcript=transcript):
                popen = self.hook({"session_id": "MEM", "transcript_path": transcript})
                self.assertEqual(mc.read_json(mc.state_path(f"codex-{LEFT}.json"))["thread"], "T7")
                popen.assert_not_called()
        self.hook({"session_id": "T8", "transcript_path": "/r/T8.jsonl"})
        self.assertEqual(mc.read_json(mc.state_path(f"codex-{LEFT}.json"))["thread"], "T8")

    def test_codex_subcommand_skips_global_options(self):
        cases = [(["codex"], ""), (["codex", "--no-daemon"], ""), (["codex", "-m", "gpt", "exec", "x"], "exec"),
                 (["codex", "-c", "a=b", "--no-daemon", "e"], "e"), (["codex", "--no-daemon", "fix it"], "fix it")]
        for argv, want in cases:
            with self.subTest(argv=argv):
                self.assertEqual(mc.codex_subcommand(argv), want)

    def test_codex_daemon_is_the_app_server_subcommand(self):
        cases = [(["codex", "-c", "features.code_mode_host=true", "app-server", "--listen", "unix://"], True),
                 (["codex", "app-server", "--listen", "unix://", "--managed-daemon"], True),
                 (["codex", "--no-daemon"], False), (["codex", "exec", "x"], False), (None, False)]
        for argv, want in cases:
            with self.subTest(argv=argv), mock.patch.object(mc, "process_argv", return_value=argv):
                self.assertEqual(mc.is_codex_daemon(4242), want)


if __name__ == "__main__":
    unittest.main()

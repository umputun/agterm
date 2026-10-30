#!/usr/bin/env python3
"""Regression checks for named-companion."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_SPEC = importlib.util.spec_from_file_location("companion", Path(__file__).with_name("companion.py"))
companion = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(companion)

TREE = {"result": {"tree": {"workspaces": [{"sessions": [
    {"id": "AAA-1", "name": "api"}, {"id": "BBB-2", "name": "web"}]}]}}}


def answer(text):
    return json.dumps({"result": "answered", "id": "ok", "label": "OK", "index": 0, "text": text})


class FakeCtl:
    def __init__(self, typed, ask_rc=0):
        self.typed, self.ask_rc, self.calls = typed, ask_rc, []

    def __call__(self, cmd, **_):
        self.calls.append(cmd)
        args = cmd[1:]
        out = ""
        if args[0] == "ask":
            out = answer(self.typed) if self.ask_rc == 0 else ""
            return subprocess.CompletedProcess(cmd, self.ask_rc, out, "")
        if args[:2] == ["session", "duplicate"]:
            out = json.dumps({"result": {"id": "ccc-3", "parent": "AAA-1"}})
        if args[0] == "tree":
            out = json.dumps(TREE)
        return subprocess.CompletedProcess(cmd, 0, out, "")

    def find(self, *prefix):
        return [c[1:] for c in self.calls if c[1:1 + len(prefix)] == list(prefix)]


class AskedNameTests(unittest.TestCase):
    def test_asked_name(self):
        cases = [
            ("typed name trimmed", 0, answer("  logs "), "logs"),
            ("blank name", 0, answer(""), ""),
            ("escaped json", 0, json.dumps({"result": "escaped"}), None),
            ("other button", 0, json.dumps({"result": "answered", "id": "cancel"}), None),
            ("esc exit", 3, "", None),
            ("cancel exit", 2, "", None),
        ]
        for name, rc, out, want in cases:
            with self.subTest(name):
                self.assertEqual(companion.asked_name(rc, out), want)

    def test_asked_name_without_dialog(self):
        with self.assertRaises(companion.Fail):
            companion.asked_name(1, "error: no window")


class SessionNameTests(unittest.TestCase):
    def test_session_name(self):
        self.assertEqual(companion.session_name(TREE, "bbb-2"), "web")
        with self.assertRaises(companion.Fail):
            companion.session_name(TREE, "CCC-3")


class AgtTests(unittest.TestCase):
    def test_agt_socket(self):
        cases = [("socket set", "/tmp/a.sock", ["--socket", "/tmp/a.sock"]), ("socket unset", "", [])]
        for name, socket, tail in cases:
            with self.subTest(name), patch.dict(os.environ, {"AGT_SOCKET": socket}), \
                    patch.object(companion.subprocess, "run") as run:
                companion.agt("tree", "--json")
                self.assertEqual(run.call_args.args[0], [companion.AGTERMCTL, "tree", "--json", *tail])


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        markers = Path(self.tmp.name) / "names"
        env = {"AGT_SESSION_ID": "BBB-2", "AGT_WINDOW_ID": "W1", "AGT_SOCKET": ""}
        for p in (patch.object(companion, "MARKERS", markers), patch.dict(os.environ, env)):
            p.start()
            self.addCleanup(p.stop)
        self.markers = markers

    def run_with(self, ctl):
        with patch.object(companion.subprocess, "run", ctl):
            companion.run()

    def test_typed_name_renames_without_marker(self):
        ctl = FakeCtl("logs")
        self.run_with(ctl)
        self.assertEqual(ctl.find("session", "rename"), [["session", "rename", "logs", "--target", "ccc-3"]])
        self.assertEqual(ctl.find("session", "tint"),
                         [["session", "tint", "gray", "--on", "icon,name", "--target", "ccc-3"]])
        self.assertEqual(ctl.find("tree"), [])
        self.assertFalse(self.markers.exists())

    def test_blank_name_takes_parent_name_and_leaves_marker(self):
        ctl = FakeCtl("")
        self.run_with(ctl)
        self.assertEqual(ctl.find("session", "rename"), [["session", "rename", "api", "--target", "ccc-3"]])
        self.assertEqual((self.markers / "CCC-3").read_text(), "api")

    def test_dismissed_dialog_creates_nothing(self):
        ctl = FakeCtl("", ask_rc=3)
        self.run_with(ctl)
        self.assertEqual(ctl.find("session"), [])
        self.assertFalse(self.markers.exists())

    def test_without_session(self):
        with patch.dict(os.environ, {"AGT_SESSION_ID": ""}), self.assertRaises(companion.Fail):
            self.run_with(FakeCtl("logs"))


if __name__ == "__main__":
    unittest.main()

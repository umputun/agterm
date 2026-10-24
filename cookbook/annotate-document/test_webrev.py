#!/usr/bin/env python3
"""Regression checks for webrev.py."""

import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("webrev", Path(__file__).parent / "scripts" / "webrev.py")
webrev = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webrev)
PageData = webrev.PageData
ReviewOptions = webrev.ReviewOptions


def done(rc: int = 0, out: str = "", err: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], rc, out, err)


def doc_data(page: str) -> dict:
    return json.loads(page.split('id="doc-data">', 1)[1].split("</script>", 1)[0])


class TestPage(unittest.TestCase):
    def test_build_page_keeps_script_close_inert(self) -> None:
        page = webrev.build_page(PageData("doc.md", "markdown", "a </script><script>alert(1)</script>\n", "n1"))
        data = page.split('id="doc-data">', 1)[1].split("</script>", 1)[0]
        self.assertNotIn("<", data)
        self.assertEqual(json.loads(data)["source"], "a </script><script>alert(1)</script>\n")

    def test_build_page_keeps_placeholder_text_in_document(self) -> None:
        # regression: a document holding a library placeholder had library code spliced into its json
        src = "a /*__WEBREV_HIGHLIGHT__*/ b /*__WEBREV_MARKDOWN_IT__*/ c __WEBREV_TITLE__"
        self.assertEqual(doc_data(webrev.build_page(PageData("page.html", "text", src, "n1")))["source"], src)

    def test_build_page_uses_given_title(self) -> None:
        page = webrev.build_page(PageData("/tmp/x/pr.md", "markdown", "x", "n1", title="PR #12 <draft>"))
        self.assertIn("<title>PR #12 &lt;draft&gt;</title>", page)
        self.assertEqual(doc_data(page)["path"], "/tmp/x/pr.md")

    def test_build_page_escapes_title(self) -> None:
        self.assertIn("<title>&lt;b&gt;.md</title>", webrev.build_page(PageData("dir/<b>.md", "text", "x", "n1")))

    def test_build_page_inlines_library(self) -> None:
        page = webrev.build_page(PageData("a.md", "markdown", "x", "n1"))
        self.assertNotIn("__WEBREV_", page)
        self.assertIn("markdown-it 14.1.0", page)
        self.assertIn("Highlight.js v11.11.1", page)

    def test_build_page_sets_style(self) -> None:
        page = webrev.build_page(PageData("a.md", "markdown", "x", "n1", style="terminal"))
        self.assertIn('<html data-style="terminal">', page)
        self.assertIn('<html data-style="">', webrev.build_page(PageData("a.md", "markdown", "x", "n1")))

    def test_page_style(self) -> None:
        for env, want in (({}, ""), ({"WEBREV_STYLE": ""}, ""), ({"WEBREV_STYLE": "terminal"}, "terminal")):
            with mock.patch.dict(os.environ, env, clear=True):
                self.assertEqual(webrev.page_style(), want)
        with mock.patch.dict(os.environ, {"WEBREV_STYLE": "Terminal"}), self.assertRaises(ValueError):
            webrev.page_style()

    def test_display_path(self) -> None:
        self.assertEqual(webrev.display_path(Path.cwd() / "docs" / "a.md"), "docs/a.md")
        self.assertEqual(webrev.display_path(Path("/nonexistent-webrev/a.md")), "/nonexistent-webrev/a.md")

    def test_sidebar_shift(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "settings.json"
            cases = [('{"sidebarBackgroundShift": 7}', 0.12), ('{"sidebarBackgroundShift": 2}', -0.18),
                     ('{"sidebarBackgroundShift": 40}', 0.30), ("{}", 0.0), ("not json", 0.0), ("[1]", 0.0)]
            for body, want in cases:
                f.write_text(body)
                self.assertAlmostEqual(webrev.sidebar_shift(f), want)
            self.assertEqual(webrev.sidebar_shift(Path(d) / "missing.json"), 0.0)


class TestOutcome(unittest.TestCase):
    def test_write_backup(self) -> None:
        cases = [("pending", "ABC-1", "pending ABC-1\n"), ("dismissed", "", "dismissed\n"),
                 ("submitted", "## a.md:1 ( )\nfix\n", "## a.md:1 ( )\nfix\n"), ("submitted", "", "")]
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "out.md"
            for state, text, want in cases:
                webrev.write_backup(f, state, text)
                self.assertEqual(f.read_text(), want)
            self.assertEqual(sorted(x.name for x in Path(d).iterdir()), ["out.md"])

    def test_read_outcome(self) -> None:
        cases = [
            (0, '{"outcome":"submitted","value":"## a.md:1 ( )\\nx\\n"}', "", ("submitted", "## a.md:1 ( )\nx\n")),
            (0, '{"outcome":"submitted","value":""}', "", ("submitted", "")),
            (2, '{"outcome":"dismissed"}', "", ("dismissed", "")),
            (1, '{"outcome":"pending"}', "", ("pending", "")),
            (1, "", "error: no such page", ("error", "error: no such page")),
            (0, '{"outcome":"weird"}', "", ("error", 'unexpected outcome: {"outcome":"weird"}')),
        ]
        for rc, out, err, want in cases:
            with mock.patch.object(webrev, "agtermctl", return_value=done(rc, out, err)):
                self.assertEqual(webrev.read_outcome("id"), want)

    def test_wait_outcome_blinks_then_restores(self) -> None:
        pending = done(1, '{"outcome":"pending"}')
        submitted = done(0, '{"outcome":"submitted","value":""}')
        cases = (("right", {}, ["--pane", "right"]), ("", {}, []), ("bogus", {}, []),
                 ("right", {"AGTERM_PANE_ID": "P1"}, ["--pane", "right", "--pane-id", "P1"]),
                 ("", {"AGTERM_PANE_ID": "P1"}, ["--pane-id", "P1"]), ("", {"AGTERM_PANE_ID": ""}, []))
        for pane, env, want in cases:
            with mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.object(webrev, "agtermctl", side_effect=[done(), pending, submitted, done()]) as m, \
                    mock.patch("time.sleep"):
                self.assertEqual(webrev.wait_outcome("id", "S", pane), ("submitted", ""))
            calls = [c.args for c in m.call_args_list]
            self.assertEqual(calls[0], ("session", "status", "blocked", "--blink", "--target", "S", *want))
            self.assertEqual(calls[-1], ("session", "status", "idle", "--target", "S", *want))

    def test_wait_outcome_restores_on_interrupt(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(webrev, "agtermctl", side_effect=[done(), KeyboardInterrupt, done()]) as m, \
                self.assertRaises(KeyboardInterrupt):
            webrev.wait_outcome("id", "S", "")
        self.assertEqual(m.call_args_list[-1].args, ("session", "status", "idle", "--target", "S"))

    def test_wait_outcome_restores_on_sigterm(self) -> None:
        before = signal.getsignal(signal.SIGTERM)

        def ctl(*args: str) -> subprocess.CompletedProcess[str]:
            if args[1] == "overlay":
                os.kill(os.getpid(), signal.SIGTERM)
                return done(1, '{"outcome":"pending"}')
            return done()

        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(webrev, "agtermctl", side_effect=ctl) as m, \
                mock.patch("time.sleep"), self.assertRaises(SystemExit) as e:
            webrev.wait_outcome("id", "S", "left")
        self.assertEqual(e.exception.code, 143)
        self.assertEqual(m.call_args_list[-1].args, ("session", "status", "idle", "--target", "S", "--pane", "left"))
        self.assertIs(signal.getsignal(signal.SIGTERM), before)


class TestControl(unittest.TestCase):
    def test_agtermctl_command(self) -> None:
        cases = [
            ({}, ["agtermctl", "tree", "--json"]),
            ({"AGTERMCTL": "", "AGTERM_SOCKET": ""}, ["agtermctl", "tree", "--json"]),
            ({"AGTERMCTL": "/opt/bin/agtermctl"}, ["/opt/bin/agtermctl", "tree", "--json"]),
            ({"AGTERM_SOCKET": "/tmp/a.sock"}, ["agtermctl", "tree", "--json", "--socket", "/tmp/a.sock"]),
        ]
        for env, want in cases:
            with mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch("subprocess.run", return_value=done()) as run:
                webrev.agtermctl("tree", "--json")
            self.assertEqual(run.call_args.args[0], want, env)

    def test_page_zoom(self) -> None:
        tree = {"windows": [{"sessions": [{"htmlOverlays": [{"id": "other", "zoom": 2}, {"id": "P", "zoom": 1.25}]}]}]}
        cases = ((json.dumps(tree), 1.25), (json.dumps({"windows": []}), 1.0), ("not json", 1.0),
                 (json.dumps({"htmlOverlays": [{"id": "P"}]}), 1.0), (json.dumps({"htmlOverlays": [{"id": "P", "zoom": "2"}]}), 1.0))
        for out, want in cases:
            with mock.patch.object(webrev, "agtermctl", return_value=done(0, out)):
                self.assertEqual(webrev.page_zoom("P"), want, out)

    def test_page_zoom_scopes_tree_to_window(self) -> None:
        for env, want in (({"AGTERM_WINDOW_ID": "W1"}, ("tree", "--json", "--window", "W1")),
                          ({"AGTERM_WINDOW_ID": ""}, ("tree", "--json")), ({}, ("tree", "--json"))):
            with mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.object(webrev, "agtermctl", return_value=done(0, "{}")) as m:
                webrev.page_zoom("P")
            self.assertEqual(m.call_args.args, want, env)

    def test_zoom_fit(self) -> None:
        cases = ((1.0, None), (0.0, None), (1.5, ["--width", "1263", "--height", "255"]), (0.8, ["--width", "674", "--height", "136"]))
        for zoom, want in cases:
            with mock.patch.object(webrev, "page_zoom", return_value=zoom), \
                    mock.patch.object(webrev, "agtermctl", return_value=done()) as m:
                webrev.zoom_fit("P", "S", 842, 170)
            if want is None:
                m.assert_not_called()
                continue
            args = list(m.call_args.args)
            self.assertEqual(args[:5], ["session", "overlay", "resize", "--size-percent", "95"])
            self.assertEqual(args[5:9], want)
            self.assertEqual(args[9:], ["--target", "S"])


class TestReview(unittest.TestCase):
    def test_size_percent(self) -> None:
        self.assertEqual(webrev.size_percent("60"), 60)
        self.assertEqual(webrev.size_percent("1"), 1)
        for bad in ("0", "101"):
            with self.assertRaises(argparse.ArgumentTypeError):
                webrev.size_percent(bad)
        with self.assertRaises(ValueError):
            webrev.size_percent("big")

    def test_review_open_args(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            doc = Path(d) / "a.md"
            doc.write_text("x\n", encoding="utf-8")
            for pane, has, lacks in (("right", ["--pane", "right"], "--size-percent"), (None, ["--size-percent", "60"], "--pane")):
                with mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": "S"}), \
                        mock.patch.object(webrev, "agtermctl", return_value=done(1, "", "boom")) as m:
                    self.assertEqual(webrev.review(doc, ReviewOptions(pane, None, "", 60)), 1)
                args = list(m.call_args.args)
                i = args.index(has[0])
                self.assertEqual(args[i:i + 2], has)
                self.assertNotIn(lacks, args)

    def test_review_open_args_fit(self) -> None:
        cases = (("draft.txt", "fix(x): subject\n\nbody line\n", ["--width", "842", "--height", "170"]),
                 ("comment.md", "short note\n", ["--width", "674", "--height", "132"]))
        with tempfile.TemporaryDirectory() as d:
            for name, body, want in cases:
                doc = Path(d) / name
                doc.write_text(body, encoding="utf-8")
                with mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": "S"}), \
                        mock.patch.object(webrev, "agtermctl", return_value=done(1, "", "boom")) as m:
                    self.assertEqual(webrev.review(doc, ReviewOptions(fit=True)), 1)
                args = list(m.call_args.args)
                i = args.index("--size-percent")
                self.assertEqual(args[i:i + 6], ["--size-percent", "95", *want])
                self.assertNotIn("--pane", args)

    def test_fit_rows(self) -> None:
        cases = [("", 80, 1), ("a", 80, 1), ("a\n", 80, 1), ("a\n\n", 80, 2), ("a\n\nb\n", 80, 3),
                 ("x" * 80 + "\n", 80, 1), ("x" * 81 + "\n", 80, 2), ("x" * 161, 80, 3), ("a\r\nb\r\n", 80, 2),
                 ("x" * 150, 100, 2), ("x" * 150, 60, 3)]
        for src, cols, want in cases:
            self.assertEqual(webrev.fit_rows(src, cols), want, repr((src, cols)))

    def test_fit_columns(self) -> None:
        cases = [("text", "x" * 200, 80), ("text", "short\n", 80), ("markdown", "short\n", 60),
                 ("markdown", "x" * 72 + "\nshort\n", 72), ("markdown", "x" * 400 + "\n", 100), ("markdown", "", 60)]
        for kind, src, want in cases:
            self.assertEqual(webrev.fit_columns(src, kind), want, repr((kind, src[:10])))

    def test_fit_size(self) -> None:
        self.assertEqual(webrev.fit_size("a\n", "text"), (842, 132))
        self.assertEqual(webrev.fit_size("a\n\nb\n", "text"), (842, 170))
        self.assertEqual(webrev.fit_size("short\n", "markdown"), (674, 132))
        self.assertEqual(webrev.fit_size("x" * 250 + "\n\nend\n", "markdown"), (1010, 208))

    def test_review_fit_rescales_after_open(self) -> None:
        opened = done(0, json.dumps({"result": {"pageID": "P"}}))
        with tempfile.TemporaryDirectory() as d:
            doc = Path(d) / "draft.txt"
            doc.write_text("fix(x): subject\n\nbody line\n", encoding="utf-8")
            for fit, calls in ((True, [mock.call("P", "S", 842, 170)]), (False, [])):
                with mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": "S"}), \
                        mock.patch.object(webrev, "agtermctl", return_value=opened), \
                        mock.patch.object(webrev, "wait_outcome", return_value=("dismissed", "")), \
                        mock.patch.object(webrev, "zoom_fit") as z:
                    self.assertEqual(webrev.review(doc, ReviewOptions(fit=fit)), 2)
                self.assertEqual(z.call_args_list, calls)

    def test_review_writes_backup(self) -> None:
        opened = done(0, json.dumps({"result": {"pageID": "P"}}))
        cases = ((("submitted", "## a.md:1 ( )\nx\n"), "## a.md:1 ( )\nx\n"), (("submitted", ""), ""),
                 (("dismissed", ""), "dismissed\n"), (("error", "boom"), "pending P\n"))
        with tempfile.TemporaryDirectory() as d:
            doc = Path(d) / "a.md"
            doc.write_text("x\n", encoding="utf-8")
            for outcome, want in cases:
                out = Path(d) / "result"
                out.unlink(missing_ok=True)
                seen = []

                def wait(*_: str, out: Path = out, seen: list = seen, outcome: tuple = outcome) -> tuple[str, str]:
                    seen.append(out.read_text())
                    return outcome

                with mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": "S"}), \
                        mock.patch.object(webrev, "agtermctl", return_value=opened), \
                        mock.patch.object(webrev, "wait_outcome", side_effect=wait), mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                    webrev.review(doc, ReviewOptions(output=out))
                self.assertEqual(seen, ["pending P\n"], outcome)
                self.assertEqual(out.read_text(), want, outcome)

    def test_main_usage_errors_exit_1(self) -> None:
        for argv in (["review", "a.md", "--size", "0"], ["review", "a.md", "--size", "abc"], ["review", "a.md", "--bogus"],
                     ["review", "a.md", "--pane", "top"], ["review"], []):
            with mock.patch.object(sys, "argv", ["webrev.py", *argv]), mock.patch("sys.stderr"), \
                    mock.patch.object(webrev, "review") as m, self.assertRaises(SystemExit) as e:
                webrev.main()
            self.assertEqual(e.exception.code, 1, argv)
            m.assert_not_called()

    def test_main_refuses_fit_with_size_or_pane(self) -> None:
        for extra in (["--size", "60"], ["--size", "95"], ["--pane", "right"]):
            with mock.patch.object(sys, "argv", ["webrev.py", "review", "draft.txt", "--fit", *extra]), \
                    mock.patch("sys.stderr"), mock.patch.object(webrev, "review") as m:
                self.assertEqual(webrev.main(), 1)
            m.assert_not_called()
        for argv, want in ((["--fit"], ReviewOptions(fit=True)), (["--size", "60"], ReviewOptions(size=60)),
                           ([], ReviewOptions())):
            with mock.patch.object(sys, "argv", ["webrev.py", "review", "draft.txt", *argv]), \
                    mock.patch.object(webrev, "review", return_value=0) as m:
                self.assertEqual(webrev.main(), 0)
            self.assertEqual(m.call_args.args[1], want)


if __name__ == "__main__":
    unittest.main()

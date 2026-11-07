#!/usr/bin/env python3
"""Regression checks for combined sidebar Git snapshots."""

from __future__ import annotations

import fcntl
import importlib.util
import io
import json
import multiprocessing
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import tomllib

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("git_info", ROOT / "git-info.py")
if SPEC is None or SPEC.loader is None:
    raise ImportError("cannot load Git-info script")
GI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GI)


def overlap_worker(settings, control):
    os.environ["AGTERM_PANE_ID"] = settings["pane"]
    real_lock = GI.fcntl.flock

    def lock(file, operation):
        if settings["gate"] == "contender":
            control.send("locking")
        return real_lock(file, operation)

    def snapshot(cwd):
        if settings["gate"] == "snapshot":
            control.send("snapshot")
            if control.recv() != "release":
                raise AssertionError("unexpected barrier response")
        branch = "main" if Path(cwd).name == "left" else "peer"
        return cwd, branch + " ✓ clean local only"

    def run(args):
        if args[0] == "ps":
            return "codex" if args[2] == "101" else "claude"
        if args[:3] != ["agtermctl", "session", "info"]:
            raise AssertionError(args)
        if settings["gate"] == "publish":
            control.send("publish")
            if control.recv() != "release":
                raise AssertionError("unexpected barrier response")
        with Path(settings["directory"], "published.jsonl").open("a") as output:
            output.write(json.dumps(args[3]) + "\n")
        return "ok"

    try:
        with (
            mock.patch.object(GI.tempfile, "gettempdir", return_value=settings["directory"]),
            mock.patch.object(GI, "session_node", return_value=settings["node"]),
            mock.patch.object(GI, "run", side_effect=run),
            mock.patch.object(GI, "snapshot", side_effect=snapshot),
            mock.patch.object(GI.fcntl, "flock", side_effect=lock),
        ):
            pid, agent = (101, "codex") if settings["pane"] == "LEFT" else (102, "claude")
            GI.refresh(settings["event"], pid, agent)
        control.send("done")
    except (
        OSError,
        ValueError,
        AssertionError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as error:
        control.send(("error", str(error)))
    finally:
        control.close()


class GitInfoTest(unittest.TestCase):
    def test_both_agents_register_the_same_lifecycle_writer(self) -> None:
        command = 'python3 "$HOME/.local/bin/agterm-git-info.py"'
        claude = json.loads((ROOT / "claude-hooks.json").read_text())
        codex = tomllib.loads((ROOT / "codex-hooks.toml").read_text())
        for config in (claude, codex):
            for event in ("SessionStart", "PostToolUse", "Stop", "SessionEnd"):
                matches = [
                    hook
                    for group in config["hooks"][event]
                    for hook in group["hooks"]
                    if hook["command"] == command
                ]
                self.assertEqual(len(matches), 1, event)
                self.assertFalse(matches[0].get("async", False))

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = mock.patch.dict(
            os.environ,
            {
                "AGTERM_SESSION_ID": "SESSION",
                "AGTERM_PANE_ID": "LEFT",
                "AGTERM_SOCKET": "/test/socket",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
            },
            clear=True,
        )
        # Keep only the executable search path from the invoking environment.
        path = os.environ["PATH"]
        self.env.start()
        os.environ["PATH"] = path
        self.addCleanup(self.env.stop)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git(self.repo, "init")
        self.git(self.repo, "symbolic-ref", "HEAD", "refs/heads/main")
        (self.repo / "file").write_text("base\n")
        (self.repo / "subdir").mkdir()
        (self.repo / "subdir/tracked").write_text("base\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "base")

    @staticmethod
    def git(repo: Path, *args: str) -> str:
        return GI.run([
            "git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "-c",
            "commit.gpgsign=false",
            "-C",
            str(repo),
            *args,
        ])

    def test_status_counts_rename_once_and_handles_newline_paths(self) -> None:
        self.git(self.repo, "mv", "file", "renamed\nfile")
        (self.repo / "untracked\nfile").write_text("new\n")
        root, line = GI.snapshot(str(self.repo / "subdir"))
        self.assertEqual(root, str(self.repo.resolve()))
        self.assertEqual(line, "main ● 2 local only")
        self.assertFalse((self.repo / ".git/index.lock").exists())

    def test_upstream_divergence_detached_and_unborn(self) -> None:
        self.git(self.repo, "branch", "upstream")
        self.git(self.repo, "branch", "--set-upstream-to=upstream")
        (self.repo / "file").write_text("local\n")
        self.git(self.repo, "commit", "-am", "local")
        self.git(self.repo, "checkout", "upstream")
        (self.repo / "file").write_text("other\n")
        self.git(self.repo, "commit", "-am", "other")
        self.git(self.repo, "checkout", "main")
        self.assertEqual(GI.snapshot(str(self.repo))[1], "main ✓ clean ↑1 ↓1")
        self.git(self.repo, "checkout", "--detach")
        oid = self.git(self.repo, "rev-parse", "--short=7", "HEAD").strip()
        self.assertEqual(GI.snapshot(str(self.repo))[1], oid + " detached ✓ clean")
        unborn = self.root / "unborn"
        unborn.mkdir()
        self.git(unborn, "init")
        self.git(unborn, "symbolic-ref", "HEAD", "refs/heads/spike")
        self.assertEqual(GI.snapshot(str(unborn))[1], "spike ✓ clean local only")
        self.assertIsNone(GI.snapshot(str(self.root)))

    def test_names_remain_plain_and_byte_bounded(self) -> None:
        name = "bad`]branch_" + "界" * 40
        self.git(self.repo, "checkout", "-b", name)
        line = GI.snapshot(str(self.repo))[1]
        self.assertTrue(line.startswith("bad`]branch_"))
        self.assertLessEqual(len(line.encode()), 110)
        self.assertEqual(GI.plain("line\n\t\u202ename", 50), "linename")

    def test_owner_rejects_nested_agents_and_unreadable_ancestry(self) -> None:
        with mock.patch.object(GI.os, "getppid", return_value=100):
            with mock.patch.object(GI, "run", side_effect=["99 sh", "90 codex", "1 agterm"]):
                self.assertEqual(GI.owner(), (99, "codex"))
            with mock.patch.object(
                GI,
                "run",
                side_effect=[
                    "99 sh",
                    "98 claude",
                    "97 sh",
                    "90 codex",
                    "1 agterm",
                ],
            ):
                self.assertIsNone(GI.owner())

    def test_combined_panes_deduplicate_and_exit_preserves_peer(self) -> None:
        self.exercise_panes(different=False)

    def test_different_worktrees_stay_distinct(self) -> None:
        self.exercise_panes(different=True)

    def test_hard_killed_process_is_pruned_on_surviving_pane_refresh(self) -> None:
        peer = self.root / "other"
        self.git(self.repo, "worktree", "add", "-b", "peer", str(peer))
        processes = [
            subprocess.Popen(
                [sys.executable, "-c", "import sys; sys.stdin.buffer.read(1)"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for _ in range(2)
        ]

        def cleanup():
            for process in processes:
                process.stdin.close()
                process.wait()

        self.addCleanup(cleanup)
        names = [
            Path(GI.run(["ps", "-p", str(p.pid), "-o", "comm="]).strip()).name for p in processes
        ]
        node = {
            "surfaces": [{"paneID": "LEFT", "kind": "left"}, {"paneID": "RIGHT", "kind": "right"}]
        }
        published = []
        original_run = GI.run

        def run(args):
            if args[0] == "agtermctl":
                published.append(args[3])
                return "ok"
            return original_run(args)

        with (
            mock.patch.object(GI.tempfile, "gettempdir", return_value=str(self.root)),
            mock.patch.object(GI, "session_node", return_value=node),
            mock.patch.object(GI, "run", side_effect=run),
        ):
            event = {"hook_event_name": "PostToolUse", "session_id": "left", "cwd": str(self.repo)}
            GI.refresh(event, processes[0].pid, names[0])
            os.environ["AGTERM_PANE_ID"] = "RIGHT"
            other = {**event, "session_id": "right", "cwd": str(peer)}
            GI.refresh(other, processes[1].pid, names[1])
            self.assertIn("L repo:", published[-1])
            self.assertIn("R other:", published[-1])
            processes[0].kill()
            processes[0].wait()
            GI.refresh(other, processes[1].pid, names[1])
            self.assertEqual(
                published[-1], '**peer** ^[✓ clean](color: "green") ^[local only](dim: true)'
            )
            state = next((self.root / f"agterm-git-info-{os.getuid()}").glob("*.json"))
            self.assertEqual(set(json.loads(state.read_text())), {"RIGHT"})

    def test_overlapping_updates_keep_both_panes(self) -> None:
        for phase in ("snapshot", "publish"):
            with self.subTest(phase=phase):
                self.overlap(phase, ending=False)

    def test_exit_cannot_be_overtaken_by_an_inflight_publication(self) -> None:
        self.overlap("publish", ending=True)

    def overlap(self, phase, *, ending):
        directory = self.root / (phase + str(ending))
        directory.mkdir()
        node = {
            "surfaces": [{"paneID": "LEFT", "kind": "left"}, {"paneID": "RIGHT", "kind": "right"}]
        }
        event = {
            "hook_event_name": "PostToolUse",
            "session_id": "root",
            "cwd": str(directory / "left"),
        }
        first = {
            "directory": str(directory),
            "node": node,
            "pane": "LEFT",
            "event": event,
            "gate": phase,
        }
        second = {
            **first,
            "pane": "LEFT" if ending else "RIGHT",
            "gate": "contender",
            "event": {
                **event,
                "hook_event_name": "SessionEnd" if ending else "PostToolUse",
                "cwd": str(directory / "left" if ending else directory / "right"),
            },
        }
        context = multiprocessing.get_context("fork")
        connections = [context.Pipe() for _ in range(2)]
        workers = [
            context.Process(target=overlap_worker, args=(settings, pair[1]))
            for settings, pair in zip((first, second), connections)
        ]
        workers[0].start()
        connections[0][1].close()
        try:
            self.assertEqual(connections[0][0].recv(), phase)
            workers[1].start()
            connections[1][1].close()
            self.assertEqual(connections[1][0].recv(), "locking")
            lock_path = next((directory / f"agterm-git-info-{os.getuid()}").glob("*.lock"))
            with lock_path.open("a") as lock, self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            connections[0][0].send("release")
            self.assertEqual(connections[0][0].recv(), "done")
            self.assertEqual(connections[1][0].recv(), "done")
        finally:
            if workers[0].is_alive():
                try:
                    connections[0][0].send("release")
                except (BrokenPipeError, OSError):
                    pass
            for worker in workers:
                if worker.pid is not None:
                    worker.join()
            for pair in connections:
                for connection in pair:
                    connection.close()
        self.assertEqual([w.exitcode for w in workers], [0, 0])
        lines = [
            json.loads(line) for line in (directory / "published.jsonl").read_text().splitlines()
        ]
        self.assertEqual(len(lines), 2)
        if ending:
            self.assertEqual(lines[-1], "--clear")
        else:
            self.assertIn("L left:", lines[-1])
            self.assertIn("R right:", lines[-1])

    def exercise_panes(self, *, different: bool) -> None:
        peer = self.repo / "subdir"
        if different:
            peer = self.root / "other"
            self.git(self.repo, "worktree", "add", "-b", "peer", str(peer))
        node = {
            "id": "SESSION",
            "split": False,
            "hasSplit": True,
            "foreground": ["/bin/zsh", "-lc", "wrapper"],
            "splitForeground": ["/bin/zsh", "-lc", "wrapper"],
            "surfaces": [{"paneID": "LEFT", "kind": "left"}, {"paneID": "RIGHT", "kind": "right"}],
        }
        published = []
        original_run = GI.run

        def run(args: list[str]) -> str:
            if args[0] == "ps":
                return "codex" if args[2] == "101" else "claude"
            if args[0] == "agtermctl":
                published.append(args)
                return "ok"
            return original_run(args)

        with (
            mock.patch.object(GI.tempfile, "gettempdir", return_value=str(self.root)),
            mock.patch.object(GI, "session_node", return_value=node),
            mock.patch.object(GI, "run", side_effect=run),
        ):
            event = {"hook_event_name": "PostToolUse", "session_id": "new", "cwd": str(self.repo)}
            GI.refresh(event, 101, "codex")
            os.environ["AGTERM_PANE_ID"] = "RIGHT"
            peer_event = {**event, "cwd": str(peer)}
            GI.refresh(peer_event, 102, "claude")
            line = published[-1][3]
            main = '**main** ^[✓ clean](color: "green") ^[local only](dim: true)'
            other = '**peer** ^[✓ clean](color: "green") ^[local only](dim: true)'
            if different:
                self.assertIn("L repo: " + main, line)
                self.assertIn("R other: " + other, line)
            else:
                self.assertEqual(line, main)
            self.assertIn("--markdown", published[-1])
            self.assertIn("86400", published[-1])
            self.assertEqual(published[-1][-2:], ["--socket", "/test/socket"])
            # A late exit from the replaced conversation must leave its successor registered.
            GI.refresh(
                {**peer_event, "hook_event_name": "SessionEnd", "session_id": "old"},
                102,
                "claude",
            )
            self.assertEqual(published[-1][3], line)
            os.environ["AGTERM_PANE_ID"] = "LEFT"
            GI.refresh({**event, "hook_event_name": "SessionEnd"}, 101, "codex")
            expected = other if different else main
            self.assertEqual(published[-1][3], expected)
            os.environ["AGTERM_PANE_ID"] = "RIGHT"
            GI.refresh({**peer_event, "hook_event_name": "SessionEnd"}, 102, "claude")
            self.assertEqual(published[-1][3], "--clear")
            self.assertNotIn("--markdown", published[-1])

    def test_colors_escape_names_and_preserve_markup_byte_limit(self) -> None:
        self.assertEqual(
            GI.colorize("bad`]branch_ ● 2 ↑1 ↓3"),
            '**bad\\`\\]branch\\_** ^[● 2](color: "yellow") '
            '^[↑1](color: "blue") ^[↓3](color: "purple")',
        )
        self.assertEqual(
            GI.colorize("abc1234 detached ✓ clean"),
            '**abc1234** ^[detached](dim: true) ^[✓ clean](color: "green")',
        )
        summaries = {
            "/left/" + "[" * 48: {"line": "`" * 80 + " ● 123 ↑12 ↓34", "panes": ["left"]},
            "/right/" + "界" * 16: {"line": "`" * 80 + " ● 123 ↑12 ↓34", "panes": ["right"]},
        }
        text, options = GI.format_summaries(summaries)
        self.assertEqual(options, [])
        self.assertLessEqual(len(text.encode()), 512)
        self.assertIn("L ", text)
        self.assertIn("R ", text)
        self.assertNotIn("color:", text)

    def test_nested_and_noninteractive_hooks_never_publish(self) -> None:
        event = json.dumps({"hook_event_name": "PostToolUse", "cwd": str(self.repo)})
        with mock.patch.object(GI, "refresh") as publish:
            with (
                mock.patch.object(GI.sys, "stdin", io.StringIO(event)),
                mock.patch.object(GI, "owner", return_value=None),
            ):
                GI.main()
            with (
                mock.patch.object(GI.sys, "stdin", io.StringIO(event)),
                mock.patch.object(GI, "owner", return_value=(1, "codex")),
            ):
                GI.main()
            with (
                mock.patch.object(GI.sys, "stdin", io.StringIO(event)),
                mock.patch.object(GI, "owner", return_value=(1, "claude")),
                mock.patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"}),
            ):
                GI.main()
            publish.assert_not_called()
            with (
                mock.patch.object(
                    GI.sys,
                    "stdin",
                    io.StringIO(
                        json.dumps({
                            "hook_event_name": "PostToolUse",
                            "cwd": str(self.repo),
                            "agent_id": "CHILD",
                        })
                    ),
                ),
                mock.patch.object(GI, "owner", return_value=(1, "claude")),
                mock.patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "cli"}),
            ):
                GI.main()
            publish.assert_not_called()

    def test_codex_shared_process_subagents_cannot_publish(self) -> None:
        transcript = self.root / "transcript.jsonl"
        event = {
            "hook_event_name": "PostToolUse",
            "cwd": str(self.repo),
            "session_id": "ROOT",
            "transcript_path": str(transcript),
        }
        for source, expected in (
            ("cli", True),
            ("exec", False),
            ({"subagent": {"thread_spawn": {"parent_thread_id": "ROOT"}}}, False),
        ):
            transcript.write_text(
                json.dumps({
                    "type": "session_meta",
                    "payload": {
                        "id": "ROOT",
                        "source": source,
                    },
                })
                + "\n"
            )
            with (
                mock.patch.object(GI, "refresh") as publish,
                mock.patch.object(GI.sys, "stdin", io.StringIO(json.dumps(event))),
                mock.patch.object(GI, "owner", return_value=(1, "codex")),
            ):
                GI.main()
                self.assertEqual(publish.called, expected)
        transcript.write_text(
            json.dumps({
                "type": "session_meta",
                "payload": {
                    "id": "OTHER",
                    "source": "cli",
                },
            })
            + "\n"
        )
        self.assertFalse(GI.codex_root(event))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT_ID = "01900000-0000-7000-8000-000000000001"
CHILD_ID = "01900000-0001-7000-8000-000000000002"
INTERMEDIATE_ID = "01900000-0002-7000-8000-000000000003"
NESTED_ID = "01900000-0003-7000-8000-000000000004"
LEGACY_ID = "01900000-0004-7000-8000-000000000005"
TAB_ID = "01900000-0005-7000-8000-000000000006"
OTHER_ID = "01900000-0006-7000-8000-000000000007"
HERE = Path(__file__).parent
RECIPE = Path(
    os.environ.get("CODEX_RESUME_SCRIPT", HERE / "codex-resume.zsh")
).resolve()
HOOK = Path(
    os.environ.get("CODEX_RESUME_HOOK", HERE / "codex-resume-hook.zsh")
).resolve()
TRANSCRIPT = "/tmp/rollout-2026-08-30T00-00-00-01900000-0000-7000-8000-000000000001.jsonl"
OWN = ["--no-daemon", "-c", 'shell_environment_policy.set.CODEX_AGTERM_TAB=""']


class CodexResumeTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.home = Path(self.temp_dir.name)
        self.sessions = self.home / ".codex" / "sessions" / "2026" / "08" / "30"
        self.map_file = self.home / ".codex" / "agterm" / TAB_ID
        self.log = self.home / "codex-args.jsonl"
        self.bin_dir = self.home / "bin"
        self.bin_dir.mkdir()
        fake_codex = self.bin_dir / "codex"
        fake_codex.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                from pathlib import Path

                with Path(os.environ["FAKE_CODEX_LOG"]).open("a") as log:
                    print(json.dumps({{
                        "argv": sys.argv[1:],
                        "tab": os.environ.get("CODEX_AGTERM_TAB"),
                    }}), file=log)

                # another codex on the machine, such as a `codex exec` an agent in the same tab
                # runs, writing a rollout while this one is open
                if target := os.environ.get("FAKE_CODEX_FOREIGN_ROLLOUT"):
                    sessions = Path(target)
                    sessions.mkdir(parents=True, exist_ok=True)
                    rollout = sessions / "rollout-2026-08-30T00-00-09-{OTHER_ID}.jsonl"
                    rollout.write_text(json.dumps({{
                        "type": "session_meta",
                        "payload": {{"id": "{OTHER_ID}", "session_id": "{OTHER_ID}"}},
                    }}, separators=(",", ":")) + "\\n")
                """
            )
        )
        fake_codex.chmod(0o755)

    def write_rollout(self, rollout_id, session_id=None, parent_id=None):
        self.sessions.mkdir(parents=True, exist_ok=True)
        payload = {"id": rollout_id}
        if session_id is not None:
            payload["session_id"] = session_id
        if parent_id is not None:
            payload["parent_thread_id"] = parent_id
        path = self.sessions / f"rollout-2026-08-30T00-00-00-{rollout_id}.jsonl"
        path.write_text(
            json.dumps(
                {"type": "session_meta", "payload": payload}, separators=(",", ":")
            )
            + "\n"
        )
        return path

    def write_compressed_rollout(self, rollout_id):
        # only the name matters: the function never reads a compressed rollout
        self.sessions.mkdir(parents=True, exist_ok=True)
        path = self.sessions / f"rollout-2026-08-30T00-00-00-{rollout_id}.jsonl.zst"
        path.write_bytes(b"\x28\xb5\x2f\xfd")
        return path

    def run_codex_logged(self, *args, foreign_rollout=False):
        env = os.environ.copy()
        env.pop("CODEX_AGTERM_TAB", None)
        env.update(
            {
                "AGTERM_SESSION_ID": TAB_ID,
                "FAKE_CODEX_LOG": str(self.log),
                "HOME": str(self.home),
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "RECIPE": str(RECIPE),
            }
        )
        if foreign_rollout:
            env["FAKE_CODEX_FOREIGN_ROLLOUT"] = str(self.sessions)
        result = subprocess.run(
            [
                "zsh",
                "-fc",
                'source "$RECIPE"; codex "$@"',
                "test-harness",
                *args,
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def run_codex(self, *args, foreign_rollout=False):
        return [
            call["argv"]
            for call in self.run_codex_logged(*args, foreign_rollout=foreign_rollout)
        ]

    def run_hook(self, event, tab=TAB_ID):
        env = os.environ.copy()
        env.pop("CODEX_AGTERM_TAB", None)
        env["HOME"] = str(self.home)
        if tab is not None:
            env["CODEX_AGTERM_TAB"] = tab
        return subprocess.run(
            ["zsh", "-f", str(HOOK)],
            input=event,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def map_to(self, rollout_id):
        self.map_file.parent.mkdir(parents=True, exist_ok=True)
        self.map_file.write_text(f"{rollout_id}\n")

    def test_mapped_child_resumes_and_repairs_root(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.write_rollout(CHILD_ID, ROOT_ID, ROOT_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex()

        self.assertEqual([[*OWN, "resume", ROOT_ID]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_nested_child_uses_root_session_id(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.write_rollout(INTERMEDIATE_ID, ROOT_ID, ROOT_ID)
        self.write_rollout(NESTED_ID, ROOT_ID, INTERMEDIATE_ID)
        self.map_to(NESTED_ID)

        calls = self.run_codex()

        self.assertEqual([[*OWN, "resume", ROOT_ID]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_mapped_root_forwards_yolo(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)

        calls = self.run_codex("--yolo")

        self.assertEqual([[*OWN, "resume", ROOT_ID, "--yolo"]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_child_without_root_falls_through_to_plain_run(self):
        self.write_rollout(CHILD_ID, ROOT_ID, ROOT_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex()

        self.assertEqual([OWN], calls)
        self.assertEqual(CHILD_ID, self.map_file.read_text().strip())

    def test_explicit_resume_passes_through(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)

        calls = self.run_codex_logged("resume", LEGACY_ID, "--yolo")

        self.assertEqual([{"argv": ["resume", LEGACY_ID, "--yolo"], "tab": None}], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_legacy_rollout_falls_back_to_filename_id(self):
        self.write_rollout(LEGACY_ID)
        self.map_to(LEGACY_ID)

        calls = self.run_codex()

        self.assertEqual([[*OWN, "resume", LEGACY_ID]], calls)
        self.assertEqual(LEGACY_ID, self.map_file.read_text().strip())

    def test_started_codex_carries_the_tab_for_the_hook(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)

        resumed = self.run_codex_logged()
        self.map_file.unlink()
        fresh = self.run_codex_logged()

        self.assertEqual(TAB_ID, resumed[0]["tab"])
        self.assertEqual(TAB_ID, fresh[1]["tab"])

    def test_another_codex_rollout_during_the_run_is_not_adopted(self):
        calls = self.run_codex(foreign_rollout=True)

        self.assertEqual([OWN], calls)
        self.assertFalse(self.map_file.exists())

    def test_replayed_resume_is_decided_again_from_the_mapping(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.write_rollout(CHILD_ID, ROOT_ID, ROOT_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex_logged(*OWN, "resume", CHILD_ID, "--yolo")

        self.assertEqual(
            [{"argv": [*OWN, "resume", ROOT_ID, "--yolo"], "tab": TAB_ID}], calls
        )

    def test_replayed_fresh_run_resumes_the_mapped_conversation(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)

        calls = self.run_codex(*OWN)

        self.assertEqual([[*OWN, "resume", ROOT_ID]], calls)

    def test_typed_no_daemon_is_not_passed_twice(self):
        fresh = self.run_codex("--no-daemon", "--yolo")
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)
        resumed = self.run_codex("--no-daemon")

        self.assertEqual([*OWN, "--yolo"], fresh[0])
        self.assertEqual([*OWN, "resume", ROOT_ID], resumed[1])

    def test_typed_no_daemon_after_another_flag_is_dropped(self):
        calls = self.run_codex("--yolo", "--no-daemon")

        self.assertEqual([[*OWN, "--yolo"]], calls)

    def test_no_daemon_after_the_prompt_marker_is_prompt_text(self):
        calls = self.run_codex("--no-daemon", "--", "--no-daemon")

        self.assertEqual([[*OWN, "--", "--no-daemon"]], calls)

    def test_queue_passes_through(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)
        args = ["queue", "--thread", ROOT_ID, "--message", "hi"]

        calls = self.run_codex_logged(*args)

        self.assertEqual([{"argv": args, "tab": None}], calls)

    def test_compressed_mapped_rollout_resumes_the_mapped_id(self):
        self.write_compressed_rollout(CHILD_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex()

        self.assertEqual([[*OWN, "resume", CHILD_ID]], calls)
        self.assertEqual(CHILD_ID, self.map_file.read_text().strip())

    def test_child_with_a_compressed_root_resumes_the_root(self):
        self.write_compressed_rollout(ROOT_ID)
        self.write_rollout(CHILD_ID, ROOT_ID, ROOT_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex()

        self.assertEqual([[*OWN, "resume", ROOT_ID]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_hook_records_the_session_for_the_tab(self):
        event = json.dumps(
            {
                "session_id": ROOT_ID,
                "transcript_path": TRANSCRIPT,
                "source": "startup",
                "hook_event_name": "SessionStart",
            },
            separators=(",", ":"),
        )

        result = self.run_hook(event)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_hook_reads_a_session_id_with_spaces_around_the_colon(self):
        event = json.dumps(
            {"source": "startup", "transcript_path": TRANSCRIPT, "session_id": ROOT_ID}
        )

        result = self.run_hook(event)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_hook_replaces_the_mapping_when_the_tab_switches_conversation(self):
        self.map_to(ROOT_ID)
        event = json.dumps(
            {"session_id": OTHER_ID, "transcript_path": TRANSCRIPT, "source": "clear"},
            separators=(",", ":"),
        )

        result = self.run_hook(event)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(OTHER_ID, self.map_file.read_text().strip())

    def test_hook_skips_the_memory_session(self):
        self.map_to(ROOT_ID)
        null = json.dumps(
            {
                "session_id": OTHER_ID,
                "transcript_path": None,
                "cwd": str(self.home / ".codex" / "memories"),
                "source": "startup",
            }
        )
        missing = json.dumps({"session_id": OTHER_ID, "source": "startup"})

        for event in (null, missing):
            with self.subTest(event=event):
                result = self.run_hook(event)

                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_hook_leaves_the_mapping_alone_without_the_tab(self):
        self.map_to(ROOT_ID)
        event = json.dumps(
            {"session_id": OTHER_ID, "transcript_path": TRANSCRIPT}, separators=(",", ":")
        )

        unset = self.run_hook(event, tab=None)
        blank = self.run_hook(event, tab="")

        self.assertEqual(0, unset.returncode, unset.stderr)
        self.assertEqual(0, blank.returncode, blank.stderr)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_hook_refuses_a_tab_that_is_not_an_id(self):
        event = json.dumps(
            {"session_id": ROOT_ID, "transcript_path": TRANSCRIPT}, separators=(",", ":")
        )

        result = self.run_hook(event, tab="../../escape")

        self.assertEqual(1, result.returncode)
        self.assertFalse((self.home / ".codex" / "agterm").exists())

    def test_hook_refuses_an_event_without_a_session_id(self):
        event = json.dumps(
            {"source": "startup", "transcript_path": TRANSCRIPT}, separators=(",", ":")
        )

        result = self.run_hook(event)

        self.assertEqual(1, result.returncode)
        self.assertFalse(self.map_file.exists())


if __name__ == "__main__":
    unittest.main()

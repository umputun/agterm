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
RECIPE = Path(
    os.environ.get("CODEX_RESUME_SCRIPT", Path(__file__).with_name("codex-resume.zsh"))
).resolve()


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
                import time
                from pathlib import Path

                with Path(os.environ["FAKE_CODEX_LOG"]).open("a") as log:
                    print(json.dumps(__import__("sys").argv[1:]), file=log)

                if target := os.environ.get("FAKE_CODEX_CREATE_CHILD"):
                    sessions = Path(target)
                    sessions.mkdir(parents=True, exist_ok=True)
                    root = sessions / "rollout-2026-08-30T00-00-00-{ROOT_ID}.jsonl"
                    child = sessions / "rollout-2026-08-30T00-00-01-{CHILD_ID}.jsonl"
                    root.write_text(json.dumps({{
                        "type": "session_meta",
                        "payload": {{"id": "{ROOT_ID}", "session_id": "{ROOT_ID}"}},
                    }}, separators=(",", ":")) + "\\n")
                    child.write_text(json.dumps({{
                        "type": "session_meta",
                        "payload": {{
                            "id": "{CHILD_ID}",
                            "session_id": "{ROOT_ID}",
                            "parent_thread_id": "{ROOT_ID}",
                        }},
                    }}, separators=(",", ":")) + "\\n")
                    now = time.time()
                    os.utime(root, (now + 1, now + 1))
                    os.utime(child, (now + 2, now + 2))
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

    def run_codex(self, *args, create_child=False):
        env = os.environ.copy()
        env.update(
            {
                "AGTERM_SESSION_ID": TAB_ID,
                "FAKE_CODEX_LOG": str(self.log),
                "HOME": str(self.home),
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "RECIPE": str(RECIPE),
            }
        )
        if create_child:
            env["FAKE_CODEX_CREATE_CHILD"] = str(self.sessions)
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

    def map_to(self, rollout_id):
        self.map_file.parent.mkdir(parents=True, exist_ok=True)
        self.map_file.write_text(f"{rollout_id}\n")

    def test_mapped_child_resumes_and_repairs_root(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.write_rollout(CHILD_ID, ROOT_ID, ROOT_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex()

        self.assertEqual([["resume", ROOT_ID]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_newest_child_records_root(self):
        calls = self.run_codex(create_child=True)

        self.assertEqual([[]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_nested_child_uses_root_session_id(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.write_rollout(INTERMEDIATE_ID, ROOT_ID, ROOT_ID)
        self.write_rollout(NESTED_ID, ROOT_ID, INTERMEDIATE_ID)
        self.map_to(NESTED_ID)

        calls = self.run_codex()

        self.assertEqual([["resume", ROOT_ID]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_mapped_root_forwards_yolo(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)

        calls = self.run_codex("--yolo")

        self.assertEqual([["resume", ROOT_ID, "--yolo"]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_child_without_root_falls_through_to_plain_run(self):
        self.write_rollout(CHILD_ID, ROOT_ID, ROOT_ID)
        self.map_to(CHILD_ID)

        calls = self.run_codex()

        self.assertEqual([[]], calls)
        self.assertEqual(CHILD_ID, self.map_file.read_text().strip())

    def test_explicit_resume_passes_through(self):
        self.write_rollout(ROOT_ID, ROOT_ID)
        self.map_to(ROOT_ID)

        calls = self.run_codex("resume", LEGACY_ID, "--yolo")

        self.assertEqual([["resume", LEGACY_ID, "--yolo"]], calls)
        self.assertEqual(ROOT_ID, self.map_file.read_text().strip())

    def test_legacy_rollout_falls_back_to_filename_id(self):
        self.write_rollout(LEGACY_ID)
        self.map_to(LEGACY_ID)

        calls = self.run_codex()

        self.assertEqual([["resume", LEGACY_ID]], calls)
        self.assertEqual(LEGACY_ID, self.map_file.read_text().strip())


if __name__ == "__main__":
    unittest.main()

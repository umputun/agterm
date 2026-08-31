#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

TAB_ID = "11111111-2222-4333-8444-555555555555"
OTHER_ID = "66666666-7777-4888-8999-000000000000"
HERE = Path(__file__).resolve().parent
RECIPES = {
    "zsh": Path(os.environ.get("CLAUDE_RESUME_ZSH_SCRIPT", HERE / "claude-resume.zsh")),
    "fish": Path(
        os.environ.get("CLAUDE_RESUME_FISH_SCRIPT", HERE / "claude-resume.fish")
    ),
}


class ClaudeResumeTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.home = Path(self.temp_dir.name)
        self.projects = self.home / ".claude" / "projects"
        self.work = self.home / "work" / "project"
        self.work.mkdir(parents=True)
        self.current_project = self.projects / self.encode_project(self.work)
        self.log = self.home / "claude-args.jsonl"
        self.bin_dir = self.home / "bin"
        self.bin_dir.mkdir()
        fake_claude = self.bin_dir / "claude"
        fake_claude.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                from pathlib import Path

                def encode(path):
                    return "".join(c if c.isascii() and (c.isalnum() or c == "-") else "-" for c in path)

                args = sys.argv[1:]
                if args[:1] == ["--session-id"]:
                    transcript = Path.home() / ".claude" / "projects" / encode(os.getcwd()) / f"{args[1]}.jsonl"
                    if transcript.exists():
                        print(f"session file still exists: {transcript}", file=sys.stderr)
                        raise SystemExit(73)

                with Path(os.environ["FAKE_CLAUDE_LOG"]).open("a") as log:
                    print(json.dumps(args), file=log)
                """
            )
        )
        fake_claude.chmod(0o755)

        self.shell = os.environ.get("CLAUDE_RESUME_SHELLS", "zsh")
        if self.shell not in RECIPES:
            self.fail(f"unsupported shell in CLAUDE_RESUME_SHELLS: {self.shell}")
        if not shutil.which(self.shell):
            self.fail(f"required shell is not installed: {self.shell}")

    @staticmethod
    def encode_project(path):
        return "".join(
            char if char.isascii() and (char.isalnum() or char == "-") else "-"
            for char in str(path.resolve())
        )

    @staticmethod
    def message(message_type="user", sidechain=False, session_id=TAB_ID):
        return {
            "parentUuid": None,
            "isSidechain": sidechain,
            "type": message_type,
            "message": {"role": message_type, "content": "probe"},
            "uuid": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sessionId": session_id,
        }

    @staticmethod
    def bridge(session_id=TAB_ID):
        return {
            "type": "bridge-session",
            "sessionId": session_id,
            "bridgeSessionId": "cse_probe",
            "lastSequenceNum": 0,
        }

    @staticmethod
    def generated_id(generation):
        if generation == 0:
            return TAB_ID
        tail = (int(TAB_ID[-8:], 16) + generation) & 0xFFFFFFFF
        return f"{TAB_ID[:-8]}{tail:08x}"

    def write_transcript(self, *entries, project=None, session_id=TAB_ID):
        directory = project or self.current_project
        directory.mkdir(parents=True, exist_ok=True)
        transcript = directory / f"{session_id}.jsonl"
        transcript.write_text(
            "".join(
                json.dumps(entry, separators=(",", ":")) + "\n" for entry in entries
            )
        )
        return transcript

    def write_raw_transcript(self, text):
        self.current_project.mkdir(parents=True, exist_ok=True)
        transcript = self.current_project / f"{TAB_ID}.jsonl"
        transcript.write_text(text)
        return transcript

    def invocation(self, *args, session_id=TAB_ID):
        self.log.unlink(missing_ok=True)
        env = os.environ.copy()
        env.update(
            {
                "AGTERM_SESSION_ID": session_id.upper(),
                "CLAUDE_CONFIG_DIR": str(self.home / ".claude"),
                "FAKE_CLAUDE_LOG": str(self.log),
                "HOME": str(self.home),
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "RECIPE": str(RECIPES[self.shell]),
                "TERM": "xterm-256color",
            }
        )
        if self.shell == "zsh":
            command = [
                "zsh",
                "-fic",
                'source "$RECIPE"; claude "$@"',
                "test-harness",
                *args,
            ]
        else:
            command = [
                "fish",
                "-i",
                "-c",
                'source "$RECIPE"; claude $argv',
                "--",
                *args,
            ]
        return command, env

    def invoke_claude(self, *args, session_id=TAB_ID):
        command, env = self.invocation(*args, session_id=session_id)
        return subprocess.run(
            command,
            env=env,
            cwd=self.work,
            capture_output=True,
            text=True,
            check=False,
        )

    def run_claude(self, *args, session_id=TAB_ID):
        result = self.invoke_claude(*args, session_id=session_id)
        self.assertEqual(0, result.returncode, result.stderr)
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_call(self, expected, *args, session_id=TAB_ID):
        self.assertEqual(
            [expected],
            self.run_claude(*args, session_id=session_id),
        )

    def test_missing_transcript_starts_tab_session(self):
        self.assert_call(["--session-id", TAB_ID])

    def test_legacy_bridge_only_transcript_is_preserved(self):
        transcript = self.write_transcript(self.bridge())

        self.assert_call(["--session-id", self.generated_id(1)])
        self.assertTrue(transcript.exists())

    def test_legacy_user_or_assistant_message_resumes_tab_session(self):
        for message_type in ("user", "assistant"):
            with self.subTest(message_type=message_type):
                self.write_transcript(
                    self.bridge(),
                    self.message(message_type),
                )
                self.assert_call(["--resume", TAB_ID])

    def test_project_key_encoding_does_not_hide_legacy_conversation(self):
        self.write_transcript(self.message(), project=self.projects / "unicode-hash-key")

        self.assert_call(["--resume", TAB_ID])

    def test_sidechain_only_transcript_is_not_moved(self):
        transcript = self.write_transcript(self.message(sidechain=True))

        self.assert_call(["--resume", TAB_ID])
        self.assertTrue(transcript.exists())

    def test_malformed_transcript_is_not_moved(self):
        transcript = self.write_raw_transcript(
            '{"type":"user","sessionId":"' + TAB_ID + '"\n'
        )

        self.assert_call(["--resume", TAB_ID])
        self.assertTrue(transcript.exists())

    def test_truncated_bridge_record_is_not_treated_as_recoverable(self):
        transcript = self.write_raw_transcript(
            '{"type":"bridge-session","sessionId":"'
            + TAB_ID
            + '","bridgeSessionId":"cse_probe","lastSequenceNum":0\n'
        )

        self.assert_call(["--resume", TAB_ID])
        self.assertTrue(transcript.exists())

    def test_bridge_only_generated_id_advances_without_moving_it(self):
        transcript = self.write_transcript(
            self.bridge(), project=self.projects / "encoded-project"
        )

        self.assert_call(["--session-id", self.generated_id(1)])
        self.assertTrue(transcript.exists())

    def test_second_generated_id_resumes(self):
        self.write_transcript(
            self.bridge(), project=self.projects / "encoded-project"
        )
        self.write_transcript(
            self.message(session_id=self.generated_id(1)),
            project=self.projects / "another-key",
            session_id=self.generated_id(1),
        )

        self.assert_call(["--resume", self.generated_id(1)])

    def test_restored_own_resume_is_recomputed(self):
        self.write_transcript(self.bridge())

        self.assert_call(
            ["--session-id", self.generated_id(1), "--permission-mode", "plan"],
            "--resume",
            TAB_ID,
            "--permission-mode",
            "plan",
        )

    def test_restored_generated_resume_is_recomputed(self):
        self.write_transcript(self.bridge())
        generated = self.generated_id(1)
        self.write_transcript(
            self.message(session_id=generated),
            project=self.projects / "new-key",
            session_id=generated,
        )

        self.assert_call(["--resume", generated], "--resume", generated)

    def test_explicit_other_resume_passes_through(self):
        self.write_transcript(self.message())

        self.assert_call(
            ["--resume", OTHER_ID, "--permission-mode", "plan"],
            "--resume",
            OTHER_ID,
            "--permission-mode",
            "plan",
        )

    def test_malformed_same_prefix_resume_passes_through(self):
        malformed = f"{TAB_ID[:-8]}gggggggg"

        self.assert_call(["--resume", malformed], "--resume", malformed)

    def test_parent_config_dir_does_not_escape_fixture(self):
        self.write_transcript(self.bridge())
        with patch.dict(
            os.environ,
            {"CLAUDE_CONFIG_DIR": str(self.home / "foreign-config")},
        ):
            self.assert_call(["--session-id", self.generated_id(1)])

    def test_malformed_tab_id_passes_through_without_path_lookup(self):
        for malformed in ("../../tmp/not-a-tab-id", "-" * 36):
            with self.subTest(malformed=malformed):
                self.assert_call(
                    ["--permission-mode", "plan"],
                    "--permission-mode",
                    "plan",
                    session_id=malformed,
                )

if __name__ == "__main__":
    if "CLAUDE_RESUME_SHELLS" in os.environ:
        unittest.main()
    else:
        status = 0
        for selected_shell in RECIPES:
            env = os.environ.copy()
            env["CLAUDE_RESUME_SHELLS"] = selected_shell
            result = subprocess.run([os.sys.executable, __file__], env=env, check=False)
            status = max(status, result.returncode)
        raise SystemExit(status)

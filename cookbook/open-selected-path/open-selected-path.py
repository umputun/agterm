#!/usr/bin/env python3
"""Open the file path you selected in the terminal, in a viewer in an overlay over that session.

Runs as an agterm keymap custom command, so the runner exports $AGT_*, widens PATH with the CLI and
Homebrew directories, and pins stdout to /dev/null.

The selection is terminal text, usually a path an agent printed: `docs/plans/x-spec.md`,
`src/app/Model.swift:566`. It is relative to wherever the agent was working, which is often not the
pane's own directory, so the first step that finds a regular file wins:

    absolute or ~/  ·  pane directory  ·  git root  ·  main checkout of a worktree
    ·  the repo's other worktrees
    ·  `git ls-files` suffix  ·  Spotlight, full-path suffix

One match inside the repo opens directly. Several, or any Spotlight match (it may sit in another repo),
go through `agtermctl pick`. None posts a panel that hides itself.

Usage: open-selected-path.py [--test] [PATH]
    PATH    resolve and open this instead of $AGT_SELECTION
    --test  run the built-in tests
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

HOME = os.path.expanduser("~")
AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")
# {path} and {line} are replaced, each quoted; {line} is 1 when the selection carried none.
EDITOR = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
VIEWER = os.environ.get("OPEN_PATH_VIEWER") or f"{EDITOR} +{{line}} {{path}}"
OVERLAY_PERCENT = os.environ.get("OPEN_PATH_OVERLAY_PERCENT", "90")
HUD_SECONDS = os.environ.get("OPEN_PATH_HUD_SECONDS", "4")
SPOTLIGHT_CAP = 20
MAX_SELECTION = 1024
# a path as agents print it; a space only in an absolute one, since a relative path with a space is far
# more often two words of prose than a file.
PATH_RES = (re.compile(r"^[\w.@+][\w.@+~-]*(?:/[\w.@+~-]+)*$"),
            re.compile(r"^~(?:/[\w.@+~-]+)+$"),
            re.compile(r"^(?:/[\w.@+~ -]+)+$"))
LINE_RE = re.compile(r":([0-9]+)(?:-[0-9]+|:[0-9]+)?$")


def parse_selection(raw: str) -> tuple[str, int | None] | None:
    """(path, line) from selected text, or None when it does not look like one path.

    Quotes, backticks and trailing prose punctuation come off first, then an editor-style `:N`, `:N-M`
    or `:N:C` becomes the line. The shape check is what keeps a stray selection from reaching git or
    Spotlight at all.
    """
    text = raw.strip()
    if not text or len(text) > MAX_SELECTION or "\n" in text or any(ord(c) < 0x20 for c in text):
        return None
    while True:
        trimmed = text.strip("`'\"()[]<>").rstrip(".,;:!?*")
        if trimmed == text:
            break
        text = trimmed
    line = None
    match = LINE_RE.search(text)
    if match:
        line = int(match.group(1))
        if line == 0:
            return None
        text = text[:match.start()]
    if not any(r.match(text) for r in PATH_RES):
        return None
    return text, line


def git(cwd: str, *args: str) -> str | None:
    """stdout of a git call, or None. `core.fsmonitor=` stops a cloned repo's config running a program."""
    try:
        done = subprocess.run(["git", "-c", "core.fsmonitor=", "-C", cwd, *args],
                              capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def existing(paths: list[str]) -> list[str]:
    out: list[str] = []
    for p in paths:
        real = os.path.realpath(p)
        if os.path.isfile(real) and real not in out:
            out.append(real)
    return out


def repo_roots(cwd: str) -> tuple[str | None, str | None]:
    """(worktree root, main checkout when cwd is in a linked worktree)."""
    root = (git(cwd, "rev-parse", "--show-toplevel") or "").strip()
    if not root:
        return None, None
    common = (git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir") or "").strip()
    main = os.path.dirname(common) if common.endswith("/.git") else None
    return root, (main if main and os.path.realpath(main) != os.path.realpath(root) else None)


def linked_worktrees(root: str) -> list[str]:
    """Every other checkout of the repo: a path an agent printed in its worktree, clicked in another."""
    listing = git(root, "worktree", "list", "--porcelain")
    here = os.path.realpath(root)
    return [line[len("worktree "):] for line in (listing or "").splitlines()
            if line.startswith("worktree ") and os.path.realpath(line[len("worktree "):]) != here]


def suffix_matches(root: str, rel: str) -> list[str]:
    listing = git(root, "ls-files", "-z")
    if listing is None:
        return []
    return [os.path.join(root, f) for f in listing.split("\0") if f and (f == rel or f.endswith("/" + rel))]


def spotlight(rel: str) -> list[str]:
    """Every indexed file whose full path ends in /<rel>, repo metadata excluded."""
    try:
        done = subprocess.run([os.environ.get("OPEN_PATH_MDFIND", "mdfind"), "-name", os.path.basename(rel)],
                              capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    hits = [h for h in done.stdout.splitlines() if h.endswith("/" + rel) and "/.git/" not in h]
    return hits[:SPOTLIGHT_CAP]


def resolve(path: str, cwd: str) -> tuple[list[str], str | None]:
    """(candidates, step): real paths of regular files, and the name of the step that found them."""
    if path.startswith(("~/", "/")):
        return existing([os.path.expanduser(path)]), "absolute"
    rel = path.removeprefix("./")
    steps = [("pane directory", lambda: [os.path.join(cwd, rel)])]
    root, main = repo_roots(cwd) if os.path.isdir(cwd) else (None, None)
    if root:
        steps.append(("git root", lambda: [os.path.join(root, rel)]))
        if main:
            steps.append(("main checkout", lambda: [os.path.join(main, rel)]))
        steps.append(("linked worktree", lambda: [os.path.join(t, rel) for t in linked_worktrees(root)]))
        if not rel.startswith("../"):
            steps.append(("repo suffix", lambda: suffix_matches(root, rel)))
    if not rel.startswith("../"):
        steps.append(("spotlight", lambda: spotlight(rel)))
    for step, find in steps:
        found = existing(find())
        if found:
            return found, step
    return [], None


def ctl(*argv: str, stdin: str | None = None, timeout: float = 20) -> subprocess.CompletedProcess[str]:
    cmd = [AGTERMCTL, *argv]
    if os.environ.get("AGT_SOCKET"):
        cmd += ["--socket", os.environ["AGT_SOCKET"]]
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout, check=False)


def target_args() -> list[str]:
    args = ["--target", os.environ["AGT_SESSION_ID"]]
    if os.environ.get("AGT_PANE") in ("left", "right"):
        args += ["--pane", os.environ["AGT_PANE"]]
    return args


def hud(message: str) -> None:
    ctl("session", "hud", message, "--hide-after", HUD_SECONDS, *target_args())


def pick(name: str, candidates: list[str]) -> str | None:
    items = [{"id": c, "label": "~" + c[len(HOME):] if c.startswith(HOME + "/") else c} for c in candidates]
    try:
        window = ["--window", os.environ["AGT_WINDOW_ID"]] if os.environ.get("AGT_WINDOW_ID") else []
        done = ctl("pick", "--prompt", f"Open which {name}?", *window, stdin=json.dumps(items), timeout=600)
    except subprocess.TimeoutExpired:
        return None
    try:
        answer = json.loads(done.stdout) if done.returncode == 0 else {}
    except ValueError:
        return None
    chosen = answer.get("id")
    return chosen if answer.get("result") == "picked" and chosen in candidates else None


def viewer_line(path: str, line: int | None) -> str | None:
    """The overlay's shell line: the template with its program made absolute and each value quoted.

    None when the program is not installed. The overlay runs under the app's own PATH, where a bare
    Homebrew name exits 127 and the overlay flashes open and vanishes.
    """
    words = shlex.split(VIEWER)
    if not words:
        return None
    program = shutil.which(words[0], path=os.pathsep.join(
        [os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin"]))
    if not program:
        return None
    values = {"{path}": path, "{line}": str(line or 1)}
    out = [program]
    for word in words[1:]:
        for key, value in values.items():
            word = word.replace(key, value)
        out.append(word)
    return shlex.join(out)


def main(argv: list[str]) -> int:
    if argv[:1] == ["--test"]:
        return run_tests()
    if "AGT_SESSION_ID" not in os.environ or not os.environ["AGT_SESSION_ID"]:
        print("run from an agterm keymap command, in a session", file=sys.stderr)
        return 2
    raw = argv[0] if argv else os.environ.get("AGT_SELECTION", "")
    parsed = parse_selection(raw)
    if not parsed:
        hud("Select a file path first" if not raw.strip() else f"Not a file path: {raw.strip()[:80]}")
        return 1
    path, line = parsed
    cwd = os.environ.get("AGT_SESSION_PWD") or ""
    candidates, step = resolve(path, cwd) if cwd or path.startswith(("~/", "/")) else ([], None)
    if not candidates:
        hud(f"File not found: {path}")
        return 1
    if len(candidates) == 1 and step != "spotlight":
        chosen: str | None = candidates[0]
    else:
        chosen = pick(os.path.basename(path), candidates)
        if not chosen:
            return 0
    command = viewer_line(chosen, line)
    if not command:
        hud(f"Viewer not installed: {(shlex.split(VIEWER) or ['?'])[0]}")
        return 1
    done = ctl("session", "overlay", "open", command, "--cwd", os.path.dirname(chosen),
               "--size-percent", OVERLAY_PERCENT, *target_args())
    return 0 if done.returncode == 0 else 1


class Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "docs", "plans"))
        os.makedirs(os.path.join(self.repo, "src", "app"))
        for rel in ("docs/plans/x-spec.md", "src/app/Model.swift", "README.md"):
            open(os.path.join(self.repo, rel), "w").close()
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        subprocess.run(["git", "-C", self.repo, "add", "."], check=True)
        subprocess.run(["git", "-C", self.repo, "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-qm", "init"], check=True)
        os.environ["OPEN_PATH_MDFIND"] = "false"

    def real(self, rel: str) -> str:
        return os.path.realpath(os.path.join(self.repo, rel))

    def test_selection_parsing(self) -> None:
        self.assertEqual(parse_selection("  src/app/Model.swift:566  "), ("src/app/Model.swift", 566))
        self.assertEqual(parse_selection("`docs/plans/x-spec.md`."), ("docs/plans/x-spec.md", None))
        self.assertEqual(parse_selection("src/a.ts:10-20"), ("src/a.ts", 10))
        self.assertEqual(parse_selection("README.md"), ("README.md", None))
        self.assertEqual(parse_selection("/Users/me/Library/Application Support/x.json"),
                         ("/Users/me/Library/Application Support/x.json", None))
        for bad in ("", "two words here", "-rf/x", "a\nb", "src/x:0", "docs/$HOME/x", "x;y/z"):
            self.assertIsNone(parse_selection(bad), bad)

    def test_pane_directory_then_git_root(self) -> None:
        sub = os.path.join(self.repo, "src")
        self.assertEqual(resolve("app/Model.swift", sub), ([self.real("src/app/Model.swift")], "pane directory"))
        self.assertEqual(resolve("docs/plans/x-spec.md", sub), ([self.real("docs/plans/x-spec.md")], "git root"))

    def test_repo_suffix_finds_a_path_printed_from_deeper(self) -> None:
        self.assertEqual(resolve("plans/x-spec.md", self.repo), ([self.real("docs/plans/x-spec.md")], "repo suffix"))

    def test_main_checkout_of_a_worktree(self) -> None:
        tree = os.path.join(self.tmp, "wt")
        subprocess.run(["git", "-C", self.repo, "worktree", "add", "-q", tree], check=True)
        open(os.path.join(self.repo, "untracked.md"), "w").close()
        self.assertEqual(resolve("untracked.md", tree), ([self.real("untracked.md")], "main checkout"))

    def test_linked_worktrees_of_the_repo(self) -> None:
        trees = [os.path.join(self.tmp, name) for name in ("wt-a", "wt-b")]
        for tree in trees:
            subprocess.run(["git", "-C", self.repo, "worktree", "add", "-q", tree], check=True)
        open(os.path.join(trees[0], "only-a.md"), "w").close()
        found = [os.path.realpath(os.path.join(trees[0], "only-a.md"))]
        self.assertEqual(resolve("only-a.md", self.repo), (found, "linked worktree"))
        self.assertEqual(resolve("only-a.md", trees[1]), (found, "linked worktree"))
        open(os.path.join(trees[1], "only-a.md"), "w").close()
        self.assertEqual(len(resolve("only-a.md", self.repo)[0]), 2)

    def test_missing_file_finds_nothing(self) -> None:
        self.assertEqual(resolve("docs/nope.md", self.repo), ([], None))

    def test_viewer_line_quotes_the_path(self) -> None:
        global VIEWER
        saved, VIEWER = VIEWER, "sh -c {path} +{line}"
        try:
            line = viewer_line("/tmp/a b; id", None) or ""
            self.assertTrue(line.endswith(" '/tmp/a b; id' +1"), line)
            self.assertTrue(os.path.isabs(shlex.split(line)[0]))
        finally:
            VIEWER = saved


def run_tests() -> int:
    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

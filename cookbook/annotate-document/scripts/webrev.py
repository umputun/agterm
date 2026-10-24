#!/usr/bin/env python3
"""Review a markdown or text file in an agterm HTML overlay and print the annotations.

Usage:
    webrev.py review FILE [--pane left|right] [--output PATH] [--title T] [--size N | --fit]
                                                                open the page, wait, print annotations
    webrev.py result PAGE_ID                                    read the outcome of an earlier page
    webrev.py render FILE OUT                                   write the page without opening it

Exit codes: 0 submitted (stdout holds annotations, empty when none), 2 dismissed, 1 error or pending.
"""

import argparse
import html
import json
import math
import os
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import NoReturn

ASSETS = Path(__file__).resolve().parent.parent / "assets"
MARKDOWN_IT = ASSETS / "markdown-it-14.1.0.min.js"
HIGHLIGHT = ASSETS / "highlight-11.11.1.min.js"
TEMPLATE = ASSETS / "page.html"
MARKDOWN_EXT = {".md", ".markdown", ".mdx"}
STYLES = ("", "terminal")
POLL_SECONDS = 1.0
AGTERM_STATE_DEFAULT = Path.home() / "Library" / "Application Support" / "agterm"
# short-draft geometry in points (--fit), measured at agterm's default HTML zoom of 1.0 and rounded up to fit both
# looks: plain text is hard-wrapped at 80 columns, markdown wraps to the window, so its width follows its longest line
FIT_TEXT_COLUMNS = 80
FIT_MIN_COLUMNS = 60
FIT_MAX_COLUMNS = 100
FIT_BASE_WIDTH = 170
FIT_COLUMN_WIDTH = 8.4
FIT_BASE_HEIGHT = 113
FIT_ROW_HEIGHT = 18.9


@dataclass
class PageData:
    path: str
    kind: str
    source: str
    nonce: str
    sidebar_shift: float = 0.0
    title: str = ""
    style: str = ""


@dataclass
class ReviewOptions:
    pane: str | None = None
    output: Path | None = None
    title: str = ""
    size: int = 95
    fit: bool = False


def display_path(path: Path) -> str:
    """Return the path as annotations name it: relative to cwd when inside it, absolute otherwise."""
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(absolute)


def agterm_settings() -> Path:
    state = os.environ.get("AGTERM_STATE_DIR")
    return (Path(state) if state else AGTERM_STATE_DEFAULT) / "settings.json"


def sidebar_shift(settings: Path) -> float:
    """Mirror agterm's sidebar tint formula."""
    try:
        strength = json.loads(settings.read_text(encoding="utf-8")).get("sidebarBackgroundShift", 5)
        return (min(10, max(0, int(strength))) - 5) * 0.06
    except (OSError, ValueError, TypeError, AttributeError):
        return 0.0


def page_style() -> str:
    """Return the page look from WEBREV_STYLE: empty for the default, "terminal" for the flat revdiff-like one."""
    style = os.environ.get("WEBREV_STYLE", "")
    if style not in STYLES:
        raise ValueError(f"WEBREV_STYLE={style!r} is not supported, use terminal or leave it unset")
    return style


def build_page(data: PageData) -> str:
    """Return the self-contained review page for one document."""
    libs = {}
    for name, path in (("MARKDOWN_IT", MARKDOWN_IT), ("HIGHLIGHT", HIGHLIGHT)):
        libs[name] = path.read_text(encoding="utf-8")
        if "</script" in libs[name].lower():
            raise ValueError(f"{path} contains </script and cannot be inlined")
    payload = json.dumps(asdict(data))
    # json escapes nothing that ends a script element, so "<" is encoded to keep "</script>" in a document inert
    payload = payload.replace("<", "\\u003c")
    page = TEMPLATE.read_text(encoding="utf-8")
    page = page.replace("__WEBREV_TITLE__", html.escape(data.title or Path(data.path).name))
    page = page.replace("__WEBREV_STYLE__", html.escape(data.style))
    for name, lib in libs.items():
        page = page.replace(f"/*__WEBREV_{name}__*/", lib)
    # the document goes in last, so placeholder text inside it is never substituted
    return page.replace("__WEBREV_DATA__", payload)


def doc_kind(file: Path) -> str:
    return "markdown" if file.suffix.lower() in MARKDOWN_EXT else "text"


def render(file: Path, out: Path, title: str = "") -> None:
    """Write the review page for file to out."""
    source = file.read_text(encoding="utf-8")
    kind = doc_kind(file)
    data = PageData(display_path(file), kind, source, uuid.uuid4().hex, sidebar_shift(agterm_settings()), title, page_style())
    out.write_text(build_page(data), encoding="utf-8")


def fit_lines(source: str) -> list[str]:
    text = source.replace("\r\n", "\n")
    return text.removesuffix("\n").split("\n")


def fit_columns(source: str, kind: str) -> int:
    """Return the text columns a short draft gets: 80 for plain text, its longest line within 60..100 for markdown."""
    if kind != "markdown":
        return FIT_TEXT_COLUMNS
    longest = max(len(line) for line in fit_lines(source))
    return min(FIT_MAX_COLUMNS, max(FIT_MIN_COLUMNS, longest))


def fit_rows(source: str, columns: int) -> int:
    """Count the rows a short draft renders at columns: one per line, a longer line wrapping onto more."""
    return sum(max(1, math.ceil(len(line) / columns)) for line in fit_lines(source))


def fit_size(source: str, kind: str) -> tuple[int, int]:
    """Return the overlay (width, height) in points for a short draft; agterm clamps each to 80% of the session."""
    cols = fit_columns(source, kind)
    width = math.ceil(FIT_BASE_WIDTH + FIT_COLUMN_WIDTH * cols)
    return width, math.ceil(FIT_BASE_HEIGHT + FIT_ROW_HEIGHT * fit_rows(source, cols))


def page_zoom(page_id: str) -> float:
    try:
        win = os.environ.get("AGTERM_WINDOW_ID")
        tree = json.loads(agtermctl("tree", "--json", *(["--window", win] if win else [])).stdout)
    except json.JSONDecodeError:
        return 1.0
    nodes = [tree]
    while nodes:
        node = nodes.pop()
        if isinstance(node, list):
            nodes.extend(node)
            continue
        if not isinstance(node, dict):
            continue
        for page in node.get("htmlOverlays") or []:
            if isinstance(page, dict) and page.get("id") == page_id and isinstance(page.get("zoom"), (int, float)):
                return float(page["zoom"])
        nodes.extend(node.values())
    return 1.0


def zoom_fit(page_id: str, session: str, width: int, height: int) -> None:
    """agterm exposes page zoom only after the page opens."""
    zoom = page_zoom(page_id)
    if zoom <= 0 or zoom == 1:
        return
    res = agtermctl("session", "overlay", "resize", "--size-percent", "95", "--width", str(math.ceil(width * zoom)),
                    "--height", str(math.ceil(height * zoom)), "--target", session)
    if res.returncode != 0:
        print(f"webrev: zoom resize failed: {(res.stderr or res.stdout).strip()}", file=sys.stderr)


def agtermctl(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the agterm CLI; it never reads AGTERM_SOCKET, so a session on a custom socket is passed one."""
    cmd = [os.environ.get("AGTERMCTL") or "agtermctl", *args]
    if sock := os.environ.get("AGTERM_SOCKET"):
        cmd += ["--socket", sock]
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def read_outcome(page_id: str) -> tuple[str, str]:
    """Return (state, text): submitted with the annotations, dismissed, pending, or error with its message."""
    res = agtermctl("session", "overlay", "result", "--page", page_id)
    try:
        outcome = json.loads(res.stdout)
    except json.JSONDecodeError:
        return "error", (res.stderr or res.stdout).strip() or f"agtermctl exited {res.returncode}"
    state = outcome.get("outcome", "")
    if state not in ("submitted", "dismissed", "pending"):
        return "error", f"unexpected outcome: {res.stdout.strip()}"
    return state, outcome.get("value", "")


def exit_for(state: str, text: str) -> int:
    """Print an outcome the way the skill reads it and return its exit code."""
    if state == "submitted":
        sys.stdout.write(text)
        return 0
    print(f"webrev: {text or state}", file=sys.stderr)
    return 2 if state == "dismissed" else 1


def write_backup(path: Path, state: str, text: str) -> None:
    """Write an outcome to the backup file: annotations as-is, otherwise a "pending <id>" or "dismissed" line.

    Annotations always start with "## " or are empty, so the three forms cannot be mistaken for each other.
    """
    body = text if state == "submitted" else f"{state} {text}".strip() + "\n"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    tmp.replace(path)


def wait_outcome(page_id: str, session: str, pane: str) -> tuple[str, str]:
    """keep both status writes on the same pane; agterm rejects another pane's reset."""
    target = ["--target", session]
    if pane in ("left", "right", "scratch"):
        target += ["--pane", pane]
    if pane_id := os.environ.get("AGTERM_PANE_ID"):
        target += ["--pane-id", pane_id]
    agtermctl("session", "status", "blocked", "--blink", *target)
    prev = signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        state, text = read_outcome(page_id)
        while state == "pending":
            time.sleep(POLL_SECONDS)
            state, text = read_outcome(page_id)
        return state, text
    finally:
        signal.signal(signal.SIGTERM, prev)
        # idle, not a saved snapshot: replaying one could claim another pane's block,
        # and an agent's own status hooks set its next state
        agtermctl("session", "status", "idle", *target)


def review(file: Path, opts: ReviewOptions) -> int:
    session = os.environ.get("AGTERM_SESSION_ID")
    if not session:
        print("webrev: AGTERM_SESSION_ID is not set; it names the agterm session to open the page in", file=sys.stderr)
        return 1
    workdir = Path(tempfile.gettempdir()) / "webrev"
    workdir.mkdir(exist_ok=True)
    page_file = workdir / f"{uuid.uuid4().hex}.html"
    render(file, page_file, opts.title)
    cmd = ["session", "overlay", "open", "--html", str(page_file), "--chromeless", "--js", "--target", session, "--json"]
    # agterm refuses --size-percent with --pane, a pane overlay is always full; it takes points only with a percent
    if opts.pane:
        cmd += ["--pane", opts.pane]
    elif opts.fit:
        width, height = fit_size(file.read_text(encoding="utf-8"), doc_kind(file))
        cmd += ["--size-percent", "95", "--width", str(width), "--height", str(height)]
    else:
        cmd += ["--size-percent", str(opts.size)]
    res = agtermctl(*cmd)
    if res.returncode != 0:
        print(f"webrev: overlay open failed: {(res.stderr or res.stdout).strip()}", file=sys.stderr)
        page_file.unlink(missing_ok=True)
        return 1
    page_id = json.loads(res.stdout)["result"]["pageID"]
    print(f"webrev: page {page_id}", file=sys.stderr, flush=True)
    if opts.fit:
        zoom_fit(page_id, session, width, height)
    if opts.output:
        write_backup(opts.output, "pending", page_id)
    state, text = wait_outcome(page_id, session, opts.pane or os.environ.get("AGTERM_PANE", ""))
    # the file backs theme reloads while the page is up, so a killed waiter or a failed read leaves it
    if state in ("submitted", "dismissed"):
        page_file.unlink(missing_ok=True)
        if opts.output:
            write_backup(opts.output, state, "" if state == "dismissed" else text)
    return exit_for(state, text)


def result(page_id: str) -> int:
    return exit_for(*read_outcome(page_id))


def size_percent(value: str) -> int:
    """Parse --size within the 1..100 agterm accepts for --size-percent."""
    n = int(value)
    if not 1 <= n <= 100:
        raise argparse.ArgumentTypeError(f"{n} is outside 1..100")
    return n


class Parser(argparse.ArgumentParser):
    """Exit 1 on a usage error; callers read 2 as a review the user cancelled."""

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        print(f"webrev: {message}", file=sys.stderr)
        sys.exit(1)


def main() -> int:
    parser = Parser(description="review a file in an agterm overlay")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_review = sub.add_parser("review", help="open the page and wait for annotations")
    p_review.add_argument("file", type=Path)
    p_review.add_argument("--pane", choices=["left", "right"])
    p_review.add_argument("--output", type=Path, help="backup file for the outcome, read when the waiter gave up")
    p_review.add_argument("--title", default="", help="header title instead of the file name, for generated content")
    p_review.add_argument("--size", type=size_percent, help="overlay size in percent, 1..100 (default 95)")
    p_review.add_argument("--fit", action="store_true", help="size the overlay for a short draft: 80 columns wide, as tall as its text")
    p_result = sub.add_parser("result", help="read the outcome of an earlier page")
    p_result.add_argument("page_id")
    p_render = sub.add_parser("render", help="write the page without opening it")
    p_render.add_argument("file", type=Path)
    p_render.add_argument("out", type=Path)
    p_render.add_argument("--title", default="")
    args = parser.parse_args()
    if args.cmd == "review" and args.fit and (args.size is not None or args.pane):
        print("webrev: --fit sizes the overlay itself and cannot be combined with --size or --pane", file=sys.stderr)
        return 1
    try:
        if args.cmd == "review":
            size = 95 if args.size is None else args.size
            return review(args.file, ReviewOptions(args.pane, args.output, args.title, size, args.fit))
        if args.cmd == "result":
            return result(args.page_id)
        render(args.file, args.out, args.title)
        return 0
    except (OSError, ValueError, KeyError) as e:
        print(f"webrev: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""embed-md.py puts an agdoc page's markdown translation into the page as a collapsed, copyable box.

usage: embed-md.py PAGE.html PAGE.md [--test]   rewrites PAGE.html in place, replacing an earlier box
"""

from __future__ import annotations

import html
import os
import re
import sys
import tempfile
from pathlib import Path

START, END = "<!-- agdoc:md -->", "<!-- /agdoc:md -->"
BLOCK_RE = re.compile(re.escape(START) + r".*?" + re.escape(END) + r"\n?", re.DOTALL)
ANCHOR_RE = re.compile(r"<footer\b|</main>")


def block(source: str) -> str:
    # the parser drops one newline right after <textarea>, so the one written here keeps a leading
    # newline in the source intact
    return (f'{START}\n<details class="md-copy">\n'
            "<summary>Markdown copy</summary>\n"
            f'<textarea readonly spellcheck="false">\n{html.escape(source, quote=False)}</textarea>\n'
            f"</details>\n{END}\n")


def embed(page: str, source: str) -> str:
    page = BLOCK_RE.sub("", page)
    # the first of <footer or </main> keeps the box inside the content column for every design:
    # editorial closes main before its footer, classic and brief put the footer last
    m = ANCHOR_RE.search(page)
    if not m:
        raise RuntimeError("page has no <footer> or </main> to place the markdown box before")
    return page[:m.start()] + block(source) + page[m.start():]


def write(page_path: Path, md_path: Path) -> None:
    text = embed(page_path.read_text(encoding="utf-8"), md_path.read_text(encoding="utf-8"))
    fd, tmp = tempfile.mkstemp(dir=page_path.parent, prefix=f".{page_path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, page_path)
    except BaseException:
        os.unlink(tmp)
        raise


def main(argv: list[str]) -> int:
    if argv == ["--test"]:
        return run_tests()
    if len(argv) != 2 or not argv[0].endswith(".html") or not argv[1].endswith(".md") \
            or not all(Path(a).is_file() for a in argv):
        print("usage: embed-md.py PAGE.html PAGE.md", file=sys.stderr)
        return 2
    try:
        write(Path(argv[0]), Path(argv[1]))
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 1
    print(argv[0])
    return 0


def run_tests() -> int:
    import unittest

    assets = Path(__file__).resolve().parent.parent / "assets"

    def textarea_value(page: str) -> str:
        m = re.search(r'<details class="md-copy">.*?<textarea[^>]*>(.*?)</textarea>', page, re.DOTALL)
        assert m, "no markdown textarea"
        raw = m.group(1)
        return html.unescape(raw.removeprefix("\n"))

    class EmbedTest(unittest.TestCase):
        def test_source_round_trips_exactly(self) -> None:
            source = "\n**Title** & more\n\nclose </textarea> here, Привет ✓ <!-- /agdoc:md -->\n"
            page = embed("<main><p>x</p></main><footer>f</footer>", source)
            self.assertEqual(source, textarea_value(page))
            self.assertEqual(1, page.count("</textarea>"))

        def test_reembed_replaces_the_box(self) -> None:
            page = embed(embed("<main></main><footer>f</footer>", "one\n"), "two\n")
            self.assertEqual(1, page.count(START))
            self.assertEqual("two\n", textarea_value(page))
            self.assertEqual(embed("<main></main><footer>f</footer>", "two\n"), page)

        def test_placed_before_first_of_footer_or_main_end(self) -> None:
            for name in ("editorial", "classic", "brief", "custom"):
                with self.subTest(name):
                    page = embed((assets / f"{name}.html").read_text(encoding="utf-8"), "md\n")
                    at = page.index(START)
                    after = page[at + len(block("md\n")):]
                    self.assertIsNotNone(ANCHOR_RE.match(after))
                    self.assertIsNone(ANCHOR_RE.search(page[:at]))

        def test_templates_style_the_box(self) -> None:
            for name in ("editorial", "classic", "brief", "custom"):
                with self.subTest(name):
                    self.assertIn(".md-copy textarea", (assets / f"{name}.html").read_text(encoding="utf-8"))

        def test_page_without_anchor_fails(self) -> None:
            with self.assertRaises(RuntimeError):
                embed("<div>no end</div>", "md\n")

        def test_failed_write_keeps_page(self) -> None:
            with tempfile.TemporaryDirectory() as d:
                page, md = Path(d) / "p.html", Path(d) / "p.md"
                page.write_text("<div>no end</div>")
                md.write_text("md\n")
                with self.assertRaises(RuntimeError):
                    write(page, md)
                self.assertEqual("<div>no end</div>", page.read_text())
                self.assertEqual(["p.html", "p.md"], sorted(p.name for p in Path(d).iterdir()))

    suite = unittest.TestLoader().loadTestsFromTestCase(EmbedTest)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Assemble the figures referenced by the design report, in reading order."""
from pathlib import Path
import re

import fitz


def main():
    here = Path(__file__).resolve().parent
    preview = fitz.open()
    bookmarks = []
    for chapter in sorted((here.parent / "chapters").glob("ch*.tex")):
        chapter_number = int(chapter.stem[2:])
        figures = re.finditer(
            r"\\figN(?:\[([^\]]*)\])?\{([^}]+)\}", chapter.read_text()
        )
        for number, match in enumerate(figures, 1):
            title, stem = match.groups()
            with fitz.open(here / "pdf" / f"{stem}.pdf") as figure:
                page = len(preview) + 1
                preview.insert_pdf(figure)
            label = (title or stem).replace(r"\_", "_")
            bookmarks.append([1, f"图 {chapter_number}-{number}  {label}", page])
    preview.set_toc(bookmarks)
    preview.set_metadata({"title": "AFDX 设计报告机制配图", "subject": "按报告顺序逐图审阅"})
    output = here / "配图审阅.pdf"
    preview.save(output, garbage=4, deflate=True)
    print(f"{len(preview)} figures: {output}")
    preview.close()


if __name__ == "__main__":
    main()

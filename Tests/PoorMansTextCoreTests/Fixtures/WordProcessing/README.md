# Word-processing fixtures

The fixtures exercise headings, Unicode text, emphasis, links, lists, a table,
a footnote where the producer supports it, and an embedded PNG.

- `pandoc.docx` and `pandoc.odt` were written by Pandoc 3.9.0.2 from `source.md`.
- `libreoffice.docx` and `libreoffice.odt` were resaved by LibreOfficeDev 26.8
  from the corresponding Pandoc fixture.
- `textutil.docx`, `textutil.odt`, and `textutil.doc` were written by the macOS
  text system from `source.html`.
- `libreoffice.doc` was written by LibreOfficeDev 26.8 from `pandoc.odt`.

They were generated on 2026-07-25 and are deliberately versioned so CI tests two
independent producers per format without requiring LibreOffice at test time.

`annotated.docx`, `external-image.docx`, and `unsafe-path.docx` are controlled
variants of `pandoc.docx`: they add tracked-change/comment markup, an external
image relationship, or a traversal entry for deterministic safety tests.
`annotated.odt` and `external-image.odt` similarly add an annotation with tracked
changes or an external image reference to `pandoc.odt`.

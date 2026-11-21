<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="Poor Man's Text app icon">
</p>

# Poor Man’s Text

[English](README.md) · [Deutsch](README.de.md)

Convert documents to Markdown and extract fields from PDF invoices and delivery
notes to JSON. Poor Man’s Text includes a desktop app and the `poormans-text`
command-line tool on macOS and Linux.

## Download and install

The [latest release](../../releases/latest) provides a notarized Universal DMG
for macOS 13 and later, plus x86-64 Linux packages and portable archives.
Download the installer or archive and its matching `.sha256` file.

**macOS.** Verify the download with
`shasum -a 256 -c Poor-Mans-Text-0.41.26.dmg.sha256`. Open the DMG and drag the
app to Applications. The app can link its bundled CLI into a directory on
`PATH`. Pandoc is available from its [official installer](https://pandoc.org/installing.html)
or through Homebrew. The app offers installation help on startup if Pandoc is
missing.

**Linux.** Verify the download with `sha256sum -c`. Install the DEB with
`sudo apt install ./poormans-text_0.41.26-1_amd64.deb`, or install the Arch
package with `sudo pacman -U ./poormans-text-0.41.26-1-x86_64.pkg.tar.zst`.
From a portable archive, run `usr/bin/poormans-text-app` for GTK or
`usr/bin/poormans-text` for the CLI. [Linux dependencies and installation](docs/LINUX-BUILD.md)

Run `poormans-text --formats` to see which imports are available on your system.
Pandoc handles formats such as DOCX, ODT, RTF, HTML and EPUB. Spreadsheet and
presentation imports use built-in readers. PDF, image and legacy Word imports
use platform backends listed in the format catalog.

The macOS app checks a signed update feed through Sparkle. You confirm any
download or installation. See [privacy and update settings](PRIVACY.md).

## Convert a document

Drop a file or folder into the app, or use **Choose Document**. Pick an output
folder and conversion options before starting. Open the result in the default
Markdown editor or directly in Fastra if it is installed. On macOS you can
also convert through the Finder service or the Shortcuts actions.

In a terminal:

```sh
poormans-text Report.docx
poormans-text --output ./Converted --jobs 2 ./SourceFiles
poormans-text --textbundle Presentation.pptx
poormans-text --stdout table.csv
```

A single input normally produces a sibling like `Report-markdown/Report.md`.
Images and attachments are stored alongside the Markdown. A folder input
searches for supported documents and mirrors its subfolders in the batch output.
Each result is published only after conversion finishes. The source bytes and
any existing result folders stay intact.

Textbundle packages Markdown and assets together. Use `--frontmatter` to include
available document metadata. `--stdout` emits the Markdown of one document.
Select a folder or Textbundle when the output needs image or attachment files
or contains multiple documents.

## Supported inputs

| Input | Formats |
| --- | --- |
| Word processing | RTF, RTFD, DOCX, DOCM, DOTX, DOTM, ODT, legacy DOC, ODM |
| Spreadsheets and tables | ODS, XLSX, XLSM, XLTX, XLTM, XLS, CSV, TSV |
| Slides and notebooks | PPTX, PPTM, POTX, ODP, IPYNB |
| PDF and images | PDF, PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP |
| Web and text | HTML, Safari web archives, EPUB, LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText, FictionBook |
| Mail and notes | EML, EMLX, Outlook MSG, MBOX and Apple Mail exports, Evernote ENEX |

Markdown preserves text and structure such as headings, lists, simple emphasis,
links and images. Page layout, fonts and some document features cannot be
represented exactly. The result includes diagnostics for known losses, fallbacks
and unsupported content. Notebook output is imported as data. Conversion uses
local resources and keeps preview links inactive.

- [DOCX comments and tracked changes](docs/DOCX-REVIEWS.md)
- [PDF text, page selection and OCR](docs/PDF-IMPORT.md) · [Structured OCR](docs/STRUCTURED-OCR.md)
- [Image import](docs/IMAGE-IMPORT.md) · [Clipboard import](docs/CLIPBOARD-IMPORT.md)
- [Spreadsheets](docs/SPREADSHEET-IMPORT.md) · [Presentations](docs/PRESENTATION-IMPORT.md) · [Notebooks](docs/NOTEBOOK-IMPORT.md)
- [Document collections](docs/COLLECTIONS.md) · [MBOX](docs/MBOX.md) · [ENEX](docs/ENEX.md)

## Choose content and save settings

Use **Select Content** to inspect PDF pages, spreadsheet sheets, presentation
slides or EPUB chapters before conversion. The CLI accepts selections such as
`--pdf-pages 2-4`, `--sheet-name Budget`, `--slides 1,3-5` and
`--epub-chapters 2,4`. See the guides for
[sheets and cell ranges](docs/SPREADSHEET-SELECTION.md),
[slides](docs/PRESENTATION-SELECTION.md) and [EPUB chapters](docs/EPUB-SELECTION.md).

Save recurring options as a named profile in the app or with
`poormans-text --save-profile NAME`. Apply a profile with `--profile NAME` and
override individual values on the command line. The **Convert Document with
Profile** Shortcuts action supports **Profile Value**, **On** and **Off**.
[Profiles, portable JSON and source-bound selections](docs/PROFILES.md)

## Preview, compare and automate

The app previews rendered Markdown, source Markdown and supported local assets.
**Compare** verifies the source and result fingerprints before using recorded
positions. PDF pages and image frames support a passive source preview.
[Markdown preview](docs/MARKDOWN-PREVIEW.md) · [Source comparison](docs/SOURCE-COMPARISON.md)

Use `--json` for a machine-readable result. `--source-map` records available
source locations and `--report` writes the diagnostic report into the output
folder. `--formats --json` returns the format catalog. `--help` lists the current
CLI options. [Reports](docs/CONVERSION-REPORT.md) · [Diagnostics](docs/DIAGNOSTICS.md) · [CLI contract for Fastra and other callers](docs/FASTRA-CONTRACT.md)

## Extract fields from receipts

Use **Extract Receipt Data** to create a JSON mask for PDFs with the same
layout. Select fields such as the invoice number or delivery date. Review the
matched words against their positions on each page. **Apply Mask** uses an
existing mask across multiple PDFs.

```sh
poormans-text extract --mask invoice-mask.json --output-dir Results Invoice-4711.pdf Invoice-4712.pdf
```

The editor and CLI use the same masks on both platforms. Extraction reads
embedded PDF text and reports missing or ambiguous fields for review.
[Receipt masks, manual corrections and batch JSON](docs/RECEIPT-EXTRACTION.md)

## Build and test

Build from source with Swift 6.2 or later. Linux GTK builds also require Rust
and the GTK development packages.

```sh
swift test
./build.sh
```

[macOS build and test guide](docs/BUILD-AND-TEST.md) · [Linux build and packaging](docs/LINUX-BUILD.md) · [Architecture](docs/ARCHITECTURE.md)

Source version **0.41.26**. [Release notes](docs/releases/0.41.26.md) · [Changelog](CHANGELOG.md)

## License

**WTFPL**, Version 2. See [LICENSE](LICENSE) for the project license and dependency
notices.

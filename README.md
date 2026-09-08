<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="Poor Man's Text app icon">
</p>

<h1 align="center">Poor Man's Text</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Convert documents, spreadsheets, PDFs, and images to Markdown.</strong>
</p>

Poor Man's Text converts RTF, RTFD, DOCX (including DOCM and DOTX/DOTM), ODT,
legacy Word (`.doc`), ODS, XLSX (including XLSM and XLTX/XLTM), XLS, CSV and
TSV, PPTX/PPTM/POTX and ODP presentations, IPYNB notebooks, OpenDocument master (`.odm`), PDF, HTML and Safari web archives, EPUB,
LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText, FictionBook, and
PNG, JPEG, HEIC, TIFF, GIF, BMP, or WebP images into folders containing
Markdown and any separately stored image assets.

The project provides two interfaces over the same conversion core:

- `poormans-text`, an automation-friendly command-line tool
- a native macOS app for opening or dropping supported documents, spreadsheets, PDFs, and images

Conversion is deliberately lossy. Markdown can preserve document structure,
links, simple emphasis, lists, and images, but not every font, layout, or
TextKit-specific attribute.

## Output

Converting a supported input creates a new sibling directory without changing
the source. If the input contains extractable images, the result looks like this:

```text
Document-markdown/
├── Document.md
└── images/
    ├── image01.png
    └── image02.jpg
```

Image links in `Document.md` are relative and retain their position in the text.
Extracted images receive stable sequential names instead of carrying technical
attachment names from the source document.
Existing output directories are never overwritten.

Manual line breaks end with two spaces in the generated Markdown. Chromatic
RTFD text is marked as `==text==`. Fastra supports this common Markdown
extension, but it is not part of standard GFM and does not retain the exact
color value. RTF color information cannot be retained by the image-safe import
path; the converter keeps the text and returns a warning instead.

## Requirements

- macOS 13 or newer
- [Pandoc](https://pandoc.org/installing.html) for word-processing and ODM files
- Swift 6.2 or newer when building from source

ODS, XLSX, XLS, CSV, TSV, PPTX/PPTM/POTX, ODP, IPYNB, PDF, and images are
read natively and need no external conversion tool.
For the remaining formats, the converter searches for Pandoc in the common Homebrew
locations and then on `PATH`. The CLI also accepts an explicit executable
through `--pandoc PATH`.

While Pandoc is missing, the app offers at every launch to install it through
Homebrew, or points to the official installation help when Homebrew is absent.
The offer stops once Pandoc exists or after choosing "Don't Ask Again".

## Download

Download the DMG and its `.sha256` file from the
[latest GitHub release](../../releases/latest). With both files in the same
directory, verify the download before opening it:

```sh
shasum -a 256 -c Poor-Mans-Text-0.10.2.dmg.sha256
```

Open the DMG and drag Poor Man's Text to Applications. The app is signed with
Developer ID, notarized by Apple, and includes the matching universal CLI.
Pandoc remains a separate requirement for word-processing and ODM files and can,
for example, be installed with `brew install pandoc`.

## Updates

From 0.7.0 on, the app keeps itself up to date through Sparkle. It checks a
signed update feed on its own and offers "Check for Updates …" in the
application menu; nothing is downloaded or installed without consent. Feed and
disk image must carry a valid Ed25519 signature, and the new version is verified
before it is unpacked. Version 0.6.0 and older have no updater, so 0.7.0 has to
be installed once by hand from the DMG.

The app transmits no profile of the Mac while checking. What GitHub as the host
of feed and download receives is described in [PRIVACY.md](PRIVACY.md), together
with the Terminal command that switches automatic checks off.

## Command line

```sh
poormans-text Document.rtfd
poormans-text Document.rtf
poormans-text Document.docx
poormans-text Document.odt
poormans-text Document.doc
poormans-text Workbook.ods
poormans-text Workbook.xlsx
poormans-text Workbook.xls
poormans-text Book.odm
poormans-text Document.pdf
poormans-text Scan.heic
poormans-text --image-ocr off Photo.jpg
poormans-text --spreadsheet-format tsv Workbook.ods
poormans-text --output Converted Document.rtfd
poormans-text --json Document.rtfd
poormans-text Report.docx Budget.xlsx Scan.pdf
poormans-text --output Converted Documents/
poormans-text --frontmatter Report.docx
poormans-text --textbundle Report.docx
poormans-text --stdout Report.docx | pbcopy
```

The default output directory is `Document-markdown` next to the source. Run
`poormans-text --help` for all options. Without an installation, the same
commands work in a source checkout as `swift run poormans-text …`.

Several inputs, or a folder, are converted sequentially by default; `--jobs 2`
to `--jobs 4` enables parallel conversion. A failure does not stop the remaining
documents. A path that does not exist or a folder
without supported documents is an argument error, though: the run stops
before anything is converted. A folder is searched recursively for
supported file extensions. Packages such as `.rtfd` count as one document,
and hidden entries, symbolic links, and earlier `*-markdown` results are
skipped. With `--output`, the directory becomes the parent that receives one
`Name-markdown` folder per document, mirroring the folder structure. In this
mode `--json` reports `{"ok", "version", "results": [...]}` with one entry per
input, and the exit code is that of the first failed input. A single file keeps
the previous single-document answer unchanged. Two documents that differ only
in their extension, such as `Report.docx` and `Report.odt`, share the name
`Report-markdown`; the second one is reported as an output collision and
nothing is overwritten.

### Frontmatter, Textbundle, and standard output

`--frontmatter` starts the Markdown with a YAML header built from the source:
title, author, subject, description, keywords, and creation and modification
dates, read from OOXML core properties (DOCX, XLSX), OpenDocument `meta.xml`
(ODT, ODS, ODM), the RTF `\info` group (RTF, RTFD), or the PDF information
dictionary. Every value is quoted, dates are ISO 8601 in UTC. A source without
any of these gets a warning instead of an empty header. The same fields appear
as `metadata` in every `--json` answer, whether or not the header was written.

`--textbundle` writes `Report.textbundle` instead of `Report-markdown`: the
Markdown is `text.md`, images live in `assets/`, and `info.json` identifies the
bundle, so Bear, iA Writer, and Ulysses open it directly. With `--output`, the
name has to end in `.textbundle`. Folder searches skip existing bundles.

`--stdout` converts exactly one document in a temporary place, prints the
Markdown to standard output, and removes the temporary result. Diagnostics go
to standard error. Image assets are not kept and are reported; their links stay
in the text. It cannot be combined with `--json`, `--output`, `--textbundle`,
several inputs, or a folder.

Exit codes follow conventional `sysexits` values: `64` for usage errors, `65`
for invalid input data, `66` for a missing input, `69` when Pandoc is not
available, `70` for a failed conversion process, `73` for an output collision,
and `74` for a file-system error. With `--json`, successes and failures are
reported as JSON on standard output; diagnostics otherwise go to standard
error. Inputs are accepted as file-system paths, not through standard input.

### Asking which formats are supported

```sh
poormans-text --formats
poormans-text --formats --json
```

`--formats` never touches a document and always exits `0`. It reports every
format this build can read, its file extensions, whether the source is a single
file or a folder package such as `.rtfd`, the external tools it needs, and
whether those tools are installed right now:

```text
rtf         .rtf                                              file     pandoc           available
rtfd        .rtfd                                             package  pandoc+textutil  available
docx        .docx .docm .dotx .dotm                           file     pandoc           available
odt         .odt                                              file     pandoc           available
doc         .doc                                              file     textutil+pandoc  available
ods         .ods                                              file                      available
xlsx        .xlsx .xlsm .xltx .xltm                           file                      available
xls         .xls                                              file                      available
odm         .odm                                              file     pandoc           available
image       .png .jpg .jpeg .heic .tif .tiff .gif .bmp .webp  file                      available
pdf         .pdf                                              file                      available
pptx        .pptx .pptm .potx                                 file                      available
odp         .odp                                              file                      available
ipynb       .ipynb                                            file                      available
csv         .csv .tsv                                         file                      available
html        .html .htm .xhtml                                 file     pandoc           available
webarchive  .webarchive                                       file     pandoc           available
epub        .epub                                             file     pandoc           available
latex       .tex .latex                                       file     pandoc           available
docbook     .dbk .docbook                                     file     pandoc           available
org         .org                                              file     pandoc           available
mediawiki   .wiki .mediawiki                                  file     pandoc           available
textile     .textile                                          file     pandoc           available
rst         .rst                                              file     pandoc           available
fb2         .fb2                                              file     pandoc           available
```

Without Pandoc, the word-processing, ODM, HTML, e-book, and text-markup lines
read `unavailable (missing required tool: pandoc)`; ODS, XLSX, XLS, CSV, TSV,
PPTX/PPTM/POTX, ODP, IPYNB, PDF, and images remain available. The `textutil` that DOC and RTFD additionally require is part of
macOS.

This is the intended way for another application to decide whether to offer a
conversion. Because the list comes from the converter itself, a host picks up
formats added in a later version without being changed. The extensions are a
fast pre-filter only — the conversion always re-detects the format from the file
contents and reports an honest error when they disagree.

## macOS app

Build the app and CLI from the repository root:

```sh
./build.sh
open "Poor Man's Text.app"
```

`./build.sh` creates the bundle under `.build/app/` and copies it, together with
the CLI, into the repository root. Both copies are ad-hoc signed for local
testing only: they are not a notarized distribution build and must not be copied
to `/Applications`.

Drop any number of supported documents, spreadsheets, presentations, notebooks,
PDFs, images, or folders
into the window or onto the app, or choose them from the open panel. A folder is
searched with the same rules as on the command line. Conversion Options remembers
an output parent (by default next to each source), table format, image OCR,
frontmatter, Textbundle, PDF OCR/layout, OCR languages, and batch parallelism. Subdirectories are preserved under a selected parent.
Select a batch result to open its Markdown in the default app, copy it, show it
in Finder, or read a text preview limited to 256 KiB. Copying reports omitted
asset files. Retry Failed Inputs retains successful outputs and result order;
a failed input also offers another output name or destination. Existing output
is never replaced. The interface follows the system's English or German language.

The app also registers two system services, available once it has been
launched at least once (macOS lists them under System Settings › Keyboard ›
Keyboard Shortcuts › Services):

- **Convert to Markdown with Poor Man's Text** appears in the Finder context
  menu for supported documents and folders. It hands the selection to the app,
  which uses the current conversion settings, exactly like a drop.
- **Convert Text to Markdown with Poor Man's Text** appears in the Services
  submenu of any app that offers selected rich text, such as Mail, Pages,
  TextEdit, or Safari. The Markdown is placed on the clipboard, ready to paste;
  nothing in the source app is replaced. Images in the selection are left out
  and reported, because the clipboard carries text only. Selections that only
  offer RTF need Pandoc, like `.rtf` files.

While conversion runs, the app shows active files and known page, sheet, slide,
notebook-cell, or image-frame progress. Cancel Conversion retains completed batch results and
removes the current document's workspace without publishing it. Unstarted inputs
remain available for retry. Cancellation waits for an active PDFKit, ImageIO,
or Vision call to return; external tool processes are terminated.

The CLI accepts `--progress` for stderr progress and `--timeout SECONDS` for a
positive time limit per external tool process. SIGINT and SIGTERM request cleanup
and return exit 130; tool timeout returns 124. A timed-out document does not stop
later batch inputs. Captured tool output is limited to 16 MiB per stream.

## Signed installation

The installer builds universal app and CLI binaries, signs both with Developer
ID and the hardened runtime, notarizes and staples the app, and only then
installs the verified bundle:

```sh
NOTARY_PROFILE=<profile> ./install.sh
```

The app is installed as `/Applications/Poor Man's Text.app`. The exact same CLI
embedded in the bundle becomes available on the terminal path as
`poormans-text`. The installer keeps an already installed copy's directory and
otherwise uses the first Homebrew `bin` on your `PATH`; `CLI_INSTALL_DIR`
overrides it. An unrelated existing target is never overwritten. The faster
`./install.sh --no-notarize` path keeps the signed but unnotarized artifacts in
the repository root.

## Release disk image

Building the distribution disk image is a separate entry point that installs
nothing:

```sh
NOTARY_PROFILE=<profile> ./release.sh
```

It runs the same build, signing and notarization path, then creates the signed
disk image, notarizes and staples that image as well, and finally writes
`Poor-Mans-Text-<version>.dmg` and a matching `.sha256` file to the repository
root. Existing artifacts are never overwritten: if the pair for that version is
already there, the run stops.

A full release — disk image, checksum, and the verified installation from the
very same signed bundle — is a single run instead:

```sh
NOTARY_PROFILE=<profile> ./install.sh --with-dmg
```

Users who drag the app from that disk image into `/Applications` are offered an
optional first-launch setup for the embedded CLI. It never replaces another
command-line tool and always asks before requesting administrator privileges.

## Conversion pipeline

RTFD stores text in `TXT.rtf` and keeps attachments as separate files inside a
macOS package. Poor Man's Text uses the macOS text system to create HTML and
materialize those attachments. Standard RTF stores images inside the file;
Pandoc reads that container and extracts its media without a Cocoa round trip.
DOCX, DOCM, DOTX/DOTM, and ODT pass through a shared, sandboxed Pandoc container
adapter that validates every ZIP entry and extracts media only inside the private
work area. Macro-enabled packages and templates are accepted after their OOXML
content type has been checked, with explicit warnings that macros and template
behavior are not retained.

DOC remains a separate legacy adapter: macOS `textutil` creates local HTML, and
the converter warns that OLE objects, text boxes, macros, and some embedded
content may be lost. DOCX tracked changes are explicitly accepted; comments and
accepted changes are reported as diagnostics.

ODS, XLSX, and binary XLS use native readers and a shared workbook model. Each
sheet becomes a Markdown section, in source order, rendered either as a GFM
table or as an escaped TSV code block. Formulas are not calculated; stored
cell results are used. ODM master documents keep their own text and safely
resolve only existing local ODT sections before flattening them in source order.

PDF uses PDFKit for embedded text. Automatic OCR renders pages with larger
embedded images or fewer than 20 extracted characters and reads them locally
with Vision. The Markdown keeps explicit page sections. Password-protected PDFs, more than 1,000 pages, and OCR work above the
64-million-pixel budget are rejected before publication. Neither PDFKit nor Vision
opens remote content.

CSV and TSV become a one-sheet workbook rendered like ODS or XLSX. The
extension selects the format, because plain text cannot be recognized as a
table by content; `.tsv` splits on tabs and `.csv` picks the separator that is
most consistent across the first lines. A byte-order mark selects UTF-8 or
UTF-16, text that is not valid UTF-8 is read as Windows-1252 with a warning,
and binary content is rejected.

HTML, Safari web archives, EPUB, LaTeX, DocBook, Org, MediaWiki, Textile,
reStructuredText, and FictionBook go through Pandoc in sandbox mode, which
also stops LaTeX `\input` from reading other files. HTML is recognized by
content; the text markups need their extension, and a `.xml` file counts as
DocBook only with the DocBook namespace. Images next to the source are copied
when they live below the source's folder; embedded `data:` images are
extracted; remote images are never fetched and become plain links; missing
images are dropped and leave their alt text. Web archives use their own stored
images. Scripts, styles, forms, and page layout are not represented, and an
EPUB is flattened into one Markdown file.

Image import stores PNG, JPEG, HEIC, TIFF, GIF, BMP, and WebP bytes unchanged as an `images/`
asset and writes a relative Markdown image reference. By default Vision adds local
OCR text below it. `--image-ocr off` retains only the image, which is useful when
the source contains handwriting, a diagram, or text that should not become
searchable Markdown. The macOS app exposes the same choice before conversion.
TIFF uses one retained asset and a separate OCR section for
each frame. Image dimensions and all frames share the same 16-million-per-frame
and 64-million-pixel OCR budgets as PDF fallback; exceeding them rejects OCR mode
before publication. Low-confidence OCR is marked in the Markdown for review.

The format-neutral engine verifies source contents instead of trusting only the
filename extension, then selects the matching path. Word-processing paths
validate and rewrite image references before Pandoc creates GitHub-Flavored
Markdown; native spreadsheet paths do not start Pandoc.

The conversion runs in a private staging directory and moves the completed
result into a persistent or caller-owned temporary destination only after all
stages succeed. Remote image references are rejected rather than downloaded.
Attachments that cannot be represented in the generated Markdown produce warnings.

## Format support and limitations

Typically preserved:

- paragraphs and manual line breaks using two trailing spaces
- bold and italic text
- chromatic RTFD text using `==text==` markers
- hyperlinks in word-processing documents
- simple ordered and unordered lists
- semantic headings, footnotes, and simple tables in DOCX and ODT
- image order and relative image references
- stored spreadsheet values, sheet names, sheet order, empty cells, internal line breaks,
  and one hyperlink target per cell
- local ODM section order
- embedded PDF text in page order, with page sections
- byte-identical PNG, JPEG, HEIC, and TIFF assets, with optional local OCR text

Expected losses or approximations:

- font families, grayscale and exact color values, and exact font sizes
- exact image dimensions
- page geometry and paragraph alignment
- complex tables, text boxes, and multi-column layouts
- equations and application-specific rich-text attributes
- semantic heading levels when the source only expresses larger font sizes
- DOCX/ODT comments and DOC change markup
- DOC OLE objects, text boxes, macros, and images unsupported by `textutil`
- DOCM/DOTM macros and DOTX/DOTM template behavior
- spreadsheet formulas without stored results, merged-cell structure, charts,
  drawings, comments, macros, and exact formatting
- multiple different hyperlink targets in one spreadsheet cell; the first target
  and all visible text stay, while the additional target is reported as a warning
- ODM section boundaries and master-document behavior after flattening
- complex PDF page layout, tables, and exact text placement;
  local OCR can contain recognition errors and needs review
- image OCR reading order and exact layout; the retained original image remains
  the authoritative source for review

## Development

```sh
./build.sh
swift test
./install.sh --no-notarize
```

See [docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md) for build, signing, and
installation details. Image import is described in
[docs/IMAGE-IMPORT.md](docs/IMAGE-IMPORT.md); PDF import is described in
[docs/PDF-IMPORT.md](docs/PDF-IMPORT.md). The implemented workbook model, two table representations,
and multi-sheet behavior are described in
[docs/SPREADSHEET-IMPORT.md](docs/SPREADSHEET-IMPORT.md).

The test suite creates real temporary Cocoa RTFD packages and monolithic RTF
files with formatting, colors, empty lines, links, lists, Unicode filenames,
and embedded images. Versioned DOCX, ODT, and binary DOC fixtures from independent
producers cover headings, footnotes, tables, lists, links, comments, tracked
changes, Unicode, and media hashes. Native spreadsheet tests cover real ODS and
XLS files, generated XLSX packages, sheet order, cell budgets, hyperlink targets,
warnings, and an independent Pandoc comparison. ODM tests use local linked ODT files. Tests also
cover real temporary PDFs with embedded text, empty OCR pages, encryption, page
and pixel budgets. Image tests generate PNG and multi-frame TIFF fixtures, compare
their preserved asset bytes, and exercise both OCR modes. They also cover output collisions, malformed or unsafe packages, missing dependencies,
the CLI-link guard, and the app's `NSItemProvider` drop path.

The current version is 0.10.2.

## License

Poor Man's Text is released under the **WTFPL**, Version 2
(Do What The Fuck You Want To Public License) — see [LICENSE](LICENSE).
The app-icon provenance is documented in [ASSETS.md](ASSETS.md).

Pandoc is an external runtime dependency and is not bundled with Poor Man's
Text. Pandoc remains subject to its own license.

The updater [Sparkle](https://sparkle-project.org) is bundled and remains
subject to its own license, which ships with the app as
`Contents/Resources/Sparkle-LICENSE.txt`.

Poor Man's Text processes documents locally and includes no telemetry. Its only
network access is the update check. Details are in [PRIVACY.md](PRIVACY.md);
support information is in [SUPPORT.md](SUPPORT.md).

### PDF text and OCR options

`--pdf-ocr auto|always|off` selects local OCR; automatic mode also recognizes
scan images below digital headers. `--ocr-language de,en` sets shared PDF/image
languages supported by the local Vision installation. `--pdf-layout auto|legacy`
selects two-column ordering or the previous extraction for comparison.
`--pdf-remove-headers-footers` removes repeated text at page margins;
`--pdf-dehyphenate` optionally joins conservative lowercase word breaks.
The app remembers these settings. Original embedded text remains present when
OCR adds text. Heuristics and limits: [PDF import](docs/PDF-IMPORT.md).

### Presentations and notebooks

PPTX/PPTM/POTX, ODP and IPYNB are native inputs and do not require Pandoc.
Slides retain source order, text, nested lists, tables, notes and supported
image assets. Notebook imports preserve Markdown, language-tagged code, text
outputs and embedded images; notebook code is never executed.
Unsupported objects or output representations and unavailable assets are
reported. Details and budgets: [presentations](docs/PRESENTATION-IMPORT.md),
[notebooks](docs/NOTEBOOK-IMPORT.md).

### Batch parallelism and source protection

`--jobs 1..4` controls the number of simultaneous batch documents; the default
is 1. The app remembers the same setting. Local Vision OCR processes at most one
image per process, while other documents can continue without OCR. A waiting
OCR request checks cancellation every 50 ms. Four documents can still retain
substantial parser, image and subprocess memory; this is a concurrency limit,
not a fixed RAM limit. Measurements are recorded in [performance](docs/PERFORMANCE.md).

All batch targets and output roots are planned and checked against every source
before any directory or worker is created. This includes adjacent outputs for a
file inside another source package. The first input position reserves a target;
conflicting later inputs fail regardless of worker speed. Existing outputs are
never overwritten. Results, JSON entries and the first ordinary error retain
input order. SIGINT/SIGTERM returns 130, retains committed results, waits for
running workers to clean up, and leaves remaining inputs available for retry.
An individual tool timeout does not cancel the other documents. Empty output
parent directories can remain after cancellation; unfinished document workspaces
and partial results are removed.

<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="Poor Man's Text app icon">
</p>

<h1 align="center">Poor Man's Text</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Convert word-processing documents and spreadsheets to Markdown.</strong>
</p>

Poor Man's Text converts RTF, RTFD, DOCX (including DOCM and DOTX/DOTM), ODT,
legacy Word (`.doc`), ODS, XLSX, XLS, and OpenDocument master (`.odm`) files into
folders containing Markdown and any separately stored image assets.

The project provides two interfaces over the same conversion core:

- `poormans-text`, an automation-friendly command-line tool
- a native macOS app for opening or dropping supported documents and spreadsheets

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

ODS, XLSX, and XLS are read natively and need no external conversion tool. For
the remaining formats, the converter searches for Pandoc in the common Homebrew
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
shasum -a 256 -c Poor-Mans-Text-0.8.1.dmg.sha256
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
poormans-text --spreadsheet-format tsv Workbook.ods
poormans-text --output Converted Document.rtfd
poormans-text --json Document.rtfd
```

The default output directory is `Document-markdown` next to the source. Run
`poormans-text --help` for all options. Without an installation, the same
commands work in a source checkout as `swift run poormans-text …`.

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
rtf   .rtf                     file     pandoc           available
rtfd  .rtfd                    package  pandoc+textutil  available
docx  .docx .docm .dotx .dotm  file     pandoc           available
odt   .odt                     file     pandoc           available
doc   .doc                     file     textutil+pandoc  available
ods   .ods                     file                      available
xlsx  .xlsx                    file                      available
xls   .xls                     file                      available
odm   .odm                     file     pandoc           available
```

Without Pandoc, the word-processing and ODM lines read
`unavailable (missing required tool: pandoc)`; ODS, XLSX, and XLS remain
available. The `textutil` that DOC and RTFD additionally require is part of
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

Drop any supported document or spreadsheet into the window or onto the app, or
choose one from the open panel. The app shows the conversion result and can
reveal the generated Markdown in Finder.

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
- stored spreadsheet values, sheet names, sheet order, empty cells, and internal line breaks
- local ODM section order

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
- spreadsheet hyperlink targets; the visible cell text stays and the loss is
  reported as a warning
- ODM section boundaries and master-document behavior after flattening

## Development

```sh
./build.sh
swift test
./install.sh --no-notarize
```

See [docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md) for build, signing, and
installation details. Image/OCR and PDF import are tracked in
[ROADMAP.md](ROADMAP.md). The implemented workbook model, two table representations,
and multi-sheet behavior are described in
[docs/SPREADSHEET-IMPORT.md](docs/SPREADSHEET-IMPORT.md).

The test suite creates real temporary Cocoa RTFD packages and monolithic RTF
files with formatting, colors, empty lines, links, lists, Unicode filenames,
and embedded images. Versioned DOCX, ODT, and binary DOC fixtures from independent
producers cover headings, footnotes, tables, lists, links, comments, tracked
changes, Unicode, and media hashes. Native spreadsheet tests cover real ODS and
XLS files, generated XLSX packages, sheet order, cell budgets, warnings, and an
independent Pandoc comparison. ODM tests use local linked ODT files. Tests also
cover output collisions, malformed or unsafe packages, missing dependencies,
the CLI-link guard, and the app's `NSItemProvider` drop path.

The current version is 0.8.1.

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

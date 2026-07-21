**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Poor Man's Text

Poor Man's Text converts Rich Text Format (`.rtf`) and macOS Rich Text with
Attachments (`.rtfd`) documents into folders containing Markdown and separately
stored image assets.

The project provides two interfaces over the same conversion core:

- `poormans-text`, an automation-friendly command-line tool
- a native macOS app for opening or dropping RTF and RTFD documents

Conversion is deliberately lossy. Markdown can preserve document structure,
links, simple emphasis, lists, and images, but not every font, layout, or
TextKit-specific attribute.

## Output

Converting `Document.rtf` or `Document.rtfd` creates a new sibling directory
without changing the source:

```text
Document-markdown/
├── Document.md
└── images/
    ├── first-image.png
    └── second-image.jpg
```

Image links in `Document.md` are relative and retain their position in the text.
Existing output directories are never overwritten.

Manual line breaks end with two spaces in the generated Markdown. Chromatic
RTFD text is marked as `==text==`. Fastra supports this common Markdown
extension, but it is not part of standard GFM and does not retain the exact
color value. RTF color information cannot be retained by the image-safe import
path; the converter keeps the text and returns a warning instead.

## Requirements

- macOS 13 or newer
- [Pandoc](https://pandoc.org/installing.html)
- Swift 6.2 or newer when building from source

The converter searches for Pandoc in the common Homebrew locations and then on
`PATH`. The CLI also accepts an explicit executable through `--pandoc PATH`.

## Command line

```sh
swift run poormans-text Document.rtfd
swift run poormans-text Document.rtf
swift run poormans-text --output Converted Document.rtfd
swift run poormans-text --json Document.rtfd
```

The default output directory is `Document-markdown` next to the source. Run
`swift run poormans-text --help` for all options.

Exit codes follow conventional `sysexits` values: `64` for usage errors, `65`
for invalid input data, `66` for a missing input, `69` when Pandoc is not
available, `70` for a failed conversion process, `73` for an output collision,
and `74` for a file-system error. With `--json`, successes and failures are
reported as JSON on standard output; diagnostics otherwise go to standard
error. Inputs are accepted as file-system paths, not through standard input.

## macOS app

Build the app and CLI from the repository root:

```sh
./build.sh
open "Poor Man's Text.app"
```

The build also places `Poor Man's Text.app` and `poormans-text` directly in the
repository root. These local artifacts are ad-hoc signed and must not be copied
to `/Applications`.

Drop an RTF or RTFD document into the window, drop it onto the app, or choose one
from the open panel. The app shows the conversion result and can reveal the
generated Markdown in Finder.

The generated bundle is ad-hoc signed for local testing and remains under
`.build/app/`. It is not a notarized distribution build.

## Signed installation

The complete installer builds universal app and CLI binaries, signs both with
Developer ID and the hardened runtime, notarizes and staples the app, creates a
signed disk image, notarizes and staples that disk image, and only then installs
the verified app:

```sh
NOTARY_PROFILE=<profile> ./install.sh
```

The app is installed as `/Applications/Poor Man's Text.app`. The exact same CLI
embedded in the bundle becomes available on the terminal path through
`/usr/local/bin/poormans-text`. An unrelated existing target is never
overwritten. The faster `./install.sh --no-notarize` path keeps the signed but
unnotarized artifacts in the repository root.

The full run also produces `Poor-Mans-Text-<version>.dmg` and a matching
`.sha256` file in the repository root. Users who drag the app from that disk
image into `/Applications` are offered an optional first-launch setup for the
embedded CLI. It never replaces another command-line tool and always asks before
requesting administrator privileges.

## Conversion pipeline

RTFD stores text in `TXT.rtf` and keeps attachments as separate files inside a
macOS package. Poor Man's Text uses the macOS text system to create HTML and
materialize those attachments. Standard RTF stores images inside the file;
Pandoc reads that container and extracts its media without a Cocoa round trip.
Both paths then validate and rewrite image references before Pandoc creates
GitHub-Flavored Markdown.

The conversion runs in a private temporary directory and moves the completed
result into place only after all stages succeed. Remote image references are
rejected rather than downloaded. Attachments that cannot be represented in the
generated Markdown produce warnings.

## Format support and limitations

Typically preserved:

- paragraphs and manual line breaks using two trailing spaces
- bold and italic text
- chromatic RTFD text using `==text==` markers
- hyperlinks
- simple ordered and unordered lists
- image order and relative image references

Expected losses or approximations:

- font families, grayscale and exact color values, and exact font sizes
- exact image dimensions
- page geometry and paragraph alignment
- complex tables, text boxes, and multi-column layouts
- equations and application-specific rich-text attributes
- semantic heading levels when the source only expresses larger font sizes

## Development

```sh
./build.sh
swift test
./install.sh --no-notarize
```

See [docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md) for build, signing, and
installation details. Planned import formats—DOCX, ODT, DOC, images, PDF, and
ODM—are tracked in [ROADMAP.md](ROADMAP.md).

The test suite creates real temporary Cocoa RTFD packages and monolithic RTF
files with formatting, colors, empty lines, links, lists, Unicode filenames,
and embedded images. It compares extracted image bytes and source bytes and also
covers output collisions, malformed inputs, unsafe image references, missing
dependencies, warnings, the CLI-link guard, and the app's `NSItemProvider` drop
path.

The current version is 0.4.0.

## License

Poor Man's Text is released under the **WTFPL**, Version 2
(Do What The Fuck You Want To Public License) — see [LICENSE](LICENSE).

Pandoc is an external runtime dependency and is not bundled with Poor Man's
Text. Pandoc remains subject to its own license.

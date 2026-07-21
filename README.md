**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Poor Man's Text

Poor Man's Text converts macOS Rich Text with Attachments (`.rtfd`) documents
into folders containing Markdown and separately stored image assets.

The project provides two interfaces over the same conversion core:

- `poormans-text`, an automation-friendly command-line tool
- a native macOS app for opening or dropping RTFD documents

Conversion is deliberately lossy. Markdown can preserve document structure,
links, simple emphasis, lists, and images, but not every font, layout, or
TextKit-specific attribute.

## Output

Converting `Document.rtfd` creates a new sibling directory without changing the
source:

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
text is marked as `==text==`. Fastra supports this common Markdown extension,
but it is not part of standard GFM and does not retain the exact color value.

## Requirements

- macOS 13 or newer
- [Pandoc](https://pandoc.org/installing.html)
- Swift 6.2 or newer when building from source

The converter searches for Pandoc in the common Homebrew locations and then on
`PATH`. The CLI also accepts an explicit executable through `--pandoc PATH`.

## Command line

```sh
swift run poormans-text Document.rtfd
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
error. An RTFD package is a directory, so it cannot be supplied through
standard input.

## macOS app

Build the local app bundle and open it:

```sh
scripts/build_app.sh
open ".build/app/Poor Man's Text.app"
```

Drop an RTFD package into the window, drop it onto the app, or choose one from
the open panel. The app shows the conversion result and can reveal the generated
Markdown in Finder.

The generated bundle is ad-hoc signed for local testing and remains under
`.build/app/`. It is not a notarized distribution build.

## Conversion pipeline

RTFD stores text in `TXT.rtf` and keeps attachments as separate files inside a
macOS package. Poor Man's Text uses the macOS text system to create HTML and
materialize those attachments, replaces Cocoa's generated image URLs with safe
relative paths, and then uses Pandoc to create GitHub-Flavored Markdown.

The conversion runs in a private temporary directory and moves the completed
result into place only after all stages succeed. Remote image references are
rejected rather than downloaded. Attachments that cannot be represented in the
generated Markdown produce warnings.

## Format support and limitations

Typically preserved:

- paragraphs and manual line breaks using two trailing spaces
- bold and italic text
- chromatic text using `==text==` markers
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
swift build
swift test
scripts/build_app.sh
```

The test suite creates real temporary Cocoa RTFD packages with formatting,
colors, empty lines, links, lists, Unicode filenames, repeated attachment names,
and multiple images. It also covers output collisions, malformed packages,
unsafe image references, missing dependencies, warnings, and the app's
`NSItemProvider` drop path.

The current version is 0.2.0. No open-source license has been selected yet.

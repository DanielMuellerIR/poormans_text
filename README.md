# Poor Man's Text

Poor Man's Text converts macOS Rich Text with Attachments (`.rtfd`) documents
into a folder containing Markdown and separately stored image assets.

The project is being developed as two interfaces over one conversion core:

- `poormans-text`, an automation-friendly command-line tool
- a native macOS app that accepts RTFD documents by drag and drop

Conversion is deliberately lossy. Markdown can preserve document structure,
links, simple emphasis, lists, and images, but not every font, color, layout, or
TextKit-specific attribute.

## Requirements

- macOS 13 or newer
- Swift 6.2 or newer for building from source
- [Pandoc](https://pandoc.org/) for HTML-to-Markdown conversion

## Usage

```sh
swift run poormans-text Document.rtfd
swift run poormans-text --output Converted Document.rtfd
swift run poormans-text --json Document.rtfd
```

By default the command creates `Document-markdown/Document.md` and, when the
source contains images, `Document-markdown/images/`. The command refuses to
replace an existing output directory.

Run `swift run poormans-text --help` for all options and documented exit
behavior.

Exit codes follow the conventional `sysexits` values: `64` for usage errors,
`65` for invalid input data, `66` for a missing input, `69` when Pandoc is not
available, `70` for a failed conversion process, `73` for an output collision,
and `74` for a file-system error. With `--json`, successes and failures are
reported as JSON on standard output; diagnostics otherwise go to standard
error. An RTFD package is a directory, so it cannot be supplied through
standard input.

## Build

```sh
swift build
swift test
scripts/build_app.sh
```

The app bundle is generated at `.build/app/Poor Man's Text.app`. It is ad-hoc
signed for local testing and is not a notarized distribution build.

The first development release is version 0.1.0. No license has been selected
yet.

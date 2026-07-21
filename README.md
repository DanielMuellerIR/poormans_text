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

## Build

```sh
swift build
swift test
```

The first development release is version 0.1.0.


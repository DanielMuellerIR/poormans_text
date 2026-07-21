# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0 - 2026-07-21

- Write manual and empty rich-text line breaks using two trailing spaces.
- Remove Pandoc escape noise from typed bullets, list markers, and separators.
- Join adjacent plain-text lines with Markdown hard breaks where safe.
- Preserve chromatic foreground text using Fastra-compatible `==text==` markers.
- Keep grayscale text unmarked and retain every source paragraph and attachment.

## 0.1.0 - 2026-07-21

- Start the Swift package with a shared core and command-line interface.
- Add guarded RTFD-to-HTML-to-GFM conversion with separate image assets.
- Add human-readable and JSON command-line results with meaningful exit codes.
- Add real Cocoa RTFD integration tests and guarded error-case coverage.
- Add a native drag-and-drop macOS app over the shared conversion core.
- Verify app opening, visual result state, and the file-URL drop data path.
- Document CLI, app, output safety, format support, and known losses in English
  and German.

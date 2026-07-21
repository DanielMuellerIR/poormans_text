# Changelog

All notable changes to this project will be documented in this file.

## 0.4.0 - 2026-07-21

- Add guarded RTF conversion through Pandoc while retaining the existing safe,
  atomic RTFD pipeline and structured CLI results.
- Preserve formatting, links, lists, blank lines, image order, and embedded RTF
  image bytes; report RTF color loss explicitly instead of dropping text or images.
- Accept RTF in the CLI, app picker, file opening, and drag-and-drop workflow.
- Offer consent-based first-launch installation of the CLI embedded in an app
  copied to `/Applications`, without replacing unrelated targets.
- Build universal release binaries for Apple silicon and Intel Macs.
- Create, sign, notarize, staple, mount-test, and checksum a distributable DMG
  before changing the installed app.

## 0.3.0 - 2026-07-21

- Add a root build command that produces visible app and CLI artifacts.
- Embed the same CLI binary in the app bundle for a consistent installation.
- Add Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper
  verification, and guarded installation to `/Applications`.
- Install the bundled CLI on the terminal path without replacing unrelated files.
- Document reusable conversion boundaries, build and test procedures, and the
  staged plan for RTF, DOCX, ODT, DOC, images, PDF, ODM, and later Fastra use.

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

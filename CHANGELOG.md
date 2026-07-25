# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Add content-based DOCX and ODT package imports through a shared sandboxed
  Pandoc adapter with isolated media extraction, archive budgets, traversal and
  symlink rejection, remote-image blocking, explicit accepted DOCX changes, and
  structured annotation diagnostics.
- Add a separate content-based legacy DOC adapter through macOS `textutil`, with
  independent text-retention checks and explicit warnings for unsupported OLE
  objects, text boxes, macros, and embedded content.
- Cover DOCX, ODT, and binary DOC with real fixtures from independent producers,
  direct Pandoc output comparisons, media hashes, source-integrity checks, and a
  real XLS/DOC OLE distinction.
- Verify multi-sheet ODS feasibility and document the future shared workbook
  model, Markdown-table and escaped-TSV renderings, sheet ordering, budgets, and
  subsequent XLSX/XLS sequence.

## 0.5.1 - 2026-07-22

- Preserve real RTFD paragraph boundaries independently from manual line breaks,
  keep CommonMark fenced code untouched, and show every conversion warning in the app.
- Keep CLI JSON errors aligned with parsed options and discard unused external-tool
  standard output instead of buffering it in full.
- Preserve the previous installed app at a reported rescue path when an atomic
  rollback fails, with the transaction paths covered by isolated tests.
- Let adapters own format inspection and expected warnings, with central priority
  and ambiguity handling for extensible format identifiers.
- Add a format-neutral conversion engine with content-based RTF/RTFD detection,
  typed requests, progress, diagnostics, and persistent or temporary destinations.
- Keep the distinct AppKit RTFD and Pandoc RTF import paths behind one adapter,
  while moving staging, collision checks, and atomic publication into the engine.
- Move the app and CLI onto the shared request API without changing CLI JSON,
  warning, or exit-code semantics.

## 0.5.0 - 2026-07-21

- License the project-owned source code and documentation under WTFPL Version 2
  and include the license in generated app bundles.
- Add the sapphire-and-amethyst document icon selected for the public release,
  with a reproducible macOS icon build and documented asset provenance.
- Add GitHub Actions verification, public download and support documentation,
  release notes, and a tag-aware local release verifier.

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

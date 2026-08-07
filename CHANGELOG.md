# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Keep the Sparkle signing key out of every step but the one that signs, pin all
  workflow actions to reviewed commit SHAs, skip prereleases, and refuse a
  manual appcast run whose tag is not the latest stable release.
- Verify ZIP entries over the mapped archive instead of copying each entry, so a
  large package no longer needs several times its own size in memory.
- Read an XLS sheet only up to its own end-of-sheet record instead of
  materializing the rest of the workbook stream once per sheet.
- Keep master-document text around a nested annotation paragraph, write manual
  line breaks as Markdown hard breaks, preserve explicit `text:s` spaces, and
  escape master text so a paragraph like `# Text` stays a paragraph.
- Replace only real Markdown image targets when merging ODM sections instead of
  rewriting every occurrence of the same text.
- Report a shared-formula cell without a stored result, read cells that omit the
  optional `r` reference, skip chartsheets with an unsupported-object warning
  instead of failing the workbook, and cover modern threaded comments.
- Validate the ODS content hierarchy before accepting a table as a sheet, and
  report spreadsheet hyperlink targets as an unsupported object in all three
  readers instead of dropping them silently.
- Decide package inspections by element namespace and resolve `xlink:href`
  through its declared prefix, so foreign elements or attributes can neither
  trigger nor hide a warning.
- Publish the disk image and its checksum only after the installation passed its
  final check, and roll the installation back if publishing fails.
- Strip debug symbols only on the release path; `./build.sh debug` keeps them.
- Unwrap list items that contain inline formatting, reject a conversion option in
  `--formats`, report a rejected parallel Pandoc installation instead of showing
  success, and skip the independent XLSX comparison when Pandoc is missing.

## 0.8.0 - 2026-08-05

- Verify the complete published Sparkle path from 0.7.0 to 0.8.0: the older
  installed app found the signed feed, installed the notarized release after
  confirmation, restarted into build 10, and matched the published bundle's
  CodeDirectory hash.
- Add native ODS, XLSX, and BIFF8 XLS import without LibreOffice, Excel, or
  Pandoc. All three readers share a bounded workbook model, preserve sheet order
  and stored cell values, and render either GFM tables or reversibly escaped
  TSV code blocks. Merges, missing formula results, unsupported objects, and
  legacy XLS losses are reported explicitly.
- Add ODM master-document import. Inline master text and local linked ODT files
  are flattened in source order, child images receive unique names, and remote,
  missing, traversing, or symlink-escaping references are rejected.
- Accept DOCM, DOTX, and DOTM after validating the OOXML main content type and
  document root. Macro and template semantics that Markdown cannot retain now
  produce dedicated warnings instead of disappearing silently.
- Keep a validated newly installed app and its CLI in place if the saved old
  bundle changes identity during the final check. The suspicious backup remains
  at its rescue path instead of being restored or deleted.
- Preserve RTF paragraph boundaries written as a backslash plus physical newline,
  leave escaped backslashes and binary payloads untouched, and keep simple list
  items tight by removing only their redundant paragraph wrapper. Markdown hard
  breaks that only precede a blank line, list item, or end of input are removed.
- Make CLI JSON paths consistently symlink-resolved, emit an explicit
  `unavailableReason: null` for available formats, and centralize response
  defaults. Remove an unused legacy result initializer and the app's identity-only
  warning wrapper.
- Derive the app's open-panel types from the core format catalog and describe
  Pandoc accurately as a requirement for word-processing and ODM files, while
  native spreadsheet conversion remains available without it.

## 0.7.1 - 2026-08-05

- Name extracted images in document order as `image01`, `image02`, and so on,
  while keeping their file extensions. RTFD conversion no longer exposes
  technical attachment-collision prefixes such as `1__#$!@%!#__`, whose
  reserved characters also broke image previews in some Markdown editors.

## 0.7.0 - 2026-08-05

- Keep the app up to date through Sparkle: it checks a signed update feed on its
  own and offers "Check for Updates …" in the application menu, but downloads
  and installs nothing without consent. Feed and disk image must carry a valid
  Ed25519 signature, the new version is verified before extraction, and no
  system profile is transmitted. Version 0.6.0 and older have no updater, so
  0.7.0 has to be installed once by hand from the DMG.
- Offer to install a missing Pandoc directly from the app: with Homebrew
  present the app runs the installation itself, otherwise it opens the official
  installation help. The offer returns at every launch until Pandoc exists or
  "Don't Ask Again" is chosen.
- Refuse every entry point while that installation runs: the drop zone, the
  "Choose Document…" button, and documents opened from Finder are turned down
  until `brew install pandoc` has finished, and the drop area says so. They used
  to stay active and answered with "Pandoc was not found." while the window was
  showing "Installing Pandoc…".
- Produce a complete release in a single run: `./install.sh --with-dmg` builds,
  signs, and notarizes once and then writes the disk image, its checksum, and the
  installation from that same bundle. `scripts/verify_release.sh` compares the
  CodeDirectory hashes of the repository app, the installed app, and the app
  inside the image, which two separate runs of `./release.sh` and `./install.sh`
  could not satisfy.
- Drain helper-process error pipes before waiting for the child to exit, so
  chatty output can no longer deadlock the in-app CLI installation.
- Verify every entry of a DOCX or ODT package against its ZIP directory entry —
  actual expanded size and checksum, not just the declared size — and hand
  Pandoc an immutable copy in the private work directory instead of the source
  path that was inspected earlier.
- Detect package features by XML element name with namespace processing enabled:
  field codes such as `instrText` are no longer reported as tracked changes, and
  external image references, ODT annotations, and ODT tracked changes are found
  regardless of the namespace prefix a producer chose.
- Keep indented code blocks out of the Markdown clean-up. Pandoc writes code
  blocks without a language indented, and the clean-up rules silently changed
  their content, dropping a trailing backslash or unescaping a leading hyphen.
- Report the external tools of every format in the plain-text `--formats`
  output as well, and declare `textutil` for RTFD, whose import path runs it.
- Reject a directory as a Pandoc executable: POSIX search permission alone made
  `--formats --pandoc /tmp` claim that every format was available.
- Remove the intermediate HTML file explicitly instead of ignoring a failed
  deletion, so it can no longer end up in the published output folder, and
  report a missing or unreadable Pandoc artifact as a file-system error instead
  of blaming a valid source document.
- Compare `PATH` entries normalized when choosing the CLI install directory, so
  a meaningless trailing slash no longer selects the wrong prefix or aborts the
  run.

## 0.6.0 - 2026-07-27

- Publish the supported input formats as a queryable catalog: adapters now
  declare their file extensions, whether the source is a single file or a folder
  package, and the external tools they need. `poormans-text --formats [--json]`
  reports that catalog together with the current availability of each tool, so a
  host application never has to hard-code format knowledge and picks up new
  formats without being changed itself.
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

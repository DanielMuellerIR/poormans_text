# Changelog

All notable changes to this project will be documented in this file.

## 0.16.0 — 2026-10-01

- Open converted Markdown directly in Fastra from the result actions, alongside
  the default application. Report missing Fastra installations and open failures.

## 0.15.1 — 2026-10-01

- Preserve named inline roots in related email messages and save related text
  resources without decoding them as message bodies.
- Reject encrypted S/MIME message bodies with an explicit diagnostic.
- Recognize complete PDF table grids independent of drawing order and preserve
  all edges of rectangle and implicitly closed path operators.
- Read HTML charset declarations from actual attributes.
- Rewrite notebook attachment reference definitions and batch Textbundle asset
  rewrites with cancellation checks.

## 0.15.0 — 2026-10-01

- Bind image inspection and ImageIO access to checked descriptors and private
  snapshots. Clone directly from the held descriptor where supported, with a
  bounded streaming fallback; source replacement or truncation cannot redirect
  ImageIO to an unchecked object. Preserve original image assets and the existing
  image engine, OCR pixel budgets and source-size limit.
- Use the same table limits for CSV/TSV, ODS, XLSX and XLS: 1,000,000 rows per
  sheet, 16,384 columns and 10,000,000 cells across all sheets. Count empty cells
  added for rectangular rendering and report the same limits in app and CLI.
  Keep the 128 MiB output limit and one-million-cell hyperlink scan budget.
- Show complete conversion errors in the app instead of cutting off the budget
  reason after a long source path.

## 0.14.0 — 2026-09-30

- Inspect foreign ZIP document packages through bounded reads from the same
  checked file descriptor, retaining the existing archive, entry and metadata
  budgets. Detection no longer copies the entire archive into the heap.
- Reject conflicting end-record directory views, unexplained gaps, overlapping
  local entries and padding after a Deflate stream. Preserve recognized digital
  signature and archive-extra-data records and signed or unsigned data descriptors.
- Keep full size and CRC verification on the private conversion copy. ZIP64 and
  encrypted document packages remain unsupported.

## 0.13.0 — 2026-09-30

- Infer PDF headings from document font sizes and reconstruct simple closed-grid
  tables, including empty cells and multiline values, using the existing PDFKit
  engine. Source text remains escaped; source files remain untouched.
- Keep label/value associations when PDFKit spaces span a table gutter. Use
  paragraph continuation as an additional signal for two-column reading order;
  unresolved layouts retain row order with a visible, page-specific warning.
- Preserve the legacy extraction for comparison. Borderless tables, complex
  grids and font substitutions remain document-dependent limitations.

## 0.12.0 — 2026-09-30

- Import Outlook MSG mail without Office through a bounded OLE/property reader
  and the shared mail engine. Preserve Unicode text, HTML and compressed RTF,
  inline images, safe byte-preserved attachments and standalone embedded MSG
  attachments. Keep the visible header table in both app and CLI.
- Normalize native MSG RTF Unicode fallbacks in the temporary Pandoc input,
  preserving the character after each escape and leaving source bytes untouched.
- Register MSG for opening, dropping and the file service. Reject broken
  containers, unsupported Outlook items and external attachment methods.

## 0.11.0 — 2026-09-30

- Import EML and Apple Mail EMLX messages through the shared engine, with
  visible header tables, decoded text/HTML bodies, related inline images and
  byte-preserved attachments in safe, unique output paths. Nested MIME,
  transfer encodings, header words and extended file-name parameters are
  bounded and validated; malformed or encrypted bodies fail explicitly.
- Register mail files for the app and file service, and support the same
  metadata, temporary output and Textbundle options as the CLI.


- Read an HTML charset only from a real `meta` tag or leading XML declaration;
  examples in comments and scripts no longer override the document encoding.
- Inspect and rewrite notebook Markdown resources in linear passes, with
  cancellation checks, while fenced code examples no longer consume the target
  budget.
- Compare CSV delimiters and line ends as Unicode scalars. A comma followed by
  a combining mark formed a different grapheme and did not split the field.
- Keep an ODP image that sits inside a paragraph (`draw:frame` within
  `text:p`); the reader stopped at the paragraph text and dropped the image
  without a warning. A presentation image referenced many times is unpacked,
  decoded, and hashed once instead of once per reference.
- Skip phonetic reading hints (`<rPh>`) in XLSX shared and inline strings; a
  Japanese workbook read `日本ニホン` where the cell says `日本`.
- Count memory before it is spent in the spreadsheet readers: a BIFF sheet
  stops at the cell budget while its records are still being collected, an
  XLSX row index that skips rows charges the skipped rows to the expanded-cell
  budget, and CSV delimiter sniffing splits only the first twenty lines instead
  of the whole file.
- Read metadata from EPUB and FictionBook sources: the OPF named by
  `META-INF/container.xml` (Dublin Core, `dc:date` as the creation date) and
  the `title-info` block (book title, first author, genres, annotation, date).
  `--frontmatter` previously always reported that no metadata was available.
- Honor the charset an HTML file declares before assuming Windows-1252. A page
  in windows-1251 or shift_jis was read as mojibake with the generic encoding
  warning; UTF-8 still comes first, and the warning now only appears when
  nothing was declared or the declaration does not decode.
- Drop an oversized local image referenced by an HTML page like any other
  unusable reference, with the alt text kept, instead of ending the whole
  conversion with a file-system error. Write a web archive subresource once,
  however many `<img>` tags reference it.
- Resolve the main part of a Word package through the `officeDocument`
  relationship in `_rels/.rels`, the way OPC defines it and Pandoc reads it. A
  document repaired by Word carries `word/document2.xml` and was rejected as
  missing its package entries. Comments, footnotes, and endnotes are looked up
  next to the resolved part. An empty `.rels` part no longer rejects the whole
  document; a malformed one still does, because it could hide an external image
  target. ODT packages are now also checked for external images in `styles.xml`.
- Report an argument error as JSON whenever `--json` appears anywhere among the
  options, not only when it precedes the faulty argument. A value-aware scan
  decides the output mode before parsing; `--pandoc --json` still names a tool
  path and `-- --json` still names an input. The parser now reads every option
  that takes a value through one shared list instead of its own branch.
- Reject `--stdout` together with `--jobs` as a usage error, the way the
  catalog mode already rejects options that cannot take effect; the parallelism
  was silently ignored. The help and the README now say that text mode prints
  one path per line and that a path containing a line break spans two lines,
  so parsing scripts should use `--json`.
- Translate the messages of the side paths: the image notice of the rich-text
  service, both installation dialogs, and the errors the rich-text service
  reports to the calling app now go through the app's central message mapping
  instead of reaching the German window in English. The orphaned
  "Converting %lld of %lld" key is gone from both language files.
- Report files opened through the Dock, a double-click, or `open -a` while the
  app is busy. That path silently dropped them; the window now says why they
  were not accepted, and ⌘O is disabled during the Pandoc installation instead
  of opening a dialog whose selection went nowhere.
- Hand the app's destination folder to the batch as its output root, the way
  `--output` reaches the CLI. A destination pointing at a file now fails with
  "output already exists" instead of a raw file-system error per input, and a
  deleted destination is recreated one level deep at most; a missing parent
  fails before any conversion starts instead of being created silently.
- Give the Homebrew installation of Pandoc a cancel button, a 15-minute limit,
  and no standard input. It ran through its own process starter without any of
  the three, so a Homebrew waiting for a password or a confirmation kept the
  drop zone, ⌘O, Dock opening, and both services locked until the app was
  restarted. The app now starts Homebrew and `osascript` through the same
  process runner as the conversion tools.
- Escape carriage returns, NUL, and the Unicode line separators in the YAML
  frontmatter. A CRLF pair is a single Swift `Character` and slipped through the
  previous escaping, so a foreign document title could close the header and
  append its own Markdown.
- Rewrite percent-encoded asset links when building a Textbundle. Image names
  containing characters outside `A-Za-z0-9-._~` kept pointing at the removed
  `images/` folder, which lost the image without a warning.
- Reject an output directory named `*.textbundle` unless `--textbundle` is set.
  Such a folder looked like a package to Finder but carried neither `info.json`
  nor `text.md`, and later folder runs skipped it as a previous result.
- Read metadata that an empty sibling element used to hide: an empty
  `dc:creator` no longer blocks `meta:initial-creator`, an unreadable
  `dcterms:created` falls back to `meta:creation-date`, and a CDATA title is
  read. Implausible RTF creation timestamps no longer become a date.
- Accept a cancellation token and a process timeout in `inspect` and
  `detectFormat`. Format detection starts `textutil` for DOC files and
  previously ran without any limit a caller could reach.
- Compare the checksum and both sizes of every local ZIP header against the
  central directory, the three fields that were the only ones left unchecked.
  A streaming unpacker reads the local length, so a package could hand it a
  stream that neither the unpack budget nor the checksum had ever seen. Entries
  with a data descriptor may still leave those fields empty, as LibreOffice
  writes them.
- Check the local header of directory entries too. They skipped the only place
  that looks at a local header at all, so theirs could declare a different name
  and an arbitrary payload.
- Reject an end record whose two entry counts disagree, and a ZIP64 locator that
  carries no sentinel values. Both let another unpacker read a different set of
  entries than the one this package gate verified.
- Refuse a result folder that is named directly as an input. The rule that skips
  `Name-markdown` and `Name.textbundle` applied only while searching, so naming
  such a folder — or dropping it onto the app — converted the images of the
  earlier run again and nested the result inside the old output folder.
- Keep the destination chosen through "Choose Another Name or Destination…"
  when retrying, and retry only the input that was asked for. The retry path
  cleared the override it had just been given and ignored the filter, so the
  choice had no effect.
- Localize the clipboard and service messages that were shown in English to
  German users, and report the command-line installer's own error in English
  instead of a German sentence inside an English message.
- Refuse an empty path argument instead of reading it as the working directory.
  `poormans-text "$FILE"` with an unset variable converted the whole working
  directory tree, and `--output ""` wrote there without a word.
- Report an out-of-range or unparsable `--timeout` as an invalid option rather
  than a missing value.
- Rewrite every attachment reference of a notebook cell in a single pass. Doing
  it once per attachment was quadratic: a 2.6 MB notebook with 20,000
  attachments ran for over ten minutes and ignored cancellation. The same file
  now converts in under two seconds.
- Report a notebook Markdown reference that points at an asset name this
  conversion generated for another cell. It used to be left in place, silently
  showing a foreign image, and the result depended on the cell order.
- Count attributes against the XML import limits, and read the notes parts of a
  slide in relationship order so repeated runs produce the same output.
- Report tracked changes that live only in footnotes or endnotes, and tracked
  formatting changes such as `rPrChange`. Pandoc accepts those changes during
  the conversion, so leaving them unreported dropped exactly the warning that
  exists for it.
- Copy a referenced image only after verifying that the copy really is an
  image, and name it after the verified type. The extension came from the
  foreign reference, so `<img src="page.html">` placed that HTML file into the
  result folder and linked it as an image; opening it fetched exactly the remote
  resources the core never fetches. The same now applies to web-archive
  subresources, which may claim `image/png` and contain something else.
- Keep reading an `<img>` tag past a `>` inside a quoted attribute. An alt text
  like `"width > height"` ended the tag early, so a valid local image was lost
  and the rest of the tag appeared as literal text in the Markdown.
- Find images whose file name contains `#` or `?`. Both were treated as URL
  separators and cut the name short, in encoded and unencoded references alike.
- Fail instead of producing an empty document when the staged HTML copy cannot
  be read.
- Read compressed BIFF8 strings as Windows-1252 instead of ISO-8859-1. Every
  western XLS with typographic quotes, an en dash, or a euro sign carried raw
  control characters into the Markdown; the hyperlink paths in the same file
  were already decoded correctly.
- Accept a spreadsheet whose trailing empty row declares a repeat beyond the
  row budget. LibreOffice ends a formatted sheet with
  `number-rows-repeated="1048575"`, and such rows are never materialised, so
  refusing the whole file was wrong. A repeat that carries content is still
  refused rather than silently truncated.
- Reject a UTF-16 delimited text file that contains NUL, like the other two
  decoding paths already did.
- Render PDF pages upright for OCR with `--pdf-layout legacy`. The legacy path
  flipped the page before handing it to Vision, which reads with an upright
  orientation, so its result was mirrored nonsense — reported as a successful
  OCR run. `HELLO OCR WORLD` came back as `НЕГГО ОСЬ MOBD`.
- Compare the recognized text, not its uncertainty note, when dropping OCR lines
  that duplicate embedded PDF text. A line below the confidence threshold could
  never match, so the same sentence appeared twice.
- Check for cancellation while preparing the extracted PDF text. A long document
  finished its whole text assembly before a cancellation took effect.
- Drop stale batch progress events in the CLI. The batch assigns the sequence
  number under its lock but calls the handler after releasing it, so the file
  counter could run backwards with `--jobs 2` and higher. The app already
  filtered these events.

## 0.10.2 — 2026-09-08

- Select one supported PowerPoint compatibility representation, or its fallback,
  instead of repeating alternative slide text and image references.
- Detect scan images in inherited PDF page resources so automatic OCR also runs
  for mixed pages whose digital header would otherwise hide scanned content.
- Preserve complete notebook Markdown resource targets with angle brackets,
  spaces, escaped punctuation and balanced parentheses when diagnosing missing files.
- Keep notebook traceback entries on separate lines without changing source and
  stream fragment decoding.

## 0.10.1 — 2026-09-05

- Verify DOCX/ODT content independently of Pandoc table padding and separately
  require the explicit numeric-column alignment preserved by the app. The
  conversion comparison covers Pandoc 3.9 and 3.11 without changing fixtures.
- Version 0.10.0 was a tagged release candidate; 0.10.1 is the public release.

## 0.10.0 — 2026-09-05

- Check the OLE directory for a WordDocument stream before invoking Apple's
  Word inspector. Valid XLS workbooks no longer hang in `textutil` during
  format detection, including workbooks with a misleading file extension.

- Add `--jobs 1..4` and remembered app batch parallelism, defaulting to one
  document. A shared core planner validates all outputs against every batch
  source before creating directories or starting workers, including adjacent
  outputs inside another RTFD source package.
- Reserve destinations by input position, retain stable result/error order, and
  wait for running conversions to clean up after cancellation. Completed results
  remain available and retries replace failed inputs only; individual process
  timeouts do not cancel the other documents.
- Serialize local Vision OCR per process with cancellation-aware waiting while
  allowing non-OCR work to continue. Show completed-file counts and each active
  app document's known progress without constructing result previews eagerly.
- Test true concurrent conversion, deterministic collisions, source-package
  protection, nil-callback result delivery, OCR waiting/cancellation and ordered
  CLI output with genuine temporary inputs.
- Add a reproducible batch benchmark with sampled process-tree memory. Eighteen
  paired-document runs retain identical output bytes; two workers reduce XLSX
  and DOCX runtime on the measured host while increasing memory use. OCR shows
  no meaningful runtime gain. Record measurements and limits in `docs/PERFORMANCE.md`.

- Import PPTX/PPTM/POTX and ODP natively through a shared slide model: source
  slide order, paragraphs and nested lists, GFM tables, speaker notes and image
  assets. Reuse verified ZIP working copies and package metadata readers; report
  macros, unsupported objects, flattened structures and missing/oversized media.
- Import version-4 IPYNB without executing code. Preserve Markdown, language-tagged
  code fences, text/error outputs and image attachments; report unsupported MIME
  outputs and unsafe or unavailable resource references. Existing Markdown code
  containers remain literal when attachment targets are rewritten.
- Add slide/cell progress, bounded XML and expanded-text/table budgets, app and
  Services file associations, and regression fixtures for content order, image
  bytes, GFM structure, cancellation, CRC failures and non-execution.

- Add remembered PDF OCR auto/always/off, shared local PDF/image OCR languages,
  automatic two-column text order, optional repeated margin removal and
  conservative dehyphenation in the app and CLI. Mixed digital/scan pages retain
  their embedded text and add scan content. Fix automatic PDF raster orientation;
  `--pdf-layout legacy` retains the previous extraction for direct comparison.
- Add optional page/sheet/cell locations to diagnostics and JSON results, including
  PDF failures, XLSX/ODS merges and discarded links, and missing spreadsheet
  formula results. Workbook location details are bounded; summary warnings remain.
- Verify real generated mixed, two-column and repeated-margin PDFs against all
  source sentences, stable counts, previous output and unchanged source bytes.

- Separate generic ZIP validation from Word/ODT package inspection. Native and
  Pandoc adapters reuse a reader bound to their own fully verified working copy,
  including its archive directory and entry index. Detection keeps a non-mapped
  descriptor snapshot; foreign source files are never mapped.
- Load and release XLSX worksheet XML and its parser one sheet at a time,
  including an autorelease pool per sheet. On a 384,000-cell fixture the largest
  measured resident set across three runs fell from 129,744,896 to 87,621,632
  bytes; all output file hashes matched the baseline. Runtime and media-heavy
  DOCX memory did not improve consistently; see `docs/PERFORMANCE.md`.
- Move OLE sector and stream handling out of the BIFF workbook parser, split
  CLI arguments, serialization and execution into separate files, and isolate
  frontmatter/Textbundle postprocessing from conversion orchestration.
- Add a reproducible macOS benchmark with generated XLSX, media-heavy DOCX and
  200 CSV inputs, complete token/asset/source checks and optional baseline
  output-hash comparison. Existing fixtures and result directories are retained.

- Carry cancellation and progress through the app, CLI, and conversion adapters.
  The app keeps its active task and cancellation token; Cancel Conversion stops
  at cooperative checkpoints, retains completed batch results, and leaves
  interrupted or unstarted inputs available for retry. Clipboard conversions
  leave the clipboard untouched when cancelled.
- Report known PDF pages, image frames, and spreadsheet sheets. Add CLI
  `--progress` on stderr and handle SIGINT/SIGTERM with exit 130 and workspace
  cleanup. External tools support `--timeout SECONDS` (exit 124); a timeout in
  one batch document does not stop later documents.
- Terminate owned helper process groups with TERM, then KILL after a short
  grace period. Bound captured tool output to 16 MiB per stream. Add cancellation
  checkpoints to package staging, ZIP inflation and CRC checks, XML delegates,
  legacy XLS parsing, CSV parsing, and spreadsheet rendering. Cancellation at
  the publication callback prevents the atomic move; cancellation after the
  finished callback leaves the published result intact.

- Remember the app's output parent, spreadsheet rendering, image OCR,
  frontmatter, and Textbundle options. Folder imports preserve their relative
  directories under the selected output parent.
- Select individual batch results, open or copy their Markdown, and show a
  bounded 256 KiB text preview. Copying explicitly reports omitted asset files.
  Retry only failed inputs while retaining successful results and list order;
  choose another output name or destination after a failure without replacing
  existing output. Keep the existing diagnostic lists visible.
- Add German interface translations to the app bundle.

- Convert several inputs in one run. The CLI accepts any number of paths, and a
  folder is searched recursively for supported file extensions: packages such
  as `.rtfd` count as one document; hidden entries, symbolic links, and earlier
  `*-markdown` results are skipped. A failure no longer stops the remaining
  documents. With `--output`, the directory becomes the parent that receives
  one `Name-markdown` folder per document and mirrors the folder structure.
  `--json` then reports a `results` list, and the exit code is that of the
  first failed input. A single file keeps the previous answer unchanged.
- Accept every dropped item in the app instead of only the first, allow
  multiple selection and folders in the open panel, and receive files opened
  together from Finder or `open -a` as one run. The window shows progress and
  an outcome per document and reveals all generated Markdown files in Finder.
- Register two system services. "Convert to Markdown with Poor Man's Text"
  appears in the Finder context menu for supported documents and folders and
  converts the selection next to its source. "Convert Text to Markdown with
  Poor Man's Text" takes selected rich text from any app, converts it through
  the RTFD or RTF path, and places the Markdown on the clipboard without
  replacing anything; images are left out and reported.
- Read document metadata: title, author, subject, description, keywords, and
  dates from OOXML core properties, OpenDocument `meta.xml`, the RTF `\info`
  group, and the PDF information dictionary. `--frontmatter` writes them as a
  quoted YAML header, and every `--json` answer carries them as `metadata`.
- Add `--textbundle`, which writes `Name.textbundle` with `text.md`, `assets/`,
  and `info.json` instead of `Name-markdown`; asset links are rewritten and a
  custom `--output` has to end in `.textbundle`. Folder searches skip bundles.
- Add `--stdout`, which prints one document's Markdown to standard output from
  a temporary conversion and reports omitted image assets on standard error.
- Accept macro-enabled Excel workbooks and templates (`.xlsm`, `.xltx`,
  `.xltm`) through the XLSX reader after checking their OOXML main content
  type. Macros and template behavior are reported as expected losses, exactly
  like DOCM and DOTX.
- Accept CSV and TSV files as a one-sheet workbook rendered like ODS or XLSX.
  The extension selects the format, because plain text cannot be recognized
  as a table by content. `.tsv` splits on tabs; `.csv` picks the separator
  (`,`, `;`, tab, or `|`) that is most consistent across the first lines.
  Quotes, doubled quotes, and line breaks inside fields follow RFC 4180. A
  byte-order mark selects UTF-8 or UTF-16; text that is not valid UTF-8 is
  read as Windows-1252 with a warning, and binary content is rejected.
- Accept HTML and XHTML files (recognized by content), Safari web archives,
  EPUB books, and the text markups LaTeX, DocBook, Org, MediaWiki, Textile,
  reStructuredText, and FictionBook through Pandoc in sandbox mode. Images
  below the source's folder are copied, embedded `data:` images are extracted,
  remote images are never fetched and become links, missing images are dropped
  with their alt text kept, and web archives use their own stored images. HTML
  `<title>` and author metadata feed the frontmatter. All of these need Pandoc
  and are listed accordingly by `--formats`.
- Accept GIF, BMP, and WebP images. They are stored byte for byte as assets and
  get the same optional local OCR as PNG, JPEG, HEIC, and TIFF.

- Review fixes (2026-09-03): image references in HTML, webarchives, and
  Pandoc-generated HTML only stay as links for `http`, `https`, `ftp`, and
  `ftps`, even when a web base URL would resolve `javascript:` or other
  schemes; local images are copied through the verified, size-bounded staging
  path and special files such as FIFOs are dropped as missing; unquoted
  `src`/`alt` attributes are read; webarchives saved from `file:` pages find
  their subresources. RTF metadata honours `\ucN` and decodes surrogate pairs.
  CSV/TSV rejects UTF-16 files that end in half a character and quoted fields
  left open at the end. Package snapshots fail on a directory read error
  instead of passing as complete. The app stays busy from the moment a drop
  is accepted, reports a clipboard write that failed, and the Finder service
  lists the macro-enabled and template Excel types and XHTML. A symbolic link
  that changes while its format is being detected is rejected.

## 0.9.1 - 2026-08-30

- Inspect PDF, DOC, and standalone RTF only through bounded private copies before
  handing a path to PDFKit, AppKit, or `textutil`. RTFD detection and conversion
  now copy a descriptor-bound package snapshot with per-file, total-byte, and
  entry-count limits and reject embedded symbolic links and special files.
- Budget image thumbnails with their integer pixel dimensions, including the
  one-pixel minimum edge, and verify the decoded frame before Vision sees it.
  A failed thumbnail no longer reports a successful downscale.
- Treat spreadsheet filenames, sheet names, and literal cell text as Markdown
  literals. One-letter schemes and drive-like targets no longer bypass the link
  allowlist.
- Reject oversized compressed ZIP metadata before taking its archive slice and
  validate stored-entry size equality before copying its bytes.
- Rewrite renamed Markdown assets with one indexed backtick scan per document.
  Optional link titles, ordered-list paragraph continuation, nested list fences,
  and all GFM HTML block classes now keep their literal contents unchanged.
- Describe a failed PDF OCR pass accurately when embedded fallback text remains
  on the affected page.

## 0.9.0 - 2026-08-30

- Scale an oversized image frame down for local OCR instead of refusing the
  whole import. A 24-megapixel photo now converts normally and reports
  `image.ocrDownscaled`; the stored asset stays the untouched original. With
  several frames the shared 64-megapixel budget is divided evenly.
- Accept only `http`, `https`, `mailto`, `file`, and scheme-less targets as
  spreadsheet hyperlink targets. A `javascript:` or `data:` target from ODS,
  XLSX, or XLS is dropped with a visible loss warning; the cell text remains. A
  single letter before the colon counts as a Windows drive, not a scheme, so
  `C:\Berichte\2026.xlsx` from an XLS file moniker survives.
- Keep the embedded text of a sparse PDF page when local OCR returns nothing or
  fails, instead of publishing an empty page section.
- Decide from its eight-byte OLE header whether a file can be a legacy XLS at
  all. Detection no longer reads an unrelated large file into memory in full:
  peak memory for a 512 MB non-spreadsheet input drops from 549 MB to 13 MB, and
  a `.xls` file without that header now names the missing OLE header instead of
  a missing ZIP signature.
- Keep the first hyperlink target of an XLSX cell when a second hyperlink
  element for the same cell carries no target of its own.
- Apply the 256 MiB rich-text size limit to the `TXT.rtf` inside an RTFD package
  as well, not only to a standalone RTF file.
- Escape Setext underlines and tilde fences in literal source text, so a line of
  `=` characters from a PDF or OCR page can no longer turn the line above it
  into a heading, and `~~~` can no longer open a code block.
- Read a foreign XLS source through a single descriptor instead of mapping it.
  A sync service replacing the file during detection can no longer end the
  process with `SIGBUS`.
- Order recognized text lines in two transitive steps — strictly top to bottom,
  then left to right within a band. The previous single comparison was not a
  strict weak ordering, so three lines could produce three different orders.
- Stage RTF, DOCX/ODT, DOC, and ODS/XLSX/XLS from the resolved source path. A
  symbolic link changed between detection and staging can no longer swap the
  converted document.
- Use the shared heading escaping in the master-document adapter instead of a
  second, character-identical copy of it.

## 0.8.5 - 2026-08-23

- Preserve one hyperlink target per spreadsheet cell from ODS XLink attributes,
  XLSX worksheet relationships, and BIFF8 HLINK records. Markdown tables render
  the link safely; escaped TSV blocks retain its Markdown source. Additional
  divergent link targets in a cell still produce a visible loss warning.
- Exercise the mapped-ZIP truncation regression in a child test process, so the
  expected `SIGBUS` cannot terminate the test runner.
- Add native PDF import through PDFKit with page markers and a local Vision OCR
  fallback. Reject encrypted, damaged, oversized, and over-budget documents
  before publication; warn explicitly about layout and OCR limits.
- Add native PNG, JPEG, HEIC, and TIFF import. Every image is retained byte for
  byte as an asset; local Vision OCR is enabled by default and can be disabled
  with `--image-ocr off`. Multi-frame TIFF uses one asset and one OCR section per
  frame.

## 0.8.4 - 2026-08-19

- Convert documents selected through a symbolic link again in every format, and
  resolve the sections of a master document next to the real master.
- Reject ZIP entries that describe a symbolic link regardless of the host system
  named in the archive, and check both readings of an entry name so that none
  can leave the package or skip size and checksum verification through a Unicode
  path field.
- Take the checks of a package and its bytes from a single file descriptor, and
  reject a named pipe or device file as input instead of waiting for it without
  a time limit.
- Share one hyperlink scan budget across all sheets of a workbook so that a
  spreadsheet within every documented limit cannot occupy detection and
  conversion for a long time.
- Keep a single space where an explicit space meets a note paragraph in master
  documents, and select attributes deterministically when a document assigns two
  prefixes to the same namespace.

## 0.8.3 - 2026-08-16

- Revalidate the exact staged DOC bytes before conversion, disable remote
  subresource loading in both `textutil` passes, and run the remaining Pandoc
  stages in its sandbox.
- Reject ZIP entries that collide after case folding or removal of a trailing
  directory slash, and keep an explicitly selected output outside the source
  package even when its path uses different letter casing.
- Bound materialized XLSX text and rendered spreadsheet output, reject cell
  references whose column overflows an integer, and stop the legacy XLS globals
  parser at its own end-of-file record.
- Resolve ODM attributes only through their declared XML namespaces, preserve
  word boundaries around nested note text, and distinguish valid Markdown
  fences and thematic breaks when rewriting asset links.
- Keep interrupted CLI-link creation and rolled-back app cleanup recoverable,
  including a retry when removing the staged replacement initially fails.

## 0.8.2 - 2026-08-09

- Generate the signed Sparkle appcast from the requested release tag and resolve
  the pinned package before the private update key enters the signing step.
- Complete the combined install-and-release transaction at the atomic DMG
  marker: an interrupt can no longer roll back the matching installation after
  the release pair became visible, and half-published checksums are removed only
  while their file identity still matches.
- Keep nested ODM note text in source order, preserve leading tabs and wide
  indentation without creating code blocks, and escape GFM strikethrough and
  entity syntax. Asset renaming now skips code spans, fenced blocks, and escaped
  literal text.
- Preserve an XLSX hyperlink's `display` text when its referenced cell is empty,
  enforce all workbook budgets for that text, and resolve worksheet relationship
  IDs only through the declared Office Document relationship namespace.
- Require every BIFF worksheet to end before the next physical sheet, reject an
  ODS spreadsheet nested below a text body, and ignore foreign OPC `Override`
  elements when identifying Word packages.

## 0.8.1 - 2026-08-07

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

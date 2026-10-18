# Text and images from the clipboard

Choose **Paste Text or Image** in the app or Edit menu. The native **Edit → Paste**
command (**⌘V**) invokes the same import through the app’s menu adapter. An active
editable text field receives its normal Paste action. Profile names and preview
search fields keep their normal editing behavior. Clipboard contents are never polled at startup, on activation or when
validating menus. The system service is another explicit invocation of the same
reader and converter.

One clipboard item is accepted. Format priority is **RTFD → RTF → HTML → PNG →
TIFF → JPEG → HEIC → GIF → BMP → WebP**, using
the [AppKit pasteboard types](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/rtf).
An invalid preferred representation fails instead of silently choosing a less
complete alternative. Empty, plain-text-only, unsupported, multiple-item and
over-64-MiB clipboards receive a message. Plain text is not guessed to be HTML
or converted as rich text. A failed read preserves an already prepared draft.

RTFD retains its attachments; RTF supports embedded images through the existing
rich-text adapter. HTML uses the existing HTML adapter and Pandoc, including
fragments, lists, links and embedded supported raster images in data URIs.
Relative images are only available inside the private source directory; a
clipboard copy does not authorize reading the source app's files. Missing local
images are diagnosed. Remote images become links and are not downloaded.
Scripts, CSS, forms and page layout are not retained. Plain Markdown does not
preserve text colors. Existing rich-text color/highlight conversion and its
warnings remain unchanged; highlight markers such as `==text==` can remain
literal in the standard Markdown preview. The conversion uses Pandoc's
[sandbox mode](https://pandoc.org/MANUAL.html#option--sandbox) and the normal
resource checks; importing HTML does not render it as an active web page.

Encoded image data uses the existing image adapter without Pandoc. The app reads
only image types advertised by the first [pasteboard item](https://developer.apple.com/documentation/appkit/nspasteboarditem),
not AppKit's extra synthesized TIFF representation. The selected bytes are
written unchanged to a private `Clipboard Image.<extension>` source and retained
byte for byte as the output asset. No source filename or path is inferred. A
file URL alone is not image data and grants no file access. Unsupported vector,
PICT/PDF-only or unencoded representations receive a message; there is no
NSImage rendering or fallback encoding. If the producer already encoded or
converted its clipboard representation, the original file bytes cannot be
reconstructed; “unchanged” refers to the bytes the clipboard item supplies.

EXIF orientation and transparency are preserved in the asset. OCR applies the
orientation once through the existing image adapter. Retina images use encoded
pixel dimensions, not their display size in points or DPI. No image is enlarged
or resized for storage. The existing per-frame OCR pixel budget can reduce only
the recognition image and reports that reduction. Multi-frame images keep the
original container and existing frame limits. Current settings and profiles
control image OCR, languages, legacy/structured recognition, layout and reports.
A profile bound to a file cannot be applied to a clipboard snapshot. A clipboard
change during the read is rejected; later changes cannot alter the snapshot.
The app adds no screen capture, activation reader or clipboard monitor.

The command captures the selected representation once. Its temporary source is
removed after conversion. The temporary result remains available for the safe
rendered/source preview until the user chooses an output or discards it:

- **Save Markdown and Assets…** chooses a new output folder or Textbundle. The
  same captured bytes and options are converted through the core's normal atomic
  publication path. Later clipboard or option changes do not change the draft.
  Existing destinations are never overwritten. Cancelling the save dialog or
  the conversion keeps the draft available for another attempt.
- **Copy Recognized Text** for image drafts copies only the OCR section, with an
  explicit omitted-image message and without the original image link. With OCR
  disabled or no recognized text, it leaves both clipboard and draft intact.
- **Copy Markdown Only** for rich-text drafts replaces the clipboard only after conversion succeeds.
  It carries text, including relative image links, and explicitly reports
  omitted assets. Those links require the separately saved result directory;
  copying does not create a permanent asset location. The existing system
  service keeps this text-only behavior.
- **Discard**, a new accepted conversion or model disposal removes the temporary
  result. A saved result has a separate lifetime and is not removed on reset.

Neither importing nor copying changes the source application or source file.
The transient source path is not a persistent document for source comparison;
clipboard results offer preview without the file-source comparison action.

`ClipboardImageTests` additionally checks real PNG/TIFF/JPEG/HEIC/GIF/BMP/WebP
bytes, transparency, orientation, Retina pixels, large-image OCR, captured
profiles, text-only output, delayed data providers, source lifetime and destination
protection on private pasteboards.

`ClipboardImportTests` uses private pasteboards and real temporary RTF, RTFD and
HTML documents. It independently checks text markers, list/link content, image
bytes, source preservation, delayed clipboard reads, captured options,
destination collisions, cancellation, missing Pandoc and temporary cleanup.
`ServicesProviderTests` retains the original service coverage. Native GUI
acceptance additionally needs actual Paste/menu/key actions, preview, saving,
copy warnings and error/cancellation states at the installed bundle.

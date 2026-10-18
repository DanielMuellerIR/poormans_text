# Rich text from the clipboard

Choose **Paste Rich Text** in the app or Edit menu. The native **Edit → Paste**
command (**⌘V**) invokes the same import through the app’s menu adapter. An active
editable text field receives its normal Paste action. Profile names and preview
search fields keep their normal editing behavior. Clipboard contents are never polled at startup, on activation or when
validating menus. The system service is another explicit invocation of the same
reader and converter.

One clipboard item is accepted. Format priority is **RTFD → RTF → HTML**, using
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

The command captures the selected representation once. Its temporary source is
removed after conversion. The temporary result remains available for the safe
rendered/source preview until the user chooses an output or discards it:

- **Save Markdown and Assets…** chooses a new output folder or Textbundle. The
  same captured bytes and options are converted through the core's normal atomic
  publication path. Later clipboard or option changes do not change the draft.
  Existing destinations are never overwritten. Cancelling the save dialog or
  the conversion keeps the draft available for another attempt.
- **Copy Markdown Only** replaces the clipboard only after conversion succeeds.
  It carries text, including relative image links, and explicitly reports
  omitted assets. Those links require the separately saved result directory;
  copying does not create a permanent asset location. The existing system
  service keeps this text-only behavior.
- **Discard**, a new accepted conversion or model disposal removes the temporary
  result. A saved result has a separate lifetime and is not removed on reset.

Neither importing nor copying changes the source application or source file.
The transient source path is not a persistent document for source comparison;
clipboard results offer preview without the file-source comparison action.

`ClipboardImportTests` uses private pasteboards and real temporary RTF, RTFD and
HTML documents. It independently checks text markers, list/link content, image
bytes, source preservation, delayed clipboard reads, captured options,
destination collisions, cancellation, missing Pandoc and temporary cleanup.
`ServicesProviderTests` retains the original service coverage. Native GUI
acceptance additionally needs actual Paste/menu/key actions, preview, saving,
copy warnings and error/cancellation states at the installed bundle.

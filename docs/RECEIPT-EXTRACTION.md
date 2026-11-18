# Extract receipt data

The macOS editor saves a versioned JSON mask for one partner and document type.
A region rule reads a rectangle on a given page. The date and identifier
suggestions look for a value of the expected shape on the same row to the
right of a label. The label and value can move together between receipts.
A region stays at its saved location. Partner and document type describe the
mask and appear in the result. They do not identify or validate the input.

## Unattended CLI

```sh
mkdir -p Results
poormans-text extract --mask northwood-invoice.json --output-dir Results --format json Invoice1.pdf Invoice2.pdf
```

The output folder must exist. With no `--output-dir`, each result is written
beside its input. With no `--format`, the output is JSON. Use `--` before input
names beginning with a dash. The command writes one JSON summary to stdout and
human-readable progress or errors to stderr. Its `items` array follows input
order. Each item has an absolute `source` path, a `status`, an `output` path
for published results, and a `diagnostic` when available.

| Exit | Meaning |
| --- | --- |
| 0 | Every document succeeded (`success`). |
| 1 | At least one document needs review (`reviewRequired`) or failed (`failed`). Inspect each item. |
| 2 | The invocation, mask, or shared destination is invalid. The summary includes `error`. |
| 130 | The run was cancelled. Check `cancelled` and per-input status. Completed results remain available. |

The complete input filename is preserved, for example
`Invoice-4711.pdf.json`. Existing files and same-name collisions in the
chosen directory are reported per input. When two inputs target the same
name, both are flagged. Other inputs still run.

## Result JSON, version 1

| Key | Contents |
| --- | --- |
| `partner`, `documentType` | Labels from the mask. |
| `data` | Field names mapped to the exact extracted strings or `null`. |
| `sources` | Field names mapped to lists of text snippets with page, rectangle and origin. |
| `review` | Field names mapped to status and any diagnostic. |
| `needsReview` | Whether any field is missing or ambiguous. |

Field names are unique strings. Status is `confirmed`, `missing`,
`ambiguous` or `corrected`. Missing and ambiguous fields have a `null`
value. Ambiguous matches remain available in `sources`, including when a
user corrects the value in the editor. Corrections are scoped to an open
receipt and can be exported from the editor to a new JSON file.

Source pages are zero-based. Rectangles contain `x`, `y`, `width` and
`height` in physical millimeters in unrotated PDF page space, from the
PDF coordinate origin, with y increasing upwards. Cropping and display zoom
do not change these coordinates. The origin of every current source is
`embeddedText`.

This first version reads embedded text in PDFs on macOS. It supports the
printed date forms `YYYY-MM-DD` and day–month–year with dots, slashes or
hyphens, and alphanumeric identifiers containing at least one digit. The
limits are 64 MiB, 1,000 pages, 100,000 UTF-16 units per page and one million
per document. Password-protected PDFs and documents with no usable embedded
text report an error. In a mixed PDF, only the embedded text contributes
evidence. OCR, position tables and other exports are tracked in the
[roadmap](../ROADMAP.md).

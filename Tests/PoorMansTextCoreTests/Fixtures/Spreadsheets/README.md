# Spreadsheet fixtures

`multisheet.ods` and `not-word.xls` were written by LibreOfficeDev 26.8 on
2026-07-25 from the same two-sheet workbook. The source contains:

- sheet `Summary` with typed numbers and two formulas;
- sheet `Details & Notes` with Unicode, a multiline cell, a pipe, and a tab.

Both files verify the native format-neutral workbook model. Their visible cell
values are compared with each other, while the XLS file additionally proves that
the legacy DOC detector does not mistake another OLE compound-document format
for Word.

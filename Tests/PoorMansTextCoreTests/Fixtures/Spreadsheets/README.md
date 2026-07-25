# Spreadsheet fixtures

`multisheet.ods` and `not-word.xls` were written by LibreOfficeDev 26.8 on
2026-07-25 from the same two-sheet workbook. The source contains:

- sheet `Summary` with typed numbers and two formulas;
- sheet `Details & Notes` with Unicode, a multiline cell, a pipe, and a tab.

The ODS file is the feasibility fixture for the future format-neutral workbook
model. The XLS file currently verifies only that the legacy DOC detector does not
mistake another OLE compound-document format for Word.

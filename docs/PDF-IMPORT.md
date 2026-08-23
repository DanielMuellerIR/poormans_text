# Nativer PDF-Import

Poor Man's Text liest PDF-Dateien ohne Pandoc oder Netzverbindung. Der Adapter
arbeitet erst mit PDFKit und setzt Vision nur für Seiten ein, auf denen PDFKit
nicht genug eingebetteten Text liefert. Das Ergebnis ist eine Inhaltsübernahme,
keine Nachbildung des Seitenlayouts.

## Erkennung und Grenzen

Der Adapter erkennt `%PDF-` im Dateikopf und öffnet anschließend die Datei mit
PDFKit. Eine `.pdf`-Endung ohne gültigen Inhalt führt zu einer verständlichen
Eingabediagnose. Dateien ohne Endung werden ebenfalls akzeptiert, wenn ihr Inhalt
ein lesbares PDF ist.

Die Quelle muss eine reguläre Datei bis 1 GiB sein. Passwortgeschützte oder
gesperrte Dokumente, beschädigte PDFs, leere Dokumente und Dokumente mit mehr als
1.000 Seiten werden abgelehnt. Vor jeder Konvertierung kopiert der Adapter die
Quelle begrenzt in den privaten Arbeitsbereich; danach lesen alle weiteren
Schritte nur diese Kopie.

## Textextraktion und OCR

Jede Ausgabe beginnt mit dem Quelldateinamen und enthält für jede PDF-Seite einen
eigenen `## Page N`-Abschnitt. PDFKit liefert den eingebetteten Seitentext zuerst.
Bleiben nach Bereinigung weniger als 20 Zeichen, rendert der Adapter die Seite
mit maximal doppelter PDF-Auflösung und liest das Bild lokal mit Vision in der
genauen Erkennungsstufe.

Die Rasterung ist begrenzt: eine Seite darf höchstens 16 Millionen Pixel haben;
alle OCR-Seiten zusammen höchstens 64 Millionen Pixel. Der Adapter berechnet
diese Arbeit vor dem ersten OCR-Aufruf und bricht bei Überschreitung ab. Vision-
Zeilen werden von oben nach unten und dann von links nach rechts geordnet.
Ergebnisse mit geringer Erkennungswahrscheinlichkeit erscheinen als
`[OCR uncertain: …]`. Eingebetteter Text und OCR-Text teilen ein Limit von
64 MiB; durch das Maskieren bleibt das erzeugte Markdown damit innerhalb des
128-MiB-Ausgabebudgets.

`pdf.ocrApplied` weist auf verwendete lokale OCR hin. Liefert sie keinen Text,
steht im Seitenabschnitt eine sichtbare Leermeldung und der Adapter meldet
`pdf.pageTextUnavailable`; bei einem Vision-Fehler kommt zusätzlich
`pdf.ocrFailed`. Jede PDF-Konvertierung meldet außerdem
`pdf.layoutNotPreserved`.

## Bewusste Grenzen

PDF-Spalten, Tabellen, Kopf- und Fußzeilen, exakte Textpositionen, Bilder und
Vektorzeichnungen bleiben nicht erhalten. Der Adapter extrahiert PDF-Bilder nicht
als Assets: Ohne eine verlässliche Position im Text würde ihre Reihenfolge ein
falsches Ergebnis suggerieren. Markdown-Metazeichen aus PDFKit und Vision werden
maskiert, damit der unstrukturierte Seitentext keine Überschrift, Tabelle oder
einen Link in der Ausgabe erzeugt.

Die Tests erzeugen echte mehrseitige PDFs, prüfen den Text und die unveränderte
Quelle und decken OCR-Fallback, falsche Signaturen, Verschlüsselung sowie Seiten-
und Pixelbudgets ab.

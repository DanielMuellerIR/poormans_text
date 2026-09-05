# Nativer PDF-Import

Poor Man's Text liest PDF-Dateien ohne Pandoc oder Netzverbindung. Der Adapter
liest eingebetteten Text mit PDFKit und ergänzt bei Bedarf lokale Vision-OCR.
Zweispaltigen Text ordnet er nach Positionen; er bildet keine PDF-Seiten nach.

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
`--pdf-ocr auto` (Standard) plant OCR bei weniger als 20 Textzeichen oder
bei einer größeren Bildressource (mindestens 256 × 128 Pixel), auch innerhalb
von Form-XObjects. So verdeckt ein digitaler Kopf keinen gescannten Hauptteil.
Das kann bei Fotos oder ungenutzten Bildressourcen zusätzliche OCR auslösen.
`--pdf-ocr always` liest jede Seite mit Vision; `--pdf-ocr off` rendert keine
OCR-Seiten. `--ocr-language de,en` beschränkt PDF- und Bild-OCR auf lokal
unterstützte Sprachen; ohne Liste entscheidet Vision automatisch. Unbekannte
oder leere Sprachcodes sind Eingabefehler. Alle Optionen sind auch in den
gemerkten App-Einstellungen verfügbar.

Die Rasterung ist begrenzt: eine Seite darf höchstens 16 Millionen Pixel haben;
alle OCR-Seiten zusammen höchstens 64 Millionen Pixel. Der Adapter berechnet
diese Arbeit vor dem ersten OCR-Aufruf und bricht bei Überschreitung ab. Vision-
Zeilen werden von oben nach unten und dann von links nach rechts geordnet.
Ergebnisse mit geringer Erkennungswahrscheinlichkeit erscheinen als
`[OCR uncertain: …]`. Eingebetteter Text und OCR-Text teilen ein Limit von
64 MiB; durch das Maskieren bleibt das erzeugte Markdown damit innerhalb des
128-MiB-Ausgabebudgets.

Eingebetteter Text bleibt vollständig erhalten. Der Adapter ergänzt OCR-Zeilen
und entfernt nur räumlich überlappende, exakt textgleiche Dubletten. Abweichende
OCR-Lesarten können deshalb zusätzlich zum digitalen Original erscheinen.

Die automatische Textordnung liest Zeichen über `PDFSelection`, prüft den
nichtleeren Zeichenbestand und trennt große horizontale Lücken. Mindestens zwei
Zeilen auf jeder Seite der Seitenmitte erlauben zwei Spalten: links vollständig,
dann rechts, mit breiten Zwischenüberschriften als Abschnittsgrenzen. Rotation,
RTL-Schrift, mehr als 100.000 UTF-16-Zeichen auf einer Seite, ungültige Positionen
oder abweichende Zeichen fallen auf den gesamten
PDFKit-Originaltext zurück und melden `pdf.layoutFallback`. Unsymmetrische oder
mehr als zwei Spalten bleiben eine Grenze dieser Heuristik.

`--pdf-remove-headers-footers` entfernt optional identischen Text in den oberen
oder unteren zehn Prozent, wenn er auf mindestens zwei und 60 Prozent aller
Seiten in derselben Randzone vorkommt. Gleichlautender Haupttext bleibt erhalten;
wechselnde Seitennummern werden nicht normalisiert. Die Diagnose nennt die Seite.
Soft-Hyphens werden bereinigt. `--pdf-dehyphenate` verbindet zusätzlich nur lange
kleingeschriebene Wortteile an benachbarten Zeilen derselben Spalte (mindestens
vier Zeichen vor und drei nach dem Trennstrich). Das bleibt eine opt-in Heuristik,
keine Wörterbuchprüfung; echte Bindestrichwörter können betroffen sein.

`--pdf-layout legacy` erhält die bisherige PDFKit-/OCR-Extraktion als Vergleich.
Ohne weitere Optionen bleibt ihre Ausgabe bytegleich zur früheren CLI, inklusive
ihrer damaligen Rasterorientierung. Spalten- und Randbereinigung wirken nur im
automatischen Layout. Neue automatische OCR rendert in PDF-Koordinaten; ein
zusätzlicher Y-Flip hatte Rastertext aufrecht erzeugter PDFs bisher gespiegelt.

`pdf.ocrApplied` weist auf verwendete lokale OCR hin. Bleibt eine Seite ganz
ohne Text, steht im Seitenabschnitt eine sichtbare Leermeldung und der Adapter
meldet `pdf.pageTextUnavailable`; bei einem Vision-Fehler kommt zusätzlich
`pdf.ocrFailed`. Jede PDF-Konvertierung meldet außerdem
`pdf.layoutNotPreserved`.

## Bewusste Grenzen

Komplexe PDF-Spalten, Tabellen, exakte Textpositionen, Bilder und
Vektorzeichnungen bleiben nicht erhalten. Der Adapter extrahiert PDF-Bilder nicht
als Assets: Ohne eine verlässliche Position im Text würde ihre Reihenfolge ein
falsches Ergebnis suggerieren. Markdown-Metazeichen aus PDFKit und Vision werden
maskiert, damit der unstrukturierte Seitentext keine Überschrift, Tabelle oder
einen Link in der Ausgabe erzeugt.

Die Tests erzeugen echte mehrseitige PDFs, prüfen den Text und die unveränderte
Quelle und decken OCR-Fallback, falsche Signaturen, Verschlüsselung sowie Seiten-
und Pixelbudgets ab.

## Nachweis

`PDFQualityTests` erzeugt ohne Fenster drei echte CoreText/CoreGraphics-PDFs:
eine gemischte Seite mit digitalem Kopf und sechs gerasterten Sätzen, zwei
Spalten mit je acht eindeutigen Zeilen und drei Seiten mit wiederkehrenden
Rändern sowie einem identischen Kopftext im Hauptteil. Tests prüfen jeden Satz,
jede Zeile genau einmal, Spaltenreihenfolge, OCR aus/immer, Randbereinigung und
unveränderte Quellenbytes. Ein unabhängiger Lauf dieser Dokumente gegen die
vorherige CLI bestätigte bytegleiche Legacy-Ausgaben und den zuvor fehlenden
Rastertext. Die Fixtures enthalten kontrollierten Text; komplexe reale Layouts
und OCR-Genauigkeit bleiben dokumentabhängig.

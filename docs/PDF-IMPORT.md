# Nativer PDF-Import

Poor Man's Text liest PDF-Dateien ohne Pandoc oder Netzverbindung. Der Adapter
liest eingebetteten Text mit PDFKit und ergänzt bei Bedarf lokale Vision-OCR.
Zweispaltigen Text ordnet er nach Positionen; er bildet keine PDF-Seiten nach.

Ein separater [strukturierter OCR-Prototyp](STRUCTURED-OCR.md) untersucht
Absätze, Listen und Tabellen ab macOS 26. Er wird vom PDF-Import noch nicht
aufgerufen; seine Vergleichsergebnisse ändern die bestehenden Optionen nicht.

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

## Seiten auswählen

`--pdf-pages "1,3-5"` importiert nur diese einsbasierten, inklusiven Bereiche.
Mehrere Bereiche sind durch Kommas getrennt; Überschneidungen und Dubletten
werden zusammengeführt. Die Ausgabe folgt immer der Quellreihenfolge und behält
die tatsächlichen Nummern in `## Page N`, Diagnosen und Quellzuordnungen.
Ohne Option werden alle Seiten importiert. Leere, rückwärts laufende und
außerhalb des Dokuments liegende Bereiche sind Fehler; sie werden nicht gekürzt.
Bei anderen Eingabeformaten ist die PDF-Auswahl unzulässig.

Die Auswahl wirkt vor Textextraktion und OCR-Planung. Text- und OCR-Pixelbudgets
zählen die tatsächlich gewählten Seiten; Quelldateigröße und die Grenze von
1.000 Seiten gelten weiterhin für das gesamte PDF. Fortschrittszahlen beziehen
sich auf die gewählte Seitenzahl. Randbereinigung bewertet nur gewählte Seiten;
Dehyphenierung verbindet niemals Text über eine Seitengrenze hinweg. Beide
Layoutvarianten unterstützen die Auswahl; Rand-/Spaltenbereinigung bleiben wie
bisher dem automatischen Layout vorbehalten.

Die Library bietet `ConversionOptions.pdfPages: IndexSelection?` und eine
kanonisch codierte Bereichsauswahl. Konvertierungsberichte halten sie als
optionales `options.pdfPages` fest. Die spätere App-Auswahl kann über
`DocumentConverter.inspectPDFContents` bis zu 500 Seitenmetadaten mit Quellhash,
Gesamtzahl, ursprünglichen Nummern, begrenzten Labels und Seitengrößen abrufen.
Diese Übersicht importiert keinen Text, rendert keine Seiten, startet keine OCR
und schreibt keine Ausgabe. Die eigentliche Konvertierung prüft die Quelle neu.

## Textextraktion und OCR

Jede Ausgabe beginnt mit dem Quelldateinamen und enthält für jede gewählte
PDF-Seite einen eigenen `## Page N`-Abschnitt. PDFKit liefert den eingebetteten
Seitentext zuerst.
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

Im automatischen Layout bleibt eingebetteter Text vollständig erhalten. Der Adapter ergänzt OCR-Zeilen
und entfernt nur räumlich überlappende, exakt textgleiche Dubletten. Abweichende
OCR-Lesarten können deshalb zusätzlich zum digitalen Original erscheinen.

Die automatische Textordnung liest Zeichen über `PDFSelection` und prüft den
nichtleeren Zeichenbestand. Synthetische Leerzeichen bestimmen nicht die Breite
einer Zeile: PDFKit kann ein einzelnes Leerzeichen über die ganze Tabellenlücke
spannen. Die sichtbaren Zeichen trennen große horizontale Lücken. Vorhandene PDFKit-
Zeilengrenzen bleiben auch innerhalb desselben Höhenbandes getrennt.

PDFKit-Schriftgrößen liefern die häufigste, nach Zeichen gewichtete nichtfette
Fließtextgröße der gewählten Seiten. Größere, einheitlich gesetzte Textzeilen mit
Buchstaben werden als Überschriften ausgegeben; absteigende Größen ordnen ihre
Ebenen unter den Seitenüberschriften ein. Gemischte Schriftgrößen, fehlende
Schriftinformationen und OCR-Zeilen bekommen keine erfundene Schriftgröße.
Das ist keine Garantie für die semantische Hierarchie: große Hervorhebungen und
Titelseiten können die Einordnung beeinflussen, ersetzte Fonts verbergen Fettdruck.

Einfache Tabellen brauchen ein geschlossenes rechteckiges Gitter aus lokalen,
ach Transformation achsenparallelen PDF-Pfaden. Die tatsächlichen Strichbreiten
liefern die geometrische Toleranz. Werte müssen vollständig in eine Zelle passen;
leere Zellen bleiben leer, mehrzeilige Werte werden mit `<br>` verbunden. Eine
fette erste Zeile oder eine Beschriftung über einer rein numerischen Spalte dient
als Tabellenkopf. Sonst bleibt die erste Quellzeile eine Datenzeile unter einem
leeren Markdown-Kopf. Pfad-, Stapel- und Gitterbudgets begrenzen die Verarbeitung;
Form-XObjects und gekrümmte Pfade werden nicht als Tabellenbeleg interpretiert.

Mindestens zwei Zeilen auf jeder Seite der Seitenmitte sind nur ein Kandidat für
zwei Spalten. Die beobachtete linke Kante der rechten Spalte bestimmt die Gasse; linke
Textzeilen dürfen bis dorthin über die geometrische Seitenmitte hinausreichen.
Auf beiden Seiten müssen zusätzlich benachbarte Textfortsetzungen
vorliegen (Folgezeile beginnt klein, vorherige endet nicht mit Satzabschluss).
Dann folgt links vollständig vor rechts, mit breiten Zwischenüberschriften als
Abschnittsgrenzen. Allein stehende Seitenzahlen in der unteren Zehn-Prozent-
Randzone folgen hinter beiden Spalten. Fehlt dieser zusätzliche Beleg, bleibt die Zeilenordnung und
`pdf.layoutAmbiguous` samt sichtbarem Hinweis nennt die Mehrdeutigkeit zwischen
Tabellenzuordnung und parallelem Text. Gleichförmige Listen werden nicht still
zu Spalten erklärt. Dieses Textsignal bleibt eine Heuristik.

Rotation, RTL-Schrift, mehr als 100.000 UTF-16-Zeichen auf einer Seite, ungültige
Positionen oder abweichende Zeichen fallen auf den gesamten PDFKit-Originaltext
zurück und melden `pdf.layoutFallback`. Unsymmetrische oder mehr als zwei Spalten,
Tabellen ohne rekonstruierbares Gitter sowie komplexe Zellverschachtelungen bleiben
Grenzen. Bei ungenügendem Beleg wird keine Tabellenstruktur erfunden.

`--pdf-remove-headers-footers` entfernt optional identischen Text in den oberen
oder unteren zehn Prozent, wenn er auf mindestens zwei und 60 Prozent aller
gewählten Seiten in derselben Randzone vorkommt. Gleichlautender Haupttext bleibt erhalten;
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
Im Legacy-Modus ersetzt nichtleere OCR den eingebetteten Rückfalltext. Dabei
können bestehende OCR-Lesefehler Zeichen verändern oder auslassen; dieser Weg
bleibt ein Vergleich mit dem bisherigen Verhalten.

`pdf.ocrApplied` weist auf verwendete lokale OCR hin. Bleibt eine Seite ganz
ohne Text, steht im Seitenabschnitt eine sichtbare Leermeldung und der Adapter
meldet `pdf.pageTextUnavailable`; bei einem Vision-Fehler kommt zusätzlich
`pdf.ocrFailed`. Jede PDF-Konvertierung meldet außerdem
`pdf.layoutNotPreserved`.

## Bewusste Grenzen

Komplexe PDF-Spalten und Tabellen, exakte Textpositionen, Bilder und
Vektorzeichnungen bleiben nicht erhalten. Der Adapter extrahiert PDF-Bilder nicht
als Assets: Ohne eine verlässliche Position im Text würde ihre Reihenfolge ein
falsches Ergebnis suggerieren. Markdown-Metazeichen aus PDFKit und Vision werden
maskiert; nur der Renderer erzeugt erkannte Überschriften und Tabellen.
Quellzeichen können keine zusätzlichen Strukturen oder Links einschleusen.

Die Tests erzeugen echte mehrseitige PDFs, prüfen den Text und die unveränderte
Quelle und decken OCR-Fallback, falsche Signaturen, Verschlüsselung sowie Seiten-
und Pixelbudgets ab.

## Nachweis

`PDFQualityTests` erzeugt ohne Fenster drei echte CoreText/CoreGraphics-PDFs:
eine gemischte Seite mit digitalem Kopf und sechs gerasterten Sätzen, zwei
Spalten mit je acht eindeutigen Zeilen und drei Seiten mit wiederkehrenden
Rändern sowie einem identischen Kopftext im Hauptteil. Tests prüfen jeden Satz,
jede Zeile genau einmal, Mehrdeutigkeit gleichförmiger Spaltenkandidaten, OCR aus/immer, Randbereinigung und
unveränderte Quellenbytes. Ein unabhängiger Lauf dieser Dokumente gegen die
vorherige CLI bestätigte bytegleiche Legacy-Ausgaben und den zuvor fehlenden
Rastertext. Die Fixtures enthalten kontrollierten Text; komplexe reale Layouts
und OCR-Genauigkeit bleiben dokumentabhängig.

`PDFStructureTests` erzeugt eine weitere echte temporäre PDF-Datei mit
Schriftgrößen, Gitterzellen und Markdown-Metazeichen. Sie prüft Überschrift,
Zellzuordnung, Maskierung und unveränderte Quellbytes. Eine optional über
`POORMANS_PDF_REAL_MATRIX` bereitgestellte private Matrix ergänzt reale
Überschriften, mehrzeilige und leere Zellen sowie echte Zweispaltenfortsetzungen;
die Dokumente selbst werden nicht im Repository gespeichert.

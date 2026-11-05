# P09/P10: PDF, Bilder, Standard-OCR und begrenztes RTFD

Stand: 2026-11-05, Produktstand 0.41.9; Legacy-DOC ergänzt in 0.41.10 und optionales HEIC in 0.41.11. Diese Backends sind im gemeinsamen
Swift-Kern integriert. Die früheren P04-Proben allein wären dafür kein Beleg.
Eine vollständige Qualitätsgleichheit mit den Mac-Backends ist noch nicht abgenommen.

## Backendgrenzen

| Fähigkeit | Integrierter Linux-Pfad | Bewusste Grenze |
| --- | --- | --- |
| PDF | Externer Python-/GI-Poppler-/Cairo-Prozess, verifizierte Quelle, Seitenauswahl, Text und Positionen, sichere Links, Anmerkungen und PNG-Bilder | Keine Tabellen-/Typografierekonstruktion; Vektorgrafiken und besondere Annotationsfelder werden als Verlust benannt. Bilder stehen am Seitenende; ursprüngliche Kompression und Platzierung bleiben nicht erhalten. |
| Standard-OCR | Lokales Tesseract mit tatsächlich installierten Sprachdaten, begrenztem TSV und normierten Rechtecken | Ohne Sprachauswahl installiertes Englisch, andernfalls erste verfügbare Sprache; Diagnose statt angeblicher automatischer Mehrsprachenerkennung. |
| Rasterbilder | Lokales Pillow; PNG/APNG, JPEG, GIF, TIFF, BMP und WebP | Alle Frames werden geprüft; [HEIC](P09-HEIC.md) verwendet optional libheif. Originalbildbytes bleiben als Asset erhalten. |
| RTFD | Verifizierter Paketsnapshot, bytebasierte NeXTGraphic-Vorbereitung und vorhandener RTF-/Pandoc-Pfad | Direkte lokale statische PNGs; andere Anhänge, Inline-Bild-/Objektziele und komplexe Attachmentnamen werden ausdrücklich abgewiesen. |
| Legacy-DOC | [Isoliertes LibreOffice/UNO](P10-DOC-UNO.md), explizit NEVER_EXECUTE/NO_UPDATE, unabhängiger TXT-Abgleich | Legacy-Layout/OLE-/Word-Parität wird nicht behauptet; Sicherheitskontrollen für neue Officeversionen wiederholen. |
| Strukturierte OCR | Nicht verfügbar | Der [P11-Qualitätsversuch](P11-QUALITY.md) rechtfertigt keine Integration. |

PDF und Rasterdecoder sind Ressourcen des SwiftPM-Core-Targets. Sie werden mit
der CLI ausgeliefert, laden ihre Bibliotheken jedoch aus ausdrücklich installierten
Hostpaketen. Paketnamen und Laufzeitgrenzen stehen in [LINUX-BUILD](../LINUX-BUILD.md).
Es gibt weder Netzwerkzugriffe noch automatische Paket-, Sprach- oder Modelldownloads.

Die Hilfsprozesse verwenden die produktive PID-/Netzwerkisolation und gebundene
Schreibbereiche. Eingaben werden vorher verifiziert kopiert. Speicher, Dateien,
Frames, Pixel, Geometrie und Capturegröße sind begrenzt. Fehlende Fähigkeiten
liefern Exit 69; Ein-/Ausgabefehler einschließlich vollem Speicherplatz Exit 74;
Timeout und Abbruch behalten ihre bestehenden Exitcodes. Der Rasterdecoder
übernimmt auch das vom Aufrufer gesetzte Prozesszeitlimit.

## Inhaltserhalt

Digitaler PDF-Text wird zuerst übernommen und gegen das Zeichen-/Zeileninventar
geprüft. Die vorhandene gemeinsame Layoutlogik ordnet Zeilen, entfernt auf Wunsch
wiederholte Ränder und verbindet konservativ Trennstellen. OCR ergänzt vorhandenen
Text: Nur räumlich und textlich übereinstimmende Dubletten entfallen; widersprechende
überlappende OCR ersetzt keinen Digitaltext und erzeugt eine Verlustdiagnose.
Datumsmetadaten vor 1970 bleiben erhalten. Deutliche räumliche Glyphenlücken
ergänzen unter Linux fehlende Wortabstände; Zeichenbestand und gelieferte
Zeilenreihenfolge bleiben erhalten. Dies rekonstruiert keine Tabellenzellen.
Unsichere Linkaktionen werden nicht ausgeführt.

Raster-OCR berücksichtigt EXIF-Lage, mehrere Frames und Transparenz auf weißem
Hintergrund. Die vollständige Bilddatei bleibt bytegleich als Asset erhalten.
RTFD bewahrt Original-RTF-Bytes im Snapshot, Encoding, Listen und Attachmentpositionen;
der PNG-Decoder prüft jede referenzierte Datei vollständig, ohne Symlinks oder
FIFOs zu öffnen. Nicht dargestellte Paketanhänge erhalten eine Verlustdiagnose.

## Ausgeführte Produktprüfungen

Die reproduzierbaren Prüfläufe unter `scripts/linux-probes/p09` und `p10-rtfd`
erzeugen synthetische Dokumente und prüfen die echte CLI:

- PDF: 13 Fälle mit unabhängigem Wortbestand, Digitaltext/OCR-Mischung, Seite 2,
  Bildpixeln, Link/Anmerkung/Autor, Randbereinigung, Dehyphenation, Legacy-Reihenfolge,
  Datumsmetadaten vor 1970 sowie defekter, verschlüsselter und ungültig ausgewählter
  Eingabe. Strukturierte OCR scheitert ausdrücklich; bei ausgeschalteter OCR bleibt
  eine ungenutzte Methodenwahl zulässig.
- Bilder: 15 Fälle einschließlich neun Bildvarianten, mehrerer Frames, EXIF-Lage,
  transparentem schwarzen Text, ausgeschalteter OCR, fehlender Sprache, echtem
  Prozesszeitlimit sowie beschädigter und übergroßer Eingabe.
- RTFD: elf Fälle mit Sonderzeichen, Unicode, Listen, zwei Namenskodierungen,
  bytegleichen PNGs sowie entfernten/absoluten/fehlenden Verweisen, Traversal,
  Symlink, FIFO, beschädigtem und unbenutztem Anhang.

Quellbytes, Ergebnis-/Berichtshashes und fehlende Veröffentlichung bei Fehlern
werden geprüft. Kleine Belege stehen unter [P09-EVIDENCE](P09-EVIDENCE/pdf.json)
und [P10-RTFD-EVIDENCE](P10-RTFD-EVIDENCE.json). Ein direkter Schreibfehler am
Cairo-/Pillow-Hilfsprozess ist zusätzlich Exit 74 zugeordnet; das ersetzt nicht
den gesonderten [vollen ext4-Produktlauf](P06-INTEGRATION.md).

Offen bleiben der neue native Mac-Regressionslauf, der vollständige Mint-Backendlauf,
ein breiter natürlicher gepaarter Qualitätskorpus und die genannten Fähigkeitsgrenzen.
Die hier bestandenen synthetischen Produktläufe belegen keine vollständige P09-/P10-Abnahme.

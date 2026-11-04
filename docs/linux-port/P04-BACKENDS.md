# P04: Linux-Backendproben

Prüfdatum: 2026-11-04. Linux- und Mac-Quellstand: `17328f17d63843025b33b45a87fa3d13db5e11d7`, Mac-CLI 0.41.7, macOS 26.7.2, nativ arm64. Es wurden ausschließlich selbst erzeugte, kleine Dokumente verarbeitet; keine Produktadapter und keine Repositoryänderungen.

**Entscheidung:** Poppler und Tesseract sind für begrenzte Fähigkeiten brauchbare Kandidaten, LibreOffice ist für DOC weiter prüfbar. P04 ist insgesamt **nicht bestanden**: RTFD benötigt einen eigenen Paket-/Assetpfad, HEIC ist hier nicht lauffähig und für strukturierte OCR fehlt ein gleichwertiger Linux-Nachweis. P11 bleibt offen; vollständige Linux-Funktionsgleichheit ist damit nicht belegt.

## Reproduktion

Die [Probeskripte](../../scripts/linux-probes/backends) erzeugen ihre Fixtures;
kleine gespeicherte Vergleichsergebnisse stehen unter [P04-EVIDENCE](P04-EVIDENCE).

`run-probes.sh` erstellt standardmäßig ein neues temporäres Arbeitsverzeichnis. Alternativ `PMT_P04_ROOT=/absoluter/neuer/pfad ./run-probes.sh` verwenden. Benötigt werden Python mit Pillow und PyGObject/Poppler-GI, Poppler-Werkzeuge und -Entwicklungspaket, C-Compiler, Tesseract mit eng/deu/osd, ImageMagick, bubblewrap und LibreOffice. QPDF ergänzt optional den Passwortfehlerfall. Die Proben installieren oder laden nichts nach. Vor erneutem Lauf einen neuen Ausgabeordner wählen.

Der vollständige Linux-Ablauf wurde nach Umstellung auf einen frei wählbaren Root in einem frischen Verzeichnis erfolgreich wiederholt. Mac-Ergebnisse sind in `mac-summary.json` verdichtet; `mac-run.py` kann nach Übertragung derselben Fixturebytes separat nativ ausgeführt werden. Kein SSH-Ziel ist im Probenpaket gespeichert.
Der DejaVuSans-Pfad ist über `PMT_P04_FONT` anpassbar; der geprüfte CachyOS-Pfad
lautet `/usr/share/fonts/TTF/DejaVuSans.ttf`. Die Backendprobe wurde auf CachyOS
ausgeführt; die Laufzeitprobe P02 zusätzlich auf Mint. Das sind getrennte Abnahmen.

## Tatsächliche Befunde

| Fähigkeit | Linux-Befund | Gepaarter Mac-Befund / Grenze |
| --- | --- | --- |
| PDF | Poppler GLib liefert 2 Seiten, Größen 600×800, 44/14 Zeichenrechtecke, 1 Bild mit 2×2 Pixeln und Platzierung, 1 URI-Link sowie Textannotation samt Inhalt. C-Probe liest die genaue URI; `pdfimages` extrahiert das Bild. | PMT erhält alle 4 Textmarker, Link und Annotation. Poppler liest `ALPHA, GAMMA, BETA`, Mac `ALPHA, BETA, GAMMA`: Lesereihenfolge ist nicht identisch. Im bestehenden Mac-PDF-Output kein Bildasset; Extraktionsfähigkeit und Produktdarstellung sind getrennte Aussagen. |
| PDF-Fehler | Beschädigtes PDF: GLib-Fehler „document is damaged“. AES-256-Fixture mit QPDF erzeugt: `pdftotext` meldet falsches/fehlendes Passwort und Exit 1. | Beschädigtes PDF: PMT Exit 65. Verschlüsseltes PDF wurde auf Mac nicht zusätzlich gepaart. |
| Standard-OCR | 1600×1100 Scan, eng+deu, 43 Wortboxen in TSV plus hOCR-Boxen. Alle 6 ALPHA-Marker sowohl normal als auch 90° gedreht erkannt (`--psm 1` beim gedrehten Fall). | Mac erkennt beide Scans; beim gedrehten Scan weicht seine Lesereihenfolge ab. Tesseract macht Umlautfehler („schéne“, „Minchen“); Mac liest diese Wörter hier korrekt. Kein allgemeiner Qualitätsnachweis. |
| Sprachdiagnose | Nicht vorhandenes `zzz` liefert Exit 1 mit fehlender Sprachdatei, keine stillen Downloads. | Nur installierte eng/deu/osd geprüft; keine automatische Zuordnung der PMT-Sprachcodes implementiert. |
| Gemischtes PDF | PDF mit auswählbarem DIGITAL-Header und gescanntem Rest: Poppler-Text liefert nur Header; gerenderte OCR liefert Header und alle Scanmarker. | Mac `auto` erhält beides. Linux-Probe belegt die Bestandteile, keinen implementierten sicheren Merge/keine Duplikatvermeidung. |
| Bilder | Pillow: PNG/JPEG/WebP/BMP-Metadaten, JPEG-EXIF 6 mit 80×40 → 40×80, GIF/TIFF je 2 tatsächlich geladene Frames mit roten/blauen Pixeln. Beschädigtes PNG abgewiesen. 100000×100000-PNG bereits beim Headerlesen als Dekompressionsbombe abgewiesen. | Mac meldet bei GIF/TIFF beide Frames und erhält Originalassets. Kein großer Decoderkorpus, keine vollständige PMT-Grenzwertprüfung. |
| HEIC | ImageMagick nennt heic als Builddelegate, aber tatsächliches HEIC-Modul ist wegen fehlendem `libheif.so.1` nicht ladbar. Explizite HEIC-Ausgabe scheitert. Die bloße Delegate-Liste ist kein Formatnachweis. | Kein echter HEIC-Vergleich. HEIC bleibt offen. |
| RTF | CP1252-Hexescapes und `\\u937?` ergeben „Grüße aus München Ω“; eingebettetes PNG und Hyperlink kommen im LO-HTML an. | Mac erhält gleiche Textmarker, 1 Bildasset und Link. Enthaltene Nummern sind **literale Listen**, keine Abnahme semantischer Listenmetadaten. |
| DOC | Echtes OLE/DOC durch LO aus synthetischem RTF erzeugt und wieder nach HTML gelesen: Text/Encoding, Bild und Link vorhanden. | Bestehender Mac-Legacypfad erhält Text, verliert hier das Bild und zeigt das HYPERLINK-Feld als Text; `legacyWord.potentialLoss` ist vorhanden. Der kleine selbst erzeugte Roundtrip ersetzt keinen unabhängigen Legacy-DOC-Korpus. |
| RTFD | Paket enthält TXT.rtf und lokales PNG. LO liest TXT.rtf-Text/Encoding, gibt `image.png` jedoch als Text aus; kein Bildasset. | Mac erhält PNG als Asset. LO allein ist kein RTFD-Ersatz. Bestehende Vorbereitung nutzt AppKit und textutil; eigener sicherer Paketpfad bleibt erforderlich. |
| Strukturierte OCR | Synthetische Seite mit 2 Textspalten, nummerierter Liste, 3-Spalten-Tabelle mit verbundenem Header und Farbfoto: Tesseract liefert Text/Geometrie, keine Tabellen-/Zellsemantik. Spalten werden zeilenweise gemischt; A1/B1 werden Al/Bl. | Mac `structured` liefert echte Markdown-Tabelle mit 3 Spalten und `ocr.tableSpansFlattened`. Auch Mac macht hier A1→Al. Tesseract-TSV/hOCR belegt keine Gleichwertigkeit; P11 blockiert volle Portierung. |

## LibreOffice-Isolation und Sicherheitsgrenzen

Die tatsächlichen LO-Läufe verwendeten separates Profil, `DisableMacrosExecution=true`, höchste Makrosicherheitsstufe, deaktiviertes Linkupdate, kein Display, 30 Sekunden Timeout mit Kill nach weiteren 2 Sekunden, eigenen PID-/Netznamespace und `--die-with-parent`. Hostdateisystem read-only; private Home-/Run-Verzeichnisse verborgen; Schreiben nur im eigenen Probenbaum beziehungsweise temporärem Namespace. Bubblewrap benötigt in dieser Ausführungsumgebung eine genehmigte Ausführung außerhalb der Agentensandbox.

Netzwerkisolation ist direkt belegt: im Namespace keine Routingtabelle; Verbindungsversuch zu einer numerischen externen Adresse endet mit ENETUNREACH (101). Ein synthetisches Dokument mit Remote-Bild wurde darin erfolgreich exportiert. **Der Export behält die Remote-URL im HTML.** Ein späterer Adapter muss sie entfernen/diagnostizieren; das HTML darf nicht ungeprüft aktiv angezeigt werden. Es wurde kein entfernter Inhalt geladen.

Makros wurden per dokumentierter und in der installierten Registry nachgelesener Konfiguration gesperrt; die Einstellung blieb im Profil erhalten. **Ein echter ausführbarer Makro-Ereignistest mit positiver Kontrolle fehlt.** Diese Probe ist keine allgemeine Sicherheitsabnahme für fremde Dokumente. Die erste Wahl des VCL-Plugins `gen` scheiterte am fehlenden Display; `svp` lief. `--headless` allein wäre unzureichend.

## Versionen, Abhängigkeiten und Distribution

Gemessen: Poppler/GLib 26.10.0; Tesseract 5.5.4 mit Leptonica 1.87.0; Pillow 13.0.0; ImageMagick 7.1.2-35 Q16-HDRI; LibreOffice 26.8.1.1 (`bf8adb135da2784a1be3ca33001278b7a20af5c1`). GdkPixbuf 2.44.8 wurde zusätzlich erkundet, scheiterte in der Agentensandbox an gesperrtem D-Bus und gilt hier weder als bestanden noch als verworfen.

Bevorzugte Paketierungsrichtung: installierte Distributionspakete als ausdrücklich erkannte externe Abhängigkeiten samt fehlenden Sprach-/Codecdiagnosen. Keine Bibliotheken oder Modellgewichte werden durch diese Proben in PMT eingebettet. Vor einer Bindung oder Bündelung bleiben exakte Paketlizenz, Drittbibliotheken, Lizenztexte/Quellbereitstellung und Updateverantwortung zu prüfen.

- [Poppler-Upstream](https://poppler.freedesktop.org/) veröffentlicht 26.10.0 mit signiertem Archiv und Fehlerkorrekturen. [Upstream-COPYING im vom Projekt verlinkten Maintainer-Mirror](https://github.com/tsdgeos/poppler_mirror/blob/master/COPYING) enthält GPL; der installierte GLib-Header nennt GPL-2.0-or-later. Exakte Gesamtpaket-Lizenzkombination vor Linken/Bündeln prüfen, keine pauschale Freigabe für PMTs Binary ableiten.
- [Tesseract](https://tesseract-ocr.github.io/tessdoc/Installation) und [tessdata](https://github.com/tesseract-ocr/tessdata/blob/main/LICENSE) stehen unter Apache 2.0. Engine und Sprachdaten sind getrennte Pakete; bei Redistribution Lizenz/Notices erhalten. Updates/Modelldaten gezielt versionieren, nicht zur Laufzeit versteckt herunterladen.
- [Pillow](https://pillow.readthedocs.io/en/stable/about.html) nennt MIT-CMU. Pillow war der Decoder-Prüfharness, keine festgelegte neue Produktlaufzeit. Seine Codecbibliotheken sind zusätzlich zu prüfen.
- [ImageMagick-Lizenz](https://imagemagick.org/license/) erlaubt Redistribution mit Lizenz/Attribution. Delegates benötigen ihre eigenen Bibliotheken/Lizenzen; die hier fehlende HEIF-Laufzeit zeigt, warum Buildlisten nicht genügen.
- [LibreOffice-Lizenzen](https://www.libreoffice.org/licenses/) nennen MPL 2.0 und zahlreiche Drittkomponenten; bei Bündelung gelten deren konkrete LICENSE-Angaben und Quellbereitstellungspflichten. [Sicherheitsmeldungen](https://www.libreoffice.org/security/) verlangen eine laufend gepflegte Version; ein isoliertes Profil ersetzt Sicherheitsupdates nicht.

Sprachdaten-SHA256: eng `daa0c97d651c19fba3b25e81317cd697e9908c8208090c94c3905381c23fc047`; deu `896b3b4956503ab9daa10285db330881b2d74b70d889b79262cc534b9ec699a4`; osd `e19f2ae860792fdf372cf48d8ce70ae5da3c4052962fe22e9de1f680c374bb0e`.

Einzelmessung Linux, bereits geladene Systemcaches: PDF-BBox 0,014 s / 17.476 KiB Spitzen-RSS; Standard-OCR 0,726 s / 116.028 KiB. Mac-Laufzeiten stehen im Summary. Unterschiedliche Hardware, Werkzeugschichten und Cachezustände erlauben keinen Geschwindigkeitsvergleich. Kein Energie-/Langlaufbudget und kein großer Qualitätskorpus abgenommen.

# Strukturierte lokale OCR

Die OCR-Methode ist in CLI, App und Kurzbefehlen ausdrücklich wählbar. Standard
bleibt der bisherige `VNRecognizeTextRequest`-Weg. `structured` verwendet ab
macOS 26 Apples `RecognizeDocumentsRequest` Revision 1 für lokale Bildpixel und
gerasterte PDF-Seiten; auf älteren Systemen folgt eine Diagnose und Standard-OCR.
Die Methodenwahl schaltet OCR nicht ein: `--image-ocr off` beziehungsweise
`--pdf-ocr off` gelten weiterhin. Die PDF-Automatik entscheidet wie bisher,
welche Seiten eine lokale Erkennung benötigen.

```sh
poormans-text --ocr-method structured --report scan.png
poormans-text --ocr-method structured --pdf-ocr always --ocr-language de,en scan.pdf
```

Die App speichert „OCR-Methode“ in ihren Konvertierungsoptionen. Die Aktion
„Dokument in Markdown umwandeln“ bietet denselben Parameter. Der Bericht
enthält die angeforderte Methode unter `options.ocrMethod`; Diagnosen nennen den
tatsächlich verwendeten Weg. Alte Berichte ohne dieses Feld bleiben lesbar.
Nach einem Update kann Kurzbefehle zunächst alte Parameter anzeigen. Die
installierte App einmal starten und Kurzbefehle neu öffnen; eine neu eingefügte
Aktion verwendet als Vorgabe weiterhin Standard-OCR.

## Ausgabe und Zusammenführung

`StructuredOCRRendering` vergleicht die Wortbestände von Volltext, Absätzen und
ersetzenden Listen-/Tabellenbereichen einschließlich ihrer Häufigkeiten. Fehlt
Text, überlappen alternative Strukturen/Dokumentregionen oder sind Positionen ungültig, wird die
gesamte Bild-/Seitenerkennung auf Standard-OCR zurückgeführt. Volltext und
Struktursichten werden niemals aneinandergehängt. Absatzreihenfolge stammt von
Vision, Quelltext wird als Markdown maskiert. Aufzählungen und einfache
Dezimalnummern werden Listen; andere Originalmarker bleiben wörtlicher Text.

Markdown-Tabellen haben einen neutralen leeren Kopf: Vision belegt keine
Kopfzeilenbedeutung. Alle Datenzeilen bleiben erhalten. Verbundene Zellen stehen
einmal links oben, die überdeckten Positionen bleiben leer; diese Abflachung
wird diagnostiziert. Gleiche Werte an verschiedenen Positionen bleiben getrennt.
Es gelten höchstens 4.096 Rasterpositionen und 256 Spalten je ausgegebener Tabelle.
Verschachtelte Tabellen/Listen werden nicht rekursiv modelliert.

Bei PDF-Seiten vergleicht `PDFStructuredOCRMerge` normalisierte OCR-Rechtecke mit
den digitalen Textpositionen. Textgleiche überlappende Blöcke erscheinen einmal;
zusätzlicher digitaler Text bleibt erhalten. Bei widersprechendem Text fällt die
Seite auf den vorhandenen Zeilenleser zurück: räumliche Dubletten werden entfernt,
überlappender widersprechender OCR-Text wird diagnostiziert weggelassen und der
digitale Originaltext bleibt maßgeblich. Fehlt sichere digitale Einzelgeometrie,
wird zusätzlicher OCR-Text nur bei vollständig übereinstimmendem Wortbestand
verworfen. Andernfalls bricht die Konvertierung verständlich ab, bevor ein
Ergebnis mit unbekanntem Textverlust veröffentlicht würde. Dasselbe gilt für
mehrdeutige Teilüberlappungen und überschrittene räumliche Vergleichsbudgets. Jede
Vergleichsphase ist auf eine Million Positionspaare begrenzt und prüft Abbruch. Wortgrenzen bleiben im Textvergleich erhalten: „a part“
und „apart“ sind ein Konflikt. Quellenvergleich und Bildassets bleiben bytegenau.

Strukturierte OCR-Seiten behalten ihre erkannte Aufteilung. Die Optionen für
wiederholte Ränder und Worttrennungen verändern sie nicht; eine Diagnose nennt
diese Grenze. `--pdf-layout legacy` bleibt auf Seiten ohne OCR wirksam; OCR-Seiten
verwenden die räumliche Zusammenführung zum Schutz des digitalen Originals.

Diagnosen: `ocr.structuredApplied` (Information), `ocr.structuredFallback`,
`ocr.tableSpansFlattened`, `pdf.ocrOriginalRetained` und
`pdf.structuredLayoutRetained`. Ein Rückfall kürzt kein erkanntes erfolgreiches
Ergebnis; Ressourcenüberschreitungen werden diagnostiziert oder brechen vor
Veröffentlichung ab. Bei Ausfall auch der Standard-OCR bleiben das Originalbild
beziehungsweise vorhandener digitaler PDF-Text und die Fehlerdiagnosen erhalten.

## Ergebnis und Grenzen

`StructuredDocumentRecognition` enthält pro erkanntem Dokument Volltext,
Absätze, Listen mit Originalmarkern und Tabellen mit Zelltexten. Textregionen
tragen normalisierte Rechtecke mit Ursprung links unten im orientierten Bild.
Zeilen-/Spaltenspannen sind nullbasiert und inklusiv; verbundene Zellen werden
anhand ihrer API-Adresse einmal übernommen. Leere Zellen bleiben erhalten.
Gleiche Texte an verschiedenen Stellen werden nicht zusammengeführt.

Verschachtelte Strukturen bleiben als Text im jeweiligen Listenelement oder in
der Tabellenzelle erhalten; ihre innere Struktur wird noch nicht rekursiv
modelliert. Lesereihenfolge und Absatzgrenzen stammen von Vision und sind keine
Zusicherung für beliebige Vorlagen. Das Modell leitet keine Zeichenkonfidenz
aus der Dokumentkonfidenz ab.

Eine Anfrage akzeptiert höchstens 16 Millionen Pixel und 8.192 Pixel je Kante.
Es gelten höchstens 16 erkannte Dokumente, insgesamt 16.384 gezählte
Strukturelemente, zwei Millionen UTF-8-Bytes über alle Textsichten, 4.096 eindeutige
Zellen je Tabelle und Zeilen-/Spaltenindizes unter 1.024. Überschreitungen liefern
einen Fehler, keine gekürzten erfolgreichen Ergebnisse. Das Pixelbudget begrenzt
die Eingabe an Vision; es ist keine harte Speichergrenze für Apples Framework.

Der alte und der neue Weg teilen den prozessweiten OCR-Slot. Wartende asynchrone
Anfragen prüfen Task- und Konvertierungsabbruch alle 50 ms. Auch nach Vision und
während der Modellübernahme wird Abbruch geprüft. Ein aktiver Framework-Aufruf
hat keine garantierte harte Abbruchfrist; der Slot bleibt bis zu
seinem tatsächlichen Ende belegt.

Die verfügbaren Sprachen werden am konkreten Request abgefragt. Bis zu acht
explizite Sprachvarianten sind erlaubt; kurze Kürzel werden gegen diese Liste
aufgelöst. Ohne Auswahl arbeitet Vision mit automatischer Spracherkennung.
Unbekannte Sprachen, ältere Systeme, API-Fehler und ungültige Zellspannen liefern
unterscheidbare interne Fehler. `DocumentOCR` erzeugt daraus eine verständliche
Diagnose und führt genau einen Standard-OCR-Rückfall aus. Die synchrone
Konvertierung überbrückt die asynchrone API mit einem einzelnen eigenen
Thread-Executor; TaskLocal-Kontext und Abbruchtoken bleiben gebunden. Der Thread
wartet ohne Wachhaltung, solange keine Arbeit ansteht. Die Konvertierung wartet
auch bei Abbruch auf das tatsächliche Framework-Ende, bevor temporäre Daten und
OCR-Slot freigegeben werden.

## Vergleich und Einsatzentscheidung

Die reproduzierbare Matrix erzeugt zehn echte lokale Dokumentdateien mit elf
Bild-/Seitenvergleichen: Tabellen mit und ohne Gitter, leere/verbundene Zellen,
Aufzählung, nummerierte Liste mit Absätzen, ein fotoähnliches JPEG mit Schräglage
und Helligkeitsverlauf, zwei Spalten, ein gemischtes zweitseitiges PDF, deutsche
Umlaute und orientierte Pixel. Die Inhalte sind synthetisch; ein natürliches
Kamerafoto oder ein umfassender Scanbestand ist damit nicht geprüft.

Im Vergleich auf arm64/macOS 26.7.1 blieben bei beiden Wegen alle 63 vorgegebenen
Textteile genau einmal erhalten. Strukturierte Erkennung traf alle 35 erwarteten
Tabellenzellen einschließlich zweier Leerzellen und einer horizontalen Spanne.
Beide Listen mit je drei Elementen behielten ihre Marker. Die spaltenweise
Sollreihenfolge wurde in elf von elf Vergleichen getroffen; der alte Weg las den
Zweispaltenfall zeilenweise und traf zehn von elf. Ein weiterer strikter Test
prüft eine vertikal verbundene Zelle ohne doppelte Übernahme.

Getrennte Prozesse benötigten für die elf Erkennungen zusammen 1,207 Sekunden
beim alten und 2,275 Sekunden beim strukturierten Weg. Der jeweilige größte
prozessweite RSS-Messwert bis zum Ende der Erkennungen betrug 301,5 bzw. 187,1 MiB.
Das sind Einzelmessungen einschließlich XCTest und Fixture-Erzeugung, keine
isolierten Vision-/GPU-Speichermessungen oder allgemeinen Leistungszusagen.
Parameter: strukturierte Revision 1 bzw. bisherige Erkennungsstufe `.accurate`,
Sprachkorrektur, Mindesttexthöhe 0,008,
explizit Englisch bzw. Deutsch, identische Pixel und Orientierung je Vergleich.
Die API meldete 30 Sprachvarianten; realer Text wurde nur auf Deutsch, Englisch
und mit automatischer Auswahl geprüft.

Der belegt nützliche Teilumfang sind diese einfachen Tabellen, Listen, Absätze
und die geprüfte Mehrspaltigkeit. Die Produktintegration bietet ihn ausdrücklich
wählbar an. Ein Standardwechsel ist durch diese kleine Matrix nicht
begründet. Für ältere Systeme, API-/Sprach-/Budgetfehler und unbrauchbare Struktur
bleibt der bisherige OCR-Weg erforderlich. Originalbilder sowie digitaler
PDF-Text bleiben maßgeblich. Natürliches Fotomaterial, weitere Sprachen und
komplexe verschachtelte Vorlagen brauchen einen breiteren Qualitätsvergleich.

Die vollständige Produktintegration wurde anschließend mit denselben zehn
Dokumentdateien je Methode geprüft: 20 Importe mit jeweils elf Seiten/Frames.
Beide Methoden erhielten alle 63 erwarteten Textteile genau einmal und die
unveränderten Bildassets. Strukturierte OCR erhielt 35/35 Tabellenzellen; die
Sollreihenfolge über den vollständigen Import stimmte bei 10/10 Dokumenten,
bei Standard-OCR bei 8/10. Diese Zählung unterscheidet sich vom elfteiligen
reinen Erkennungsvergleich oben. Komplette Importe benötigten in einem Lauf
1,075 bzw. 1,651 Sekunden. Der gemeinsame Prozess-Spitzenwert der Gesamtsuite
von 1,65 GiB erlaubt keinen Speichervergleich zwischen den Methoden.

Reale PDF-Fixtures prüfen zusätzlich widersprechenden digitalen Text und
mehrdeutige Teilüberlappungen: Das digitale Original bleibt erhalten, räumlich
getrennter Scantext wird übernommen; unsicherer Zusatztext führt zum atomaren
Fehler ohne fertiges Ergebnis oder temporäre Reste. Vier parallele Konvertierungen,
24 synchron wartende Swift-Aufgaben, Abbruch und Rückfallfehler sind geprüft.
Die Methodenwahl und gerenderte Ausgabe wurden in der App auf Deutsch und
Englisch sowie die lokale Dateikonvertierung in der nativen Kurzbefehle-App
mit der notarisierten Universal-App geprüft. Reale Laufzeittests auf älterem
macOS und Intel-Hardware stehen weiter aus.

## Reproduktion

Vom Repo-Root mit Xcode und macOS 26 oder neuer:

```sh
swift test --filter 'VisionDocumentRecognizerTests|StructuredOCRTests'

import_dir=$(mktemp -d /tmp/poormans-structured-import.XXXXXX)
PMT_STRUCTURED_IMPORT_DIR="$import_dir" \
  swift test --skip-build --filter VisionDocumentRecognizerTests/testStructuredProductImportMatrixPreservesContentsCellsAndBytes

comparison_dir=$(mktemp -d /tmp/poormans-vision.XXXXXX)
PMT_VISION_COMPARISON_DIR="$comparison_dir" PMT_VISION_ENGINE=legacy \
  swift test --skip-build --filter VisionDocumentRecognizerTests/testComparisonMatrix
PMT_VISION_COMPARISON_DIR="$comparison_dir" PMT_VISION_ENGINE=structured \
  swift test --skip-build --filter VisionDocumentRecognizerTests/testComparisonMatrix
```

Beide Messläufe verwenden denselben frischen Ordner. Die JSON-Dateien enthalten
Quellhashes, unabhängige Text-/Zellerwartungen, Dublettenzählungen, Sollreihenfolge,
Parameter, vollständige neutrale Erkennung, monotone Laufzeiten und prozessweiten
Spitzen-RSS. Qualitätsabweichungen werden in der Matrix aufgezeichnet; deren
Test-Erfolg allein bedeutet keine inhaltliche Abnahme. Die separaten strikten
Tests prüfen Tabellen-/Listeninhalte, Leer-/Verbundzellen, Quellen- und Assetbytes,
Codable-Roundtrip, Budgets, Sprachen, Abbruch und den gemeinsamen OCR-Slot.
Ein echter Vision-Fehler wird mit ungültigen Bilddaten ausgelöst. Der normale
PDF-Import des gemischten Dokuments wird zusätzlich auf alle 15 erwarteten
Textteile und unveränderte Quelle geprüft.

Der Unverfügbarkeitszweig wird mit Systemversionen 13, 15 und 25 geprüft. Das
ersetzt keinen Lauf auf einem älteren System. Die Deployment-Grenze des Pakets
bleibt macOS 13; die neuen Vision-Typen sind verfügbarkeitsgeprüft gekapselt.

Primärquellen: [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest),
[DocumentObservation](https://developer.apple.com/documentation/vision/documentobservation)
und [Recognizing tables within a document](https://developer.apple.com/documentation/vision/recognize-tables-within-a-document).

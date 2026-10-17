# Strukturierte lokale OCR: interner Prototyp

`VisionDocumentRecognizer` kapselt Apples `RecognizeDocumentsRequest` Revision 1
ab macOS 26. Er ist intern im Core aufrufbar und liest ausschließlich übergebene
lokale Pixel. PDF-/Bildkonvertierung, App, CLI und Kurzbefehle verwenden weiterhin
den bestehenden `VNRecognizeTextRequest`-Weg. Die Produktintegration steht aus.

## Ergebnis und Grenzen

`StructuredDocumentRecognition` enthält pro erkanntem Dokument Volltext,
Absätze, Listen mit Originalmarkern und Tabellen mit Zelltexten. Textregionen
tragen normalisierte Rechtecke mit Ursprung links unten im orientierten Bild.
Zeilen-/Spaltenspannen sind nullbasiert und inklusiv; verbundene Zellen werden
anhand ihrer API-Adresse einmal übernommen. Leere Zellen bleiben erhalten.
Gleiche Texte an verschiedenen Stellen werden nicht zusammengeführt.

Volltext, Absätze, Listen und Tabellen sind alternative Sichten auf denselben
Inhalt. Sie dürfen nicht aneinandergehängt werden. Der Prototyp erzeugt noch
kein Markdown und vereinigt keine erkannten Texte mit digitalem PDF-Text.
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
hat im Prototyp keine garantierte harte Abbruchfrist; der Slot bleibt bis zu
seinem tatsächlichen Ende belegt.

Die verfügbaren Sprachen werden am konkreten Request abgefragt. Bis zu acht
explizite Sprachvarianten sind erlaubt; kurze Kürzel werden gegen diese Liste
aufgelöst. Ohne Auswahl arbeitet Vision mit automatischer Spracherkennung.
Unbekannte Sprachen, ältere Systeme, API-Fehler und ungültige Zellspannen liefern
unterscheidbare interne Fehler. Ein aufrufender Produktadapter muss daraus eine
verständliche Diagnose und den bisherigen OCR-Rückfallweg machen.

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
und die geprüfte Mehrspaltigkeit. Die nächste Integration soll ihn ausdrücklich
wählbar anbieten. Ein Standardwechsel ist durch diese kleine Matrix nicht
begründet. Für ältere Systeme, API-/Sprach-/Budgetfehler und unbrauchbare Struktur
bleibt der bisherige OCR-Weg erforderlich. Originalbilder sowie digitaler
PDF-Text bleiben maßgeblich; Zusammenführung, Diagnosen, Fortschritt und
Markdown-Sicherheit sind Aufgaben der Produktintegration.

## Reproduktion

Vom Repo-Root mit Xcode und macOS 26 oder neuer:

```sh
swift test --filter VisionDocumentRecognizerTests

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

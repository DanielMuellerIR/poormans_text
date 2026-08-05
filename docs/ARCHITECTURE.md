# Architektur

Poor Man's Text hält Konvertierungslogik und Bedienoberflächen getrennt, damit
derselbe Kern von CLI, eigener App und später Fastra benutzt werden kann.

## Heutige Modulgrenzen

- `PoorMansTextCore`: formatneutrale Anfrage, adaptereigene Formaterkennung, Adapterwahl,
  temporäre Arbeitsbereiche, atomare Veröffentlichung, Assets, Warnungen und
  Ergebnisobjekte.
- `PoorMansTextAppSupport`: App-Zustand, Dateiauswahl und Drop-Übergabe.
- `PoorMansTextCLI`: Argumente, Exit-Codes und JSON-/Textausgabe.
- `PoorMansTextApp`: ausschließlich SwiftUI-Darstellung.

Der Kern ist GUI-frei, aber das aktuelle Target bleibt macOS-spezifisch: Der
Rich-Text-Adapter benutzt für die RTFD-Farbübernahme AppKit. RTF läuft wegen
standardkonform eingebetteter Bilder direkt über Pandoc; ein Cocoa-Roundtrip
würde diese Bilder verwerfen. DOC benutzt den macOS-Systemimport über `textutil`.
DOCX einschließlich DOCM/DOTX/DOTM und ODT teilen einen Pandoc-Paketadapter.
ODS, XLSX und XLS werden nativ in ein gemeinsames Arbeitsmappenmodell gelesen;
ODM löst ausschließlich lokale ODT-Teildokumente auf. Alle Wege liegen hinter
derselben Foundation-basierten Anfrage und bestimmen deren API nicht.

## Formatneutrale Konvertierung

Die aktuelle Grenze sieht so aus:

```text
App / CLI / Fastra
        │  Anfrage, Bestätigung, Fortschritt
        ▼
DocumentConverter ─ Inspections priorisieren, Adapter wählen, atomar veröffentlichen
        │
        ├── RichTextAdapter      RTFD über AppKit, RTF über Pandoc
        ├── WordProcessing…      DOCX/DOCM/DOTX/DOTM, ODT und isolierte Medien
        ├── LegacyWordAdapter    DOC über textutil, danach HTML/Pandoc
        ├── SpreadsheetAdapter   ODS, XLSX und XLS über native Leser
        ├── OpenDocumentMaster…  ODM plus geprüfte lokale ODT-Teildokumente
        ├── ImageOCRAdapter      ImageIO + Vision (geplant)
        └── PDFAdapter           PDFKit + optional Vision (geplant)
```

`InputFormat`, `InputInspection`, `ConversionRequest`, `ConversionOptions`,
`ConversionProgress`, `ConversionWarning` und `ConversionResult` benötigen nur
Foundation. `DocumentConverter.inspect` beschreibt Format und bekannte Verluste;
`convert` erkennt die Quelle erneut, damit eine frühere Bestätigung keine später
veränderte Datei durchwinkt. AppKit, Vision, PDFKit und externe Prozesse bleiben
hinter Adaptern.

Jeder Adapter liefert seine eigenen inhaltsbasierten Inspections samt Priorität,
Format und erwarteten Warnungen. `DocumentConverter` löst eindeutige Treffer oder
meldet Mehrdeutigkeit; unbekannte Formate erhalten einen allgemeinen Fehler statt
einer Rich-Text-Diagnose. `InputFormat` ist dafür ein offener, Codable-kompatibler
String-Wert. Ein neuer Adapter benötigt somit keine zusätzliche Erkennungslogik im
Orchestrator.

Ein Adapter deklariert seine Formate ausschließlich über
`supportedFormatDescriptors`: Format, Dateiendungen, `containerKind` und die
benötigten `ExternalTool`-Werte. `supportedFormats` leitet sich daraus ab, und
`DocumentConverter.formatCatalog` ergänzt die Verfügbarkeit auf dem aktuellen
Rechner. Der Katalog kostet nur Dateisystemprüfungen und startet keinen Prozess —
ein Host darf ihn beim Öffnen jeder Datei abfragen. Ein Werkzeug ohne bekannten
Prüfweg gilt bewusst als nicht verfügbar; lieber ein Format zu wenig anbieten als
eine Umwandlung, die verlässlich scheitert.

Adapter erzeugen ausschließlich ein vollständiges Ergebnis im Staging-Bereich.
Nur `DocumentConverter` bestimmt das dauerhafte oder temporäre Ziel und verschiebt
das Ergebnis nach einer zweiten Kollisionsprüfung atomar dorthin. Die
Adapterregistrierung bleibt intern. Ein späterer Split in ein formatneutrales
Library-Target und ein macOS-Import-Target kann sie gezielt als öffentliche oder
SPI-Grenze stabilisieren.

DOCX, DOCM, DOTX/DOTM und ODT werden vor Pandoc anhand ihres ZIP-Inhalts erkannt.
Der OOXML-Hauptinhaltstyp und die Wurzel von `word/document.xml` unterscheiden
Dokumente, makrofähige Dokumente und Vorlagen; Makros und Vorlagenverhalten
werden als erwarteter Verlust gemeldet. Das zentrale Paket-Gate lehnt Traversal,
Symlinks, verschlüsselte Einträge, unbekannte Kompressionsarten, doppelte Namen
und überschrittene Größenbudgets ab. Pandoc
läuft danach mit `--sandbox` und extrahiert Medien ausschließlich in den
Arbeitsordner. Externe Bildbeziehungen werden nie geladen.

Der Tabellenimport liest ODS, XLSX und binäres XLS in ein eigenes
Arbeitsmappenmodell und rendert erst danach Markdown. Die drei Leser verwenden
dieselbe Blatt-, Zell-, Budget- und Diagnosegrenze; XLSX- und ODS-ZIP-Pakete
durchlaufen zusätzlich das zentrale Paket-Gate. Darstellung und Mehrblatt-Regel
stehen in [SPREADSHEET-IMPORT.md](SPREADSHEET-IMPORT.md).

ODM wird als OpenDocument-Masterpaket erkannt. Nur relative, vorhandene
ODT-Verweise im Verzeichnisbaum des Masters sind zulässig; entfernte Ziele,
Pfadfluchten, fehlende Dateien und ausbrechende symbolische Links werden
abgelehnt. Jeder Teil läuft anschließend durch denselben geprüften ODT-Adapter,
und seine Bilder erhalten abschnittsweise eindeutige Namen.

## Vertrag für aufrufende Apps

Der Kern:

- veröffentlicht seinen vollständigen Formatkatalog samt Dateiendungen,
  Ablageform (Datei oder Ordner-Paket) und nötigen externen Werkzeugen;
- erkennt unterstützte Formate und beschreibt erwartbare Verluste;
- konvertiert nur nach einem expliziten Aufruf;
- verändert die Quelle nie;
- schreibt atomar in ein vom Host bestimmtes Ziel;
- liefert strukturierte Warnungen, Assets und die Markdown-URL;
- zeigt keine Fenster und fragt nichts selbst ab.

Die Poor-Man's-Text-App und die CLI erzeugen beide eine `ConversionRequest` und
enthalten keine eigene Formaterkennung. `RichTextConverter` und der frühere Name
`RTFDConverter` bleiben als dünne quellkompatible Fassaden erhalten.

Der Host entscheidet, ob und wann gefragt wird. Fastra kann dadurch beim Öffnen
eines Fremdformats eine eigene Bestätigung zeigen, zunächst in ein temporäres
Verzeichnis konvertieren und erst danach die Markdown-Datei öffnen. Die
Poor-Man's-Text-App kann denselben Kern weiterhin direkt in einen Nachbarordner
schreiben.

Ein Host kann Prüfung und temporären Import dabei getrennt ausführen:

```swift
let converter = DocumentConverter()
let inspection = try converter.inspect(sourceURL)
// Der Host fragt anhand von inspection.format und expectedWarnings selbst nach.
let result = try converter.convert(
    ConversionRequest(inputURL: sourceURL, destination: .temporary)
)
defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
openMarkdown(result.markdownFile)
```

## Testgrenzen

- Adaptertests verwenden echte temporär erzeugte RTF- und RTFD-Dokumente sowie
  versionierte DOCX-, ODT-, DOC-, ODS- und XLS-Dateien aus unabhängigen
  Erzeugern. Bilddaten werden per Bytevergleich geprüft; DOCX/ODT und XLSX
  zusätzlich gegen Pandoc direkt.
- Pakettests prüfen Traversal, externe Bilder, Kommentare, angenommene Änderungen
  und die inhaltsbasierte Unterscheidung eines echten XLS vom alten DOC. Eigene
  Tabellen- und ODM-Tests prüfen Blattreihenfolge, Zellbudgets,
  Merge-/Formelwarnungen, lokale ODT-Verweise, Pfadfluchten und eindeutige Assets.
- Engine-Tests prüfen Adapter-Inspections, Priorität und Mehrdeutigkeit sowie
  Kollisionsschutz und atomare Veröffentlichung einschließlich einer erst während
  der Konvertierung entstehenden Zielkollision unabhängig von SwiftUI.
- CLI-Tests prüfen Exit-Codes und JSON; App-Tests prüfen nur Übergabe und Zustand.
- Weitere manuelle Editorproben bleiben außerhalb des öffentlichen Repos und
  dienen als zusätzlicher Output-Diff, nicht als still aktualisierbares Golden
  Master.

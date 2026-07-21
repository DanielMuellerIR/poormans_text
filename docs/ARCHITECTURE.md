# Architektur

Poor Man's Text hält Konvertierungslogik und Bedienoberflächen getrennt, damit
derselbe Kern von CLI, eigener App und später Fastra benutzt werden kann.

## Heutige Modulgrenzen

- `PoorMansTextCore`: formatneutrale Anfrage, Formaterkennung, Adapterwahl,
  temporäre Arbeitsbereiche, atomare Veröffentlichung, Assets, Warnungen und
  Ergebnisobjekte.
- `PoorMansTextAppSupport`: App-Zustand, Dateiauswahl und Drop-Übergabe.
- `PoorMansTextCLI`: Argumente, Exit-Codes und JSON-/Textausgabe.
- `PoorMansTextApp`: ausschließlich SwiftUI-Darstellung.

Der Kern ist GUI-frei, aber das aktuelle Target bleibt macOS-spezifisch: Der
Rich-Text-Adapter benutzt für die RTFD-Farbübernahme AppKit. RTF läuft wegen
standardkonform eingebetteter Bilder direkt über Pandoc; ein Cocoa-Roundtrip
würde diese Bilder verwerfen. Beide Wege liegen hinter derselben
Foundation-basierten Anfrage und bestimmen deren API nicht.

## Formatneutrale Konvertierung

Die aktuelle Grenze sieht so aus:

```text
App / CLI / Fastra
        │  Anfrage, Bestätigung, Fortschritt
        ▼
DocumentConverter ─ Format erkennen, Adapter wählen, atomar veröffentlichen
        │
        ├── RichTextAdapter      RTFD über AppKit, RTF über Pandoc (vorhanden)
        ├── PandocAdapter        DOCX, ODT und extrahierte Medien (geplant)
        ├── ImageOCRAdapter      ImageIO + Vision (geplant)
        └── PDFAdapter           PDFKit + optional Vision (geplant)
```

`InputFormat`, `InputInspection`, `ConversionRequest`, `ConversionOptions`,
`ConversionProgress`, `ConversionWarning` und `ConversionResult` benötigen nur
Foundation. `DocumentConverter.inspect` beschreibt Format und bekannte Verluste;
`convert` erkennt die Quelle erneut, damit eine frühere Bestätigung keine später
veränderte Datei durchwinkt. AppKit, Vision, PDFKit und externe Prozesse bleiben
hinter Adaptern.

Adapter erzeugen ausschließlich ein vollständiges Ergebnis im Staging-Bereich.
Nur `DocumentConverter` bestimmt das dauerhafte oder temporäre Ziel und verschiebt
das Ergebnis nach einer zweiten Kollisionsprüfung atomar dorthin. Die
Adapterregistrierung bleibt bis zum zweiten Adapter intern; dann kann sie beim
geplanten Split in ein formatneutrales Library-Target und ein macOS-Import-Target
gezielt als öffentliche oder SPI-Grenze stabilisiert werden.

## Vertrag für aufrufende Apps

Der Kern:

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

- Adaptertests verwenden echte temporär erzeugte RTF- und RTFD-Dokumente und
  vergleichen eingebettete Bilddaten unabhängig.
- Engine-Tests prüfen Formaterkennung, Auswahl, Kollisionsschutz und atomare
  Veröffentlichung einschließlich einer erst während der Konvertierung
  entstehenden Zielkollision unabhängig von SwiftUI.
- CLI-Tests prüfen Exit-Codes und JSON; App-Tests prüfen nur Übergabe und Zustand.
- Reale Dokumente bleiben außerhalb des öffentlichen Repos und dienen als
  zusätzlicher Output-Diff, nicht als still aktualisierbares Golden Master.

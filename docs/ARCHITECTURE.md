# Architektur

Poor Man's Text hält Konvertierungslogik und Bedienoberflächen getrennt, damit
derselbe Kern von CLI, eigener App und später Fastra benutzt werden kann.

## Heutige Modulgrenzen

- `PoorMansTextCore`: RTF-/RTFD-Konvertierung, temporäre Arbeitsbereiche, Assets,
  Pandoc-/`textutil`-Aufrufe, Normalisierung, Warnungen und Ergebnisobjekte.
- `PoorMansTextAppSupport`: App-Zustand, Dateiauswahl und Drop-Übergabe.
- `PoorMansTextCLI`: Argumente, Exit-Codes und JSON-/Textausgabe.
- `PoorMansTextApp`: ausschließlich SwiftUI-Darstellung.

Der Kern ist GUI-frei, aber macOS-spezifisch: Die RTFD-Farbübernahme benutzt
AppKit. RTF läuft wegen standardkonform eingebetteter Bilder direkt über Pandoc;
ein Cocoa-Roundtrip würde diese Bilder verwerfen. Das ist für Fastra kompatibel,
soll bei weiteren Formaten jedoch nicht die formatneutrale API bestimmen.

## Ziel mit mehreren Importformaten

Vor dem nächsten Importformat werden folgende Verantwortungen eingeführt:

```text
App / CLI / Fastra
        │  Anfrage, Bestätigung, Fortschritt
        ▼
ConversionEngine ── Format erkennen, Adapter wählen, atomar veröffentlichen
        │
        ├── RichTextAdapter      RTFD über AppKit, RTF über Pandoc
        ├── PandocAdapter        DOCX, ODT und extrahierte Medien
        ├── ImageOCRAdapter      ImageIO + Vision
        └── PDFAdapter           PDFKit + optional Vision
```

Die Typen für Anfrage, Format, Warnung und Ergebnis sollen nur Foundation
benötigen. AppKit, Vision, PDFKit und externe Prozesse bleiben hinter Adaptern.
Ein späterer Split in ein formatneutrales Library-Target und ein macOS-Import-
Target ist vorgesehen, sobald der zweite Adapter implementiert wird; ein
vorsorglicher Umbau vor dem nächsten Containerformat würde heute nur API-Ballast
erzeugen.

## Vertrag für aufrufende Apps

Der Kern:

- erkennt unterstützte Formate und beschreibt erwartbare Verluste;
- konvertiert nur nach einem expliziten Aufruf;
- verändert die Quelle nie;
- schreibt atomar in ein vom Host bestimmtes Ziel;
- liefert strukturierte Warnungen, Assets und die Markdown-URL;
- zeigt keine Fenster und fragt nichts selbst ab.

Der Host entscheidet, ob und wann gefragt wird. Fastra kann dadurch beim Öffnen
eines Fremdformats eine eigene Bestätigung zeigen, zunächst in ein temporäres
Verzeichnis konvertieren und erst danach die Markdown-Datei öffnen. Die
Poor-Man's-Text-App kann denselben Kern weiterhin direkt in einen Nachbarordner
schreiben.

## Testgrenzen

- Adaptertests verwenden echte temporär erzeugte RTF- und RTFD-Dokumente und
  vergleichen eingebettete Bilddaten unabhängig.
- Engine-Tests prüfen Formaterkennung, Auswahl, Kollisionsschutz und atomare
  Veröffentlichung unabhängig von SwiftUI.
- CLI-Tests prüfen Exit-Codes und JSON; App-Tests prüfen nur Übergabe und Zustand.
- Reale Dokumente bleiben außerhalb des öffentlichen Repos und dienen als
  zusätzlicher Output-Diff, nicht als still aktualisierbares Golden Master.

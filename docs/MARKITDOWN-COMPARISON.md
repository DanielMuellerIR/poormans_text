# Vergleichsanalyse: Poor Man's Text vs. Microsoft MarkItDown

Diese Analyse stellt das Architekturdesign, die Funktionsweise, die Stärken und Schwächen von **[Microsoft MarkItDown](https://github.com/microsoft/markitdown)** und **Poor Man's Text** detailliert gegenüber und leitet daraus konkrete Vorschläge für die Weiterentwicklung ab.

---

## 1. Executive Summary & Philosophischer Vergleich

Obwohl beide Projekte Dokumente in Markdown transformieren, verfolgen sie **grundlegend unterschiedliche Kernphilosophien und Zielgruppen**:

```text
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                   POOR MAN'S TEXT                                       │
│  Fokus: Menschliche Autoren, Desktop-Editoren (Fastra/Obsidian), deterministische      │
│  Asset-Erhaltung, native macOS-Performance, kompromisslose Sicherheit & Staging         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                           VS
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                MICROSOFT MARKITDOWN                                     │
│  Fokus: LLM-/RAG-Datenaufbereitung (AutoGen-Ökosystem), Stream-Extraktion für AI-       │
│  Pipelines, breite Formatabdeckung (Cloud/Office/Audio/Web), multimodale KI-Integration │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

| Dimension | Poor Man's Text | Microsoft MarkItDown |
| :--- | :--- | :--- |
| **Primäres Ziel** | Verlustbehaftete, aber struktur- und bildtreue Dokumentenkonvertierung für lokale Editoren und Workflows. | Text- und Informationsextraktion zur Weiterverarbeitung durch LLMs / AI-Agents. |
| **Tech-Stack** | Swift 6, native macOS-Frameworks (AppKit, Foundation, später PDFKit/Vision), Pandoc-Sandbox, CLI + SwiftUI-App. | Python 3.10+, Standard-Open-Source-Parser (`mammoth`, `pdfminer`, `openpyxl`, `python-pptx`), LLM-Clients. |
| **Asset-Handling** | **First-Class Citizen:** Bilder werden verlustfrei extrahiert, sequentiell benannt (`images/image01.png`), im Markdown relativ verlinkt; Ausgabeverzeichnis als Bundle. | **Sekundär:** Bilder werden im Textfluss ignoriert oder durch Textbeschreibungen (LLM-Vision-Captions) / OCR-Text ersetzt; primär monolithischer Text-Output. |
| **Sicherheit & Isolation** | **Extrem strikt:** Sandboxing für Fremdprozesse, striktes ZIP-Gate (Traversal, Bomb-, Symlink-Schutz), SIGBUS-Prävention, atomare Staging-Pipeline, Zero-Remote-Garantie. | **Pragmatisch:** Läuft mit Standard-Prozessrechten; führt Web-Requests aus; DoS-/Zip-Bomb-Limits wurden erst nachträglich als Patches ergänzt. |
| **Bereitstellung** | Notarisierte macOS-App mit Drag&Drop, Sparkle Auto-Update (Ed25519-signiert) und universelle CLI. | `pip`-Paket (`pip install markitdown[all]`) für CLI und Python-Bibliotheksimport. |

---

## 2. Detaillierter Format- und Feature-Vergleich

| Formatbereich | Format | Poor Man's Text | Microsoft MarkItDown | Wer löst es besser? |
| :--- | :--- | :--- | :--- | :--- |
| **Office Text** | **DOCX / DOCM / DOTX** | Pandoc-Container-Adapter + ZIP-Gate + OOXML-Validierung. Echte Bildextraktion, Tracked Changes & Comments Warnungen. | `mammoth` + `lxml`. Pure-Python-Transformation nach HTML, danach `markdownify`. | **Poor Man's Text**: Deutlich robuster bei Bild-Assets, Formatprüfung und Tabellen-Struktur. |
| | **RTF / RTFD** | Native AppKit-Integration für RTFD (inkl. `==text==` Farbmarkierung) + Pandoc für RTF (Image-Safe). | Nicht nativ / rudimentär als Plaintext. | **Poor Man's Text**: Haushoch überlegen (macOS-Spezialist). |
| | **ODT / ODM** | Nativer ZIP-Gate + Pandoc für ODT; native rekursive Auflösung von Master Documents (`.odm`) mit Pfadflucht-Schutz. | ODT nicht primär im Fokus; kein ODM-Support. | **Poor Man's Text**: Klar überlegen. |
| | **Legacy DOC (`.doc`)** | macOS `textutil` Pipeline + Pandoc HTML. | Nicht unterstützt (benötigt externe Konverter). | **Poor Man's Text**: macOS-Vorteil. |
| **Tabellen** | **XLSX / ODS / XLS** | **Eigener nativer Parser in Swift**: Echter BIFF-Binary-Parser für altes `.xls`, XML-Streaming für XLSX/ODS, GFM-Tabellen / TSV-Codeblocks, Formel-/Merge-Warnungen, Zellbudgets. | `openpyxl` / `pandas` / `xlrd`. Mächtiges Tabellen-Dataframe-Parsing, aber schwergewichtiger Python-Stack. | **Poor Man's Text**: Extrem schlank (kein 200MB Python-Stack), blitzschnell, typsicher und sicher gegen Speichererschöpfung. |
| **Präsentationen** | **PowerPoint (.pptx)** | *Nicht unterstützt* (bisher nicht auf Roadmap). | `python-pptx`: Extrahiert Folien chronologisch (`## Slide N: Title`), Textrahmen, Bulletpoints, Tabellen und Notizen. | **MarkItDown**: Bietet fertige Unterstützung für Präsentationsfolien. |
| **Code & Notizen** | **Jupyter Notebooks (.ipynb)** | *Nicht unterstützt*. | Nativer Parser: Rendert Markdown-Zellen und Code-Zellen sauber in Fenced Blocks (```python ...). | **MarkItDown**: Sehr nützlich für Entwickler- und Data-Science-Dokumente. |
| **PDF** | **PDF-Dateien** | *Auf Roadmap (Etappe 6)*: PDFKit + Vision OCR lokal. | `pdfminer.six` + `pdfplumber`: Extrahiert Text und Tabellenlayout rein in Python. | **MarkItDown** hat es heute; **Poor Man's Text** plant die performantere, native macOS-Lösung (PDFKit). |
| **Bilder & OCR** | **Bilder (PNG/JPG/TIFF)** | *Auf Roadmap (Etappe 5)*: ImageIO + Apple Vision OCR (lokal, offline, kostenlos). | EXIF via ExifTool + OCR / Bildbeschreibung via LLM (OpenAI GPT-4o Vision). | **MarkItDown** nutzt multimodale KI; **Poor Man's Text** fokussiert Offline-Datenschutz & System-OCR. |
| **E-Mail & E-Book** | **MSG / EML / EPUB** | *Nicht unterstützt*. | `.msg` via `extract-msg`, EPUB via `ebooklib`. Header/Body-Extraktion. | **MarkItDown**: Breites Spektrum für Archivierungs-Workflows. |
| **Streaming / I/O** | **CLI Pipes & Streams** | Schreibt immer atomar Verzeichnisse (`Document-markdown/`). Keine Stdin/Stdout-Pipes. | Unterstützt `cat doc.pdf \| markitdown`, `markitdown doc.pdf > out.md`, Python `BinaryIO` Streams. | **MarkItDown**: Flexibler für Terminal-Pipes und Skriptverkettung. |

---

## 3. Was macht Microsoft MarkItDown besser? (Stärken von MarkItDown)

### 1. Breiteres Spektrum an Alltags- und Entwicklerformaten
MarkItDown deckt Formate ab, die im Entwickler- und Büroalltag häufig anfallen:
* **PowerPoint (`.pptx`)**: Wandelt Präsentationen in strukturierte Folienkapitel mit Sprechernotizen um.
* **Jupyter Notebooks (`.ipynb`)**: Wandelt Notebooks direkt in sauberen Markdown-Code mit Code- und Textblöcken um.
* **E-Mails (`.msg` / `.eml`)**: Trennt Header (Von, An, Betreff, Datum) strukturiert vom Body ab.
* **E-Books (`.epub`)**: Liest Kapiteltexte aus EPub-Archiven.

### 2. Nahtlose multimodale KI-Integration (`llm_client` / `llm_model`)
Wenn ein Dokument Diagramme, Charts oder Fotos enthält, kann MarkItDown optional einen LLM-Client (z. B. OpenAI GPT-4o) einbinden. Anstatt Bilder nur als Binärdatei abzulegen, generiert das Modell eine treffende textuelle Beschreibung:
```text
![Revenue Trend](images/img1.png)
*Chart Description: A line graph showing Q1-Q4 revenue growth peaking at $4.2M in Q3.*
```

### 3. Stream- und Pipe-Fähigkeit (`stdin` / `stdout`)
MarkItDown kann direkt in Unix-Pipelines verwendet werden:
```bash
cat input.pdf | markitdown | llm "Fasse diese PDF zusammen"
```
Das ist für reine Text-Pipelines, in denen keine lokalen Bild-Assets benötigt werden, ungemein praktisch.

### 4. Plugin-Ökosystem via Entry Points
Über `entry_points(group="markitdown.plugin")` können externe Pakete (wie `markitdown-ocr` oder Community-Parser) dynamisch geladen werden, ohne den Kernquellcode zu verändern.

---

## 4. Was macht Poor Man's Text besser? (Stärken unseres Projekts)

### 1. Überlegenes Asset-Handling für echte Markdown-Editoren
* **Poor Man's Text** erzeugt vollwertige Dokument-Bundles: Die Originalbilder werden verlustfrei extrahiert, sequentiell und deterministisch benannt (`image01.png`), im Ordner `images/` abgelegt und im Markdown exakt an ihrer Textposition relativ verlinkt.
* MarkItDown ignoriert Bilddateien weitgehend oder beschränkt sich auf Textbeschreibungen im Monolithen.

### 2. Kompromisslose Sicherheit, Sandboxing & Staging
* **Pandoc-Sandbox**: Läuft isoliert mit `--sandbox`.
* **Striktes ZIP-Gate**: Verhindert Path Traversal (`../../`), Symlink-Ausbrüche und Zip-Bomben vor dem Entpacken.
* **SIGBUS- und Crash-Schutz**: `ZIPArchiveInspector` spiegelt fremde Archive niemals direkt unsicher in den Adressraum.
* **Atomares Staging**: Konvertierungen laufen in temporären Bereichen und werden erst nach 100%igem Erfolg atomar ans Ziel verschoben. Bereits existierende Ausgabeordner werden niemals überschrieben.
* **Zero-Remote-Garantie**: Keine unbemerkten Netzwerkzugriffe oder Datenabflüsse.

### 3. Schlanker, nativer High-Performance-Core (Zero-Dependency)
* Tabellen (XLSX, ODS und binäres XLS) werden in purem Swift ohne Fremdbibliotheken wie Pandas, NumPy oder OpenPyXL geparst.
* Startzeit in Millisekunden, minimaler Speicherverbrauch, keine Python-Laufzeitumgebung nötig.

### 4. Host-Introspektion & Schnittstelle (`--formats`)
* Über `poormans-text --formats [--json]` kann eine aufrufende Host-App (wie **Fastra**) jederzeit abfragen, welche Formate unterstützt werden und welche externen Tools (z. B. Pandoc) auf dem System verfügbar sind, ohne Prozesse starten oder Dateien konvertieren zu müssen.

### 5. Native macOS-Integration
* RTFD-Unterstützung mit Farberhalt (`==text==`), Drag-and-Drop, signierte Universal-Binaries, Apple Notarization und sicheres In-App-Update via Sparkle (Ed25519).

---

## 5. Konkrete Vorschläge: Was wir von MarkItDown übernehmen könnten

Hier sind 5 konkrete, priorisierte Vorschläge für Poor Man's Text, geordnet nach Mehrwert und Passung zu unserer Architektur:

### Vorschlag 1: Nativer PPTX-Adapter (PowerPoint) — *Hohe Priorität*
* **Warum**: Pandoc kann `.pptx` nicht nativ nach Markdown konvertieren. Präsentationen sind aber ein extrem häufiges Format.
* **Wie in Poor Man's Text**: Da ein `.pptx` ein OOXML-ZIP-Paket ist, passt es perfekt in unser bestehendes `ZIPArchiveInspector`- und XML-Streaming-Konzept:
  1. `ppt/presentation.xml` und `ppt/slides/slideN.xml` in natürlicher Reihenfolge einlesen.
  2. Pro Folie eine Überschrift `## Slide N: [Titel]` erzeugen.
  3. Text-Shapes als Absätze/Listen und Notizen (`ppt/notesSlides/notesSlideN.xml`) als `> **Note:** ...` ausgeben.
  4. Eingebettete Grafiken aus `ppt/media/` über unsere bewährte Asset-Pipeline nach `images/` extrahieren.
* **Aufwand**: Mittel. Kein Pandoc erforderlich, rein nativer Swift-Adapter.

### Vorschlag 2: Nativer IPYNB-Adapter (Jupyter Notebooks) — *Hohe Priorität / Quick Win*
* **Warum**: Entwickler und Data Scientists wollen oft Code-Notizen und Dokumentationen aus Jupyter Notebooks in Fastra/Markdown überführen.
* **Wie in Poor Man's Text**:
  1. `.ipynb` ist ein simples JSON-Format.
  2. Swift `Decodable`-Struct für Notebook-Zellen (`markdown`, `code`, `outputs`).
  3. Markdown-Zellen 1:1 übernehmen; Code-Zellen in Fenced Code Blocks (```` ```python ````) setzen; Textausgaben als Blockquote oder Output-Fences anfügen; Base64-Bilder in `images/` ablegen.
* **Aufwand**: Sehr gering (1–2 Tage). Rein nativer Swift-Parser ohne externe Tools.

### Vorschlag 3: CLI-Stream- / Stdout-Modus (`--stdout` oder `-`) — *Mittlere Priorität*
* **Warum**: Erlaubt die direkte Integration in Terminal-Pipes und Unix-Tools (z. B. Übergabe an lokale LLMs oder Skripte).
* **Wie in Poor Man's Text**:
  * Neue CLI-Option `--stdout` (oder wenn das Ziel `-` ist).
  * Wenn aktiviert: Das erzeugte Markdown wird direkt auf `stdout` ausgegeben (diagnostische Warnungen bleiben auf `stderr`).
  * Falls Bilder enthalten sind: Warnung auf `stderr`, dass Assets im Stdout-Modus nicht materialisiert werden (oder Inline-Data-URIs als Option).

### Vorschlag 4: Dokument-Metadaten & Frontmatter (`--frontmatter`) — *Mittlere Priorität*
* **Warum**: Dokumente enthalten oft wichtige Metadaten (Titel, Autor, Erstellungsdatum, Thema). MarkItDown extrahiert den Titel; für Markdown-Editoren ist YAML-Frontmatter der Standard.
* **Wie in Poor Man's Text**:
  * Auslesen von OOXML `docProps/core.xml`, ODT/ODS `meta.xml` oder RTF-Info.
  * `ConversionResult` um ein optionales `metadata: DocumentMetadata?` erweitern.
  * Optionaler CLI-Schalter `--frontmatter`: Fügt dem generierten Markdown einen sauberen YAML-Header voran:
    ```yaml
    ---
    title: Quartalsbericht 2026
    author: Daniel Müller
    date: 2026-08-20
    ---
    ```

### Vorschlag 5: E-Mail-Adapter (.eml) — *Niedrigere Priorität / Nische*
* **Warum**: Schnelle Konvertierung von gespeicherten E-Mails für Dokumentationszwecke.
* **Wie in Poor Man's Text**:
  * `.eml` ist Standard-MIME (RFC 822/2822).
  * Header (From, To, Date, Subject) in YAML-Frontmatter oder Markdown-Kopfzeilen umwandeln, Body durch den bestehenden HTML-/Plaintext-Rewriter schleifen, Anhänge in `images/` bzw. `attachments/` sichern.

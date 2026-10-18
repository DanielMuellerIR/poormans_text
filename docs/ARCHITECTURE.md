# Architektur

Poor Man's Text hält Konvertierungslogik und Bedienoberflächen getrennt, damit
derselbe Kern von CLI, eigener App und später Fastra benutzt werden kann.

## Heutige Modulgrenzen

- `PoorMansTextCore`: formatneutrale Anfrage, adaptereigene Formaterkennung, Adapterwahl,
  temporäre Arbeitsbereiche, atomare Veröffentlichung, Assets, Warnungen und
  Ergebnisobjekte.
- `PoorMansTextAppSupport`: App-Zustand, Dateiauswahl, Drop-Übergabe, die
  Weitergabe gemeinsam geöffneter Dateien (`OpenedDocumentsRelay`) und die
  Systemdienste (`ServicesProvider`, `RichTextClipboard`). Der Rich-Text-Dienst
  schreibt die Auswahl als temporäre `.rtfd`- oder `.rtf`-Datei und nutzt den
  normalen Adapterweg mit temporärem Ziel; der Kern kennt keine Zwischenablage.
  `ConvertDocumentIntent` ist ein weiterer dünner Adapter: Er übernimmt
  dateibasierte Kurzbefehle-Eingaben, Optionen und Abbruch, ruft den Kern im
  Hintergrund auf und gibt eine Textliste mit der Ergebnisordner-URL an erster
  Stelle und möglichen Warnungen danach zurück. Die
  Kurzbefehle-Aktion speichert keine GUI-Einstellungen.
- `PoorMansTextCLI`: Argumente, Exit-Codes und JSON-/Textausgabe.

Mehrere Eingaben löst `InputEnumerator` im Kern auf: Dateien und Pakete
unverändert, Ordner rekursiv nach den Endungen des Formatkatalogs, ohne
versteckte Einträge, symbolische Links und frühere `*-markdown`-Ergebnisse.
CLI und App rufen dieselbe Funktion, damit ein Ordner an beiden Stellen
dieselben Dokumente in derselben Reihenfolge ergibt. `DocumentConverter` wandelt
ein Dokument je Aufruf um; `BatchConverter` plant gemeinsame Ziele und steuert
die begrenzte Worker-Schleife. CLI und App stellen deren Ergebnisse dar.
- `PoorMansTextApp`: ausschließlich SwiftUI-Darstellung.

Der Kern ist GUI-frei, aber das aktuelle Target bleibt macOS-spezifisch: Der
Rich-Text-Adapter benutzt für die RTFD-Farbübernahme AppKit. RTF läuft wegen
standardkonform eingebetteter Bilder über Pandoc; ein vorgeschalteter, begrenzter
Unicode-Rewriter schützt UTF-16-Surrogatpaare und entfernt deren ANSI-Fallbacks
nur in der temporären Eingabe. Im HTML werden die Zeichen als Zeichenreferenzen
wiederhergestellt. Ungültige Unicode-Folgen brechen die Konvertierung ab. Ein Cocoa-Roundtrip
würde diese Bilder verwerfen. DOC benutzt den macOS-Systemimport über `textutil`.
DOCX einschließlich DOCM/DOTX/DOTM und ODT teilen einen Pandoc-Paketadapter.
ODS, XLSX und XLS werden nativ in ein gemeinsames Arbeitsmappenmodell gelesen;
PPTX/PPTM/POTX und ODP teilen ein Folienmodell; IPYNB nutzt einen eigenen
JSON-Import ohne Codeausführung. ODM löst ausschließlich lokale ODT-Teildokumente auf. Alle Wege liegen hinter
derselben Foundation-basierten Anfrage und bestimmen deren API nicht.
PDFKit liest eingebetteten PDF-Text, und Vision verarbeitet ausschließlich lokal
gerenderte Seiten entsprechend dem gewählten OCR-Modus. ImageIO übernimmt Bilddaten unverändert als Asset;
Vision ergänzt dort optional lokalen Text. `DocumentOCR` wählt anhand von
`ConversionOptions.ocrMethod` zwischen Standard-OCR und ausdrücklich gewählter
strukturierter Erkennung ab macOS 26. `VisionDocumentRecognizer` liefert dafür
ein neutrales Modell getrennter Text-/Struktursichten; `StructuredOCRRendering`
prüft ihre Inhaltsdeckung und erzeugt sicheres Markdown. `PDFStructuredOCRMerge`
vereinigt es räumlich mit maßgeblichem digitalem Originaltext. Unsichere Struktur
und fehlende Verfügbarkeit führen mit Diagnose zur bisherigen Erkennung zurück.
Vertrag und Vergleich stehen unter
[Strukturierte OCR](STRUCTURED-OCR.md).

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
        ├── PresentationAdapter  PPTX/PPTM/POTX und ODP nativ ins Folienmodell
        ├── NotebookAdapter      IPYNB-Zellen, Ausgaben und Bilder ohne Ausführung
        ├── OpenDocumentMaster…  ODM plus geprüfte lokale ODT-Teildokumente
        ├── ImageAdapter         ImageIO-Asset + optionales Vision-OCR
        ├── PDFAdapter           PDFKit-Text + lokaler Vision-OCR-Fallback
        ├── DelimitedTextAdapter CSV/TSV nativ ins Arbeitsmappenmodell
        └── PandocTextAdapter    HTML, Webarchive, EPUB, LaTeX, DocBook, Org,
                                 MediaWiki, Textile, RST, FB2 über Pandoc
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

`DelimitedTextAdapter` ist der einzige Adapter, der die Dateiendung verlangt:
Reiner Text lässt sich am Inhalt nicht als Tabelle erkennen. Danach gelten die
Regeln des Tabellenimports. `PandocTextAdapter` fasst alle Formate zusammen, die
Pandoc liest und die keinen nativen Leser brauchen; HTML wird am Inhalt erkannt,
EPUB über das Paket-Gate und den `mimetype`-Eintrag, die Textauszeichnungen
über Endung plus Signatur. Vor der gemeinsamen HTML-Schlussstrecke bereinigt
`HTMLImageSourceResolver` die Bildverweise: lokale Bilder unterhalb des
Quellordners werden kopiert, `data:`-Bilder ausgepackt, entfernte Bilder zu
Links, fehlende Bilder zu ihrem Alt-Text; Webarchive liefern ihre Bilder als
Nebenressourcen (`WebArchiveReader`). Pandoc läuft mit `--sandbox`, sodass etwa
`\input` in LaTeX keine fremden Dateien liest.

`MailAdapter` erkennt EML und Apple-Mail-EMLX an den Nachrichtenkopfzeilen und
liest die begrenzte Quelle über einen geprüften Deskriptor. `MIMEMessage`
beachtet Apple Mails Bytezählung, Headerfaltung, Transfer- und Zeichencodierung,
Multipart-Grenzen und erweiterte Dateinamen. `MailContent` wählt eine
Körperalternative, ordnet CID-Ressourcen zu und erhält Anhänge unter eigenen
sicheren Namen. `MailBodyConverter` nutzt die gemeinsame sichere
HTML-Schlussstrecke ohne Zugriff auf lokale Nachbardateien. Klartextkörper werden
erst danach als umschlossene Textblöcke eingesetzt; der Abschluss ist länger als
jede Backtick-Folge im Körper. Dadurch bleiben auch Tabs, Einrückungen und
abschließende Leerzeilen wörtlich erhalten. Kopfzeilen werden
vollständig als Tabelle ausgegeben; das vorhandene Metadatenmodell erhält
Betreff, Absender und Datum. GUI und CLI verwenden denselben Adapter.

`MSGAdapter` erkennt Outlook-Mail in OLE-Containern. `MSGProperties` liest
Propertytabellen mit objektabhängigen Headern und prüft Strings, Codepages und
Wertlängen. `MSGMessage` bildet Kopfzeilen, Körper und Anhänge auf dieselbe
Mail-Engine ab. `MSGCompressedRTF` prüft und entpackt LZFu/MELA;
`MSGRTFHTML` liest das darin gekapselte HTML und normalisiert bei nativem RTF
Unicode-Fallbacks auf `uc0`, weil Pandoc sonst ein folgendes Literal verschluckt.
Normales RTF geht über Pandoc in
einem eigenen temporären Ressourcenordner, ohne Quelldateinachbarn einzubeziehen.
`MSGEmbeddedWriter` baut für eingebettete Nachrichten eigenständige OLE-Dateien
mit bytegleichen Wertstreams und der gemeinsamen Named-Property-Zuordnung.
Empfänger, Anhänge, Streams, Verschachtelung und entpackte Daten bleiben begrenzt;
externe Anhangsmethoden werden abgewiesen. Office wird nicht geladen.

Jeder Adapter liefert neben Markdown und Assets ein `DocumentMetadata`, soweit
sein Format Titel, Autor oder Daten kennt (`docProps/core.xml`, `meta.xml`,
RTF-`\info`, PDF-Info-Wörterbuch, EPUB-OPF, FB2-`title-info`, HTML-Kopf; DOC,
XLS, IPYNB und Bilder liefern nichts).
`ConversionPostprocessor` übernimmt die Nachbearbeitung im Staging-Bereich:
`ConversionOptions.frontmatter` stellt den YAML-Kopf voran,
`ConversionOptions.outputLayout == .textbundle` baut das Ergebnis in
`text.md`, `assets/` und `info.json` um und schreibt die Asset-Links über den
Markdown-Rewriter neu. Erst danach wird veröffentlicht.

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

`DOCXReviewPreserver` ergänzt im verifizierten privaten DOCX Textmarker für
Kommentare und sichtbar gewählte Revisionen. Pandoc übernimmt weiterhin die
Textauswahl für Annehmen/Verwerfen; der Adapter behandelt zusätzlich
Tabellenzeilen und verschobenen Text. Kommentare werden vor Pandoc aus den
Beziehungen gelesen, ihre internen Anker entfernt und nach der gemeinsamen
HTML-Schlussstrecke als maskierte Anmerkungen samt Quellzuordnung ausgegeben.
Zufällige Marker werden vollständig aufgelöst; Fußnotennummern bleiben Pandocs
Aufgabe. Nichtstandardmäßige Notenteile erhalten geprüfte private Aliase samt
lokalen Beziehungen. Budgets und Grenzen stehen in [DOCX-REVIEWS.md](DOCX-REVIEWS.md).
ODT/DOC verwenden ihre bisherigen Wege.

Der Tabellenimport liest ODS, XLSX und binäres XLS in ein eigenes
Arbeitsmappenmodell und rendert erst danach Markdown. Die drei Leser verwenden
dieselbe Blatt-, Zell-, Linkziel-, Budget- und Diagnosegrenze; XLSX- und ODS-ZIP-Pakete
durchlaufen zusätzlich das zentrale Paket-Gate. Darstellung und Mehrblatt-Regel
stehen in [SPREADSHEET-IMPORT.md](SPREADSHEET-IMPORT.md).

ODM wird als OpenDocument-Masterpaket erkannt. Nur relative, vorhandene
ODT-Verweise im Verzeichnisbaum des Masters sind zulässig; entfernte Ziele,
Pfadfluchten, fehlende Dateien und ausbrechende symbolische Links werden
abgelehnt. Jeder Teil läuft anschließend durch denselben geprüften ODT-Adapter,
und seine Bilder erhalten abschnittsweise eindeutige Namen.

Der PDF-Adapter erkennt die PDF-Signatur und öffnet nur reguläre Dateien bis
1 GiB. Passwortgeschützte und beschädigte Dateien sowie Dokumente mit mehr als
1.000 Seiten lehnt er ab. PDFKit liefert pro Seite zuerst den Text; unter 20
Zeichen rendert der Adapter die Seite innerhalb eines gemeinsamen 64-Millionen-
Pixel-Budgets und übergibt das Bild lokal an Vision. Das Ergebnis bleibt
seitenweise und erhält immer eine Layoutverlustwarnung. Details stehen in
[PDF-IMPORT.md](PDF-IMPORT.md).

Der Bildadapter lässt ImageIO den tatsächlichen Bildtyp bestimmen und akzeptiert
PNG, JPEG, HEIC und TIFF. Er stagt die reguläre Quelle einmal, kopiert genau diese
Bytes als `images/image01.<endung>` ins Ergebnis und schreibt einen relativen
Markdown-Verweis. `ConversionOptions.imageTextRecognition` steuert, ob Vision
unter dem Bild lokalen OCR-Text ergänzt; die CLI bietet dafür `--image-ocr on|off`.
Die OCR-Prüfung liest Dimensionen vor dem Dekodieren, begrenzt jeden Frame auf
16 Millionen Pixel und alle TIFF-Frames zusammen auf 64 Millionen Pixel. Vision
respektiert die Bildorientierung und markiert unsichere Textzeilen. Details stehen
in [IMAGE-IMPORT.md](IMAGE-IMPORT.md).

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
  Erzeugern sowie temporäre PDFs mit eingebettetem Text und OCR-Fallback sowie
  PNG- und mehrseitige TIFF-Bilder.
  Bilddaten werden per Bytevergleich geprüft; DOCX/ODT und XLSX zusätzlich gegen
  Pandoc direkt.
- Pakettests prüfen Traversal, externe Bilder, Kommentare, angenommene Änderungen
  und die inhaltsbasierte Unterscheidung eines echten XLS vom alten DOC. Eigene
  Tabellen- und ODM-Tests prüfen Blattreihenfolge, Zell- und Linkzielbudgets,
  Merge-/Formelwarnungen, lokale ODT-Verweise, Pfadfluchten und eindeutige Assets.
- Engine-Tests prüfen Adapter-Inspections, Priorität und Mehrdeutigkeit sowie
  Kollisionsschutz und atomare Veröffentlichung einschließlich einer erst während
  der Konvertierung entstehenden Zielkollision unabhängig von SwiftUI.
- CLI-Tests prüfen Exit-Codes und JSON; App-Tests prüfen nur Übergabe und Zustand.
- Weitere manuelle Editorproben bleiben außerhalb des öffentlichen Repos und
  dienen als zusätzlicher Output-Diff, nicht als still aktualisierbares Golden
  Master.

## App-Einstellungen und Ergebnisaktionen

`AppModel` speichert Zielordner, Tabellenformat, Bild-/PDF-OCR, OCR-Methode und -Sprachen,
PDF-Layout, Frontmatter, Ausgabelayout und Batch-Parallelität in `UserDefaults`. Es bildet daraus `ConversionRequest` und
friert Optionen und Ziel für einen Mehrfachlauf ein. Der Zielordner ist ein
Elternordner; rekursiv gefundene Eingaben behalten darunter ihre relativen
Unterordner. Die Engine prüft weiterhin jede Veröffentlichung auf Kollisionen.
Wiederholungen ersetzen nur fehlgeschlagene Listeneinträge, an derselben Position.
Erfolgreiche Ausgaben bleiben bestehen.

`MarkdownPreview` liest über einen auf reguläre Dateien geprüften Deskriptor
einen Ausschnitt von höchstens 256 KiB plus ein Prüfbyte und kürzt eine
angeschnittene UTF-8-Endsequenz. Bei vorhandenem Manifest hasht es denselben
vollständigen Lesevorgang zur Ankerprüfung. Gerendertes Markdown darf nur
registrierte lokale Rasterassets anzeigen; fremdes HTML bleibt Text.
Öffnen und Kopieren beziehen sich auf das ausgewählte Ergebnis; die Zwischenablage
enthält ausschließlich den Markdown-Text und meldet ausgelassene Asset-Dateien.
Die SwiftUI-Ergebnisliste erzeugt Zeilen bedarfsgerecht über `LazyVStack`.
Die englischen und deutschen `Localizable.strings` liegen im fertigen App-Bundle
unter `Contents/Resources`, damit SwiftUI und AppKit dasselbe Sprachpaket lesen.

## Fortschritt, Auftragsabbruch und Werkzeuglimits

`ConversionCancellationToken` ist threadsicher und gehört dem aufrufenden
Auftrag. `DocumentConverter.convert` bindet pro Dokument einen abgeleiteten Token,
den Fortschrittscallback und das Werkzeug-Zeitlimit in `ConversionExecution`
(`TaskLocal`). Synchrone ODM-Unterimporte erben diese Bindung; getrennte
Konvertierungen erhalten getrennte Kontexte. Ein Werkzeugtimeout markiert nur
das aktuelle Dokument, nicht den übergeordneten Batch-Token. Die äußere
API-Grenze erhält Abbruch- und Timeoutfehler auch dann, wenn ein Adapter seinen
Parserfehler in einen Formatfehler übersetzt.

`ConversionProgress` enthält neben der Phase optional Einheit, erledigte Anzahl
und Gesamtzahl. PDF-Seiten, Bildframes, Tabellenblätter, Präsentationsfolien
und Notebook-Zellen melden bekannte Fortschritte. Die App wechselt für die Darstellung auf den Main Actor und
verwirft verspätete Meldungen eines beendeten Auftrags. Sie hält Task und Token
bis zur tatsächlichen Beendigung; der Abbruchknopf fordert Abbruch an und sperrt
sich während des Aufräumens. Bereits fertige Batch-Ausgaben bleiben erhalten.
Noch nicht gestartete Eingaben erscheinen als abgebrochen und können erneut
versucht werden.

Die Engine prüft Abbruch vor und nach Phasenmeldungen, insbesondere direkt nach
`publishing` und vor dem atomaren Move. Mit dem erfolgreichen Move gilt das
Dokument als veröffentlicht; ein Abbruch im anschließenden `finished`-Callback
widerruft diesen Erfolg nicht. Der dokumentbezogene temporäre Ordner wird auch
bei Fehlern während seiner Anlage entfernt. Bereits angelegte leere Elternordner
eines gemeinsamen Batch-Ziels bleiben bestehen.

`ProcessRunner` prüft Zeit und Abbruch alle 10 ms und sendet TERM an die
nachweislich eigene Prozessgruppe (sonst nur an den gestarteten Prozess), nach
250 ms nötigenfalls KILL. Testaufrufe können Zeitlimit, Schonfrist und
Ausgabegrenze ändern. Datei-Capture vermeidet volle Pipes; maximal 16 MiB je
Stream werden eingelesen. Der Größenmonitor beendet einen übermäßig schreibenden
Prozess, wobei die temporäre Datei zwischen zwei Prüfungen größer werden kann.
Kindprozesse, die absichtlich eine andere Prozessgruppe gründen, gehören nicht
zur erfassten Gruppe.

Der Abbruch ist kooperativ: Paketkopien, ZIP-CRC und Entpacken prüfen blockweise,
CSV alle 4096 Zeichen, XML-Parser an Delegate-Aufrufen, XLS an Datensatz- und
Sektorgrenzen. PDFKit/ImageIO und ein bereits laufender Vision-Aufruf kehren
zunächst aus ihrem jeweiligen Systemaufruf zurück; davor und danach wird der
Token geprüft. Entfernte Inhalte werden weiterhin nicht geladen.

## Paketleser und Formatinspektion

`ZIPArchiveInspector` prüft ausschließlich ZIP-Struktur, Pfadnamen, Eintragsarten,
Größenbudgets und CRC-Prüfsummen. `WordProcessingPackageInspector` besitzt das
Word-/ODT-Formatwissen und seine XML-Delegates. Beide Paketwege implementieren
`ZIPPackageReading`: einen Eintrag lesen, vorhandene Namen abfragen oder gezielt
mehrere Einträge lesen. Entpackte XML-Dateien werden nicht global gespeichert.

Für die Erkennung hält `ZIPInspectionSnapshot` denselben geöffneten und mit
`fstat` geprüften Deskriptor bis zum Ende seiner Nutzung. Schlussblock,
Zentralverzeichnis und angeforderte Einträge werden bedarfsgerecht mit `pread`
gelesen: höchstens 65.557 Bytes Schlussbereich, ein 64-KiB-Lesepuffer und die
bereits begrenzten Metadateneinträge. Der Namensindex wächst mit den vorhandenen,
weiterhin auf 10.000 begrenzten Einträgen; die Mediennutzlast wird nicht gehalten.
Es gelten weiterhin Archivbudgets und die Größen-/CRC-Prüfung jedes tatsächlich
gelesenen Eintrags. Fremde Dateien werden weder vollständig kopiert noch gemappt.
Widersprüchliche Schlussblöcke, überlappende Einträge, ungeklärte Lücken und
Deflate-Restbytes führen zum Abbruch. Reguläre digitale Signatur- und
Archive-Extra-Data-Blöcke werden anhand ihrer Längen erkannt. Die bestehende
Ablehnung von ZIP64 und verschlüsselten Paketen bleibt erhalten; ein
Entschlüsselungsheader macht ein verschlüsseltes Zentralverzeichnis nicht zu
einem unterstützten Klartextpaket.
Eine vollständige Medienprüfung bei jedem Erkennungsversuch brachte im Benchmark
keinen Vorteil und wurde nicht zur Voraussetzung der Formaterkennung gemacht.

Für die Konvertierung erzeugt `openVerifiedPackage` zuerst selbst eine neue
Arbeitskopie und prüft **alle** Einträge vollständig, auch nicht gelesene Medien.
Nur dieser Pfad erzeugt einen `ZIPPackageReader` mit einer gemappten privaten
Kopie. Er hält deren Verzeichnis und Namensindex bis zum Ende der Nutzung.
Sein Initialisierer ist dateiprivat; kein anderer Adapter kann einen beliebigen
Quellpfad als geprüfte Kopie ausgeben. Die Engine besitzt den Arbeitsordner und
räumt ihn auf. DOCX/ODT, ODS/XLSX und ODM reichen denselben Reader an
Formatprüfung, Parser und Metadatenleser weiter, statt die Paketdatei mehrfach
vollständig einzulesen. Ein kurzer `withVerifiedReader`-Aufruf besitzt und entfernt
seinen eigenen temporären Ordner.

`XLSXWorkbookParser` hält das gemeinsame Zellmodell und die Shared-String-Werte,
liest aber jeweils nur die XML-Datei eines Blattes und dessen Beziehungen.
Ein `autoreleasepool` beendet pro Blatt zusätzlich die Lebensdauer der
Foundation-Parserobjekte. Shared-String-XML wird nach seiner Auswertung ebenfalls
freigegeben. Das Zellmodell bleibt absichtlich vollständig erhalten; die
Speichermessung steht in [PERFORMANCE.md](PERFORMANCE.md).

`OLECompoundDocument` kennt Header, Sektorketten, Mini-Streams und benannte Streams.
`LegacyWordAdapter` prüft darin auf `WordDocument`, bevor `textutil` die geprüfte
Arbeitskopie untersucht; XLS-Container gelangen damit nicht in Apples Word-Importer.
`LegacyXLSWorkbookParser` interpretiert erst den gelieferten `Workbook`-/`Book`-
Stream als BIFF und baut das Tabellenmodell. Gemeinsame begrenzte Little-Endian-
Lesezugriffe liegen in `BinaryDataReading.swift`.

Die CLI trennt `CLIArguments.swift` (Optionen und Validierung), `CLIOutput.swift`
(JSON, Katalogdarstellung und Exit-Codes) und `CLIExecution.swift` (Dateiausführung,
Batch-Ziele und Fortschritt). `main.swift` hält Einstieg und Signalregistrierung.
`ConversionPostprocessor` führt Frontmatter und Textbundle ausschließlich im
Staging-Bereich aus. `DocumentConverter` behält Pfadvalidierung, Abbruch und den
atomaren Veröffentlichungsschritt. Der Markdown-Rewriter wurde nicht verändert.

### PDF-Textordnung und Diagnosen

`PDFTableGeometry` liest begrenzt lokale PDF-Pfade und liefert geschlossene
Gitter als zusätzlichen Tabellenbeleg. `PDFStructuredLayout` ordnet Text in
Zellen ein, maskiert die Werte, erzeugt Überschriften und nennt ungelöste
Spaltenmehrdeutigkeit. Bei Standard-OCR bleibt der Legacy-Pfad zum Vergleich unverändert.

`PDFAdapter` koordiniert die verifizierte PDF-Kopie, Seitenbudgets und OCR.
`PDFAnnotations` liest begrenzt Kommentare, Markierungen und Linkaktionen aus
dieser privaten Kopie. Eindeutige digitale Textbezüge ergeben Inline-Links,
sonst bleiben sichere Ziele separate Seitenanmerkungen. Rohwerte schützen
Rich-Text-Inhalte und Datumsangaben vor unbeabsichtigter Interpretation;
Popup-Verweise müssen beidseitig und eindeutig passen. Detailzuordnungen tragen
Seite und Anmerkungsnummer. `DocumentLinkTarget` prüft erlaubte externe Ziele
für PDF und Präsentationen gemeinsam; der Renderer maskiert Linksyntax separat.
PDF-Rasterung blendet Annotationen pro Aufruf aus und stellt den Displayzustand
auch bei Fehlern wieder her.

`PDFImageResources` durchsucht begrenzt lokale Bild-/Formressourcen als Hinweis
auf gemischte Seiten. `PDFTextLayout` rekonstruiert geprüfte Textpositionen und Schriftgrößen,
ordnet zwei Spalten und bereinigt auf Wunsch wiederkehrende Ränder und
Worttrennungen. Bei unsicherer Geometrie bleibt der gesamte Originaltext.
`OCRLanguageSelection` validiert gemeinsam für PDF und Bilder gegen die lokal
von Vision unterstützten Sprachen. `ConversionLocation` ergänzt bestehende
`ConversionWarning`-Werte optional um Seite, Blatt, Zelle, Folie, Frame,
Quellabsatz sowie Nachrichten- und Notizkennungen. Die CLI behält
Textwarnungen und ergänzt bei vorhandenen Meldungen `diagnostics` und
`diagnosticGroups`. Bedeutung, bekannte Fundstellen und tatsächlich ausgelassene
Diagnosezahlen stehen maschinenlesbar zur Verfügung; die App zeigt den Bezug
in ihrer bisherigen Warnungsliste. Der Vertrag steht in [DIAGNOSTICS.md](DIAGNOSTICS.md).

ODS-Positionsdiagnosen berücksichtigen noch nicht materialisierte leere Zeilen
und Zellen. Bei wiederholten betroffenen Elementen nennen sie die erste Zelle
des wiederholten Bereichs.

### Präsentationen und Notebooks

`PresentationAdapter` bindet PPTX/PPTM/POTX und ODP an den geprüften Paketleser.
`PresentationImport` liest ihre Struktur; `PresentationSlide`/`PresentationBlock`
und `PresentationRenderer` teilen Absatz-, Listen-, Tabellen-, Bild- und
Notizdarstellung. `PresentationText` enthält getrennte Textläufe mit validierten
Linkzielen; der Renderer maskiert erst den gesamten Quelltext und ersetzt danach
nur eigene Linkmarker. Interne Beziehungen werden auf ursprüngliche Foliennummern
abgebildet und gegen die tatsächlich ausgewählten Folien geprüft. Die gemeinsame
URI-Maskierung liegt in `MarkdownEscaping`. `ImportXML` begrenzt die XML-Bäume und lehnt Entitätsdeklarationen
ab. `ImportTextBuilder` prüft vor jeder String-Vergrößerung das Ausgabebudget;
ODP-Wiederholungen werden zusätzlich vor ihrer Expansion geprüft.

`NotebookAdapter`/`NotebookImport` lesen ausschließlich Notebook-JSON. Dynamische
Codefences verhindern, dass Quellcode Markdown-Struktur öffnet. Der bestehende
`MarkdownLinkTargetRewriter` übernimmt Attachments, ohne Codezustände neu zu
implementieren. Beide Importwege nutzen `ImportMediaStore` für begrenzte lokale
Bilddaten, Hash-Deduplizierung und Assetpfade sowie `ImportDiagnostics` für
begrenzte Warnungslisten. Kein neuer Importweg startet externe Prozesse.

### Gemeinsame Batchgrenze

`BatchConverter` führt vorgeplante `ConversionRequest`-Werte mit ein bis vier
Workern aus. `BatchOutputPlan` prüft alle Ziele und optionalen Root-Verzeichnisse
gegen sämtliche Quellen, reserviert Ziele in Eingabereihenfolge und legt erst
danach Elternordner an. Der Plan schützt auch die einmal aufgelösten Quellpfade;
`ConversionExecution.Context` führt diese Schutzmenge und die geplanten
Quellauflösungen bis in die erneute Ausgabeprüfung vor Veröffentlichung weiter.

`BatchConversionResult` bleibt an seinen ursprünglichen Index gebunden.
`BatchConversionProgress` trägt Sequenz, Index, abgeschlossene Gesamtzahl,
laufende Indizes und optionalen Dokumentfortschritt. CLI-Ausgabe und Appzustand
entstehen weiterhin in den dünnen Adaptern. Die App verwirft veraltete
Fortschrittsmeldungen, erhält beim Retry bestehende Ergebnisse und verwendet
weiterhin die bedarfsgerecht aufgebaute Ergebnisliste ohne automatische Vorschau.

`OCRConcurrencyGate` umschließt `VisionTextRecognizer` unmittelbar beim
`handler.perform` und `VisionDocumentRecognizer` während des asynchronen Requests.
Ein `NSCondition`-Slot begrenzt beide OCR-Wege gemeinsam pro Prozess auf eins;
wartende Dokumente prüfen ihren Token alle 50 ms und geben den Slot per `defer`
frei. Jedes Dokument behält einen eigenen Kind-Token, damit Prozesszeitlimits
keinen ganzen Batch abbrechen. Nach Benutzerabbruch wartet die Batchgrenze auf
alle Worker und liefert fertige, fehlgeschlagene und nicht gestartete Eingaben
in ihrer ursprünglichen Reihenfolge zurück. `OCRAsyncBridge` verwendet für die
synchrone Konvertierungsgrenze einen eigenen Thread-Executor, damit gleichzeitig
wartende Swift-Aufgaben keine Fortsetzung im kooperativen Threadpool blockieren.
Kontext und Abbruchtoken werden ausdrücklich übergeben; die Grenze wartet auch
bei Abbruch auf das tatsächliche Framework-Ende.

## Quellzuordnung und Berichte

`ConversionRecording` ist an den synchronen Auftragskontext gebunden. Vollständige
`VerifiedFile`-Lesevorgänge liefern den Hash der tatsächlich übernommenen
Primärbytes; die vier nativen Renderer ergänzen bekannte UTF-8-Ausgabebereiche.
Frontmatter verschiebt diese Bereiche; der Link-Rewriter meldet tatsächliche
Textänderungen für das Textbundle. Standardkonvertierungen aktivieren weder
Hashaufzeichnung noch Zuordnung.

Nach der Nachbearbeitung prüft der Kern alle Bereiche, hasht fertige Ausgabedateien
und schreibt den optionalen Bericht vor der atomaren Veröffentlichung. Der
Foundation-Vertrag, Portabilität und Grenzen stehen in
[CONVERSION-REPORT.md](CONVERSION-REPORT.md). App, CLI und spätere Hosts
verwenden die Ergebnisfelder, ohne Parserzustand oder technische Marker im
Markdown nachzubilden.

## Gerenderte Vorschau

`MarkdownPreview` liest begrenzt und prüft bei bekannten Manifesten denselben
Byte-Strom. `RenderedMarkdownPreview` erzeugt aus dem gepinnten Markdown-AST
ausschließlich maskiertes HTML, statische Darstellung und bekannte Quellanker.
`PreviewAssets` öffnet nur registrierte Ergebnisbilder über gehaltene
Verzeichnisdeskriptoren und liefert begrenzte PNG-Thumbnails.

`MarkdownPreviewPane` verbindet Quelltext, native WebKit-Suche, Ankersprünge und
sichtbare Grenzen. `AppModel` verwirft veraltete Lesevorgänge; der App-Adapter
öffnet nur die Ergebnisansicht. Pfad-, Ressourcen- und Darstellungsvertrag stehen
in [MARKDOWN-PREVIEW.md](MARKDOWN-PREVIEW.md).

## Quellenvergleich

`ConversionComparisonPane` ordnet Diagnosen und bekannte Ergebnisbezüge zu.
`ComparisonNavigation` hält die Regeln für Filter, Abschnittsbildung und genaue
beziehungsweise gröbere Sprünge zentral; mehrdeutige Blattbezüge bleiben offen.
App-Konvertierungen aktivieren die optionale Zuordnung ohne Berichtdatei.

`ComparisonSourceSnapshot` prüft einen vollständigen Byte-Strom und hält ihn nur
innerhalb der Vorschaugrenze. Ein eigener Actor erzeugt begrenzte PDF-/ImageIO-
Rasteransichten aus genau diesen Bytes. `ComparisonSourceModel` verwirft alte
Lese-/Rasteraufgaben und entzieht bei Dateisystemänderungen die Zuordnung.
Unbekannte Identitäten werden nicht nachträglich als passend angenommen.
Die UI-Adapter führen weder PDF-Aktionen aus noch ändern sie die Quelle;
Details stehen in [SOURCE-COMPARISON.md](SOURCE-COMPARISON.md).

## PDF-Seitenauswahl

`IndexSelection` normalisiert positive inklusive Bereiche, begrenzt ihre Anzahl
und löst sie erst gegen die tatsächliche Dokumentgröße auf. `PDFAdapter` trennt
Quellindex und Ausgabeindex: Nur gewählte Seiten liefern Text/OCR-Arbeit,
während Überschriften, Diagnosen und Quellzuordnungen ihre physischen Nummern
behalten. Beide Layoutwege nutzen dieselbe Auswahl; ohne Auswahl bleibt ihr
bisheriger Ablauf erhalten.

`inspectPDFContents` liefert aus einer geprüften privaten Kopie ausschließlich
begrenzte Seitenmetadaten und deren Quellhash. Es startet weder Import noch OCR
und veröffentlicht nichts. Größen-/Seitenlimits gelten für die ganze Quelle,
Arbeitsbudgets für die ausgewählten Seiten. Details: [PDF-IMPORT.md](PDF-IMPORT.md).

## Arbeitsmappenauswahl

`SpreadsheetSelection` verbindet eine typisierte Blattauswahl mit bis zu 64 validierten A1-Rechtecken. XLSX, BIFF und ODS liefern Sichtbarkeit und ursprüngliche Blattindizes. Die vollständige Quelle bleibt an die bisherigen Parser- und Paketbudgets gebunden. Erst danach zerlegt die Auswahl ihre Rechteckvereinigung in disjunkte, begrenzte Ausgabeabschnitte; der gemeinsame Renderer erhält Zeilen-/Spaltenursprung und Quellblattindex. So werden entfernte Bereiche nicht zur großen umschließenden Tabelle expandiert. GUI-Adapter und SwiftUI sind daran nicht beteiligt. `inspectSpreadsheetContents` liefert einen hashgebundenen Überblick aus einem vollständig geprüften Snapshot ohne Ausgabeordner.

## Präsentationsauswahl

`PresentationSelection` verbindet ursprüngliche Folienintervalle mit der Notizübernahme. `PresentationImport` wählt über `p:sldIdLst` beziehungsweise die ODP-Seitenreihenfolge vor dem Lesen der Folienblöcke aus. Ausgeschlossene Inhalte erzeugen keine Konvertierungsdiagnosen oder Assets; die vollständige Paketprüfung bleibt davor aktiv. Fortschritt und Text-/Assetbudgets zählen die ausgewählte Arbeit, Quellenzuordnungen behalten die ursprünglichen Foliennummern. Die verifizierte Inhaltsübersicht liest höchstens 500 Folientitel und lokale Notizverweise ohne Medienablage oder Renderer.

## EPUB-Auswahl

`EPUBSelectionPackage` liest Container, OPF-Spine, XHTML und optionale Navigation aus verifizierten ZIP-Snapshots. Die Auswahl ändert OPF und gewählte XHTML-Dateien ausschließlich in einer privaten Kopie; das macOS-Systemwerkzeug `/usr/bin/zip` aktualisiert literal übergebene Paketpfade, anschließend wird das vollständige Paket erneut geprüft. Pandocs bestehende Sandbox bleibt erhalten. Zufällige interne Textmarken passieren die sichere HTML-Konvertierung, werden danach in ausschließlich generierte lokale Anker umgewandelt und müssen vollständig verschwinden. Linkumschreibung verwendet den bestehenden Markdown-Scanner, damit Code unverändert bleibt. Kapitelbereiche werden erst anhand der abschließenden Markdown-Bytes registriert.

### An die Inhaltsübersicht gebundene Aufträge

`ConversionRequest.expectedSourceIdentity` bindet eine dokumentbezogene Auswahl
an SHA-256 und Bytezahl der Inhaltsübersicht. Der Kern vergleicht unmittelbar vor
der Veröffentlichung mit dem vollständig verifizierten, tatsächlich importierten
Quellstrom. Ein erneutes Lesen des möglicherweise ersetzten Quellpfads ist dafür
kein Ersatz. Fehlende oder abweichende Identitäten verhindern die Veröffentlichung,
auch ohne Quellzuordnung oder Bericht. Eine Änderung nach dem importierten Snapshot
ändert dessen korrekt gebundenes Ergebnis nicht; der Quellenvergleich erkennt die
inzwischen abweichende Originaldatei weiterhin.

`ContentSelectionModel` lädt eine fensterlokale Übersicht mit Abbruch-Token und
Generationskennung. `AppModel` kopiert Basisoptionen pro Einzelauftrag und hält die
Auswahl nur für einen bewussten Wiederholungsversuch desselben Dokuments. Neue
Einzel-, Batch- und Dienstimporte verwenden wieder ihre vollständigen Eingaben.
Die Kurzbefehle-Aktion bildet optionale Parameter auf dieselben typisierten
Core-Auswahlen ab; widersprüchliche Formatfamilien werden vor dem Import abgewiesen.

## Benannte Konvertierungsprofile

`ConversionProfile` ist ein versionierter, SwiftUI-freier Wert. Portable Optionen,
dokumentgebundene Auswahl und ausdrücklich lokale Ziel-/Werkzeugpfade sind getrennt.
`ConversionProfileOptions` enthält keine Privatpfade oder Dokumentpositionen;
`presentationIncludeNotes` ist eine portable Präferenz. Eine explizite
`PresentationSelection.includeNotes` hat im Adapter weiterhin Vorrang.
`ConversionProfile.resolve` legt explizite Einzeloptionen über die Profilwerte;
Blattwahl und Zellbereiche werden unabhängig überlagert. Quellgebundene Auswahlen
benutzen die geprüfte Inhaltsübersicht und deren Hash/Größe. Die aufgelöste Anfrage
trägt `expectedSourceIdentity` bis zur bestehenden Prüfung vor Veröffentlichung.

`ProfileJSONPreflight` begrenzt Tiefe/Knoten und lehnt doppelte, auch maskierte
Schlüssel ab. Alle Modellebenen lehnen unbekannte Felder ab; nur fehlende bekannte
Optionsfelder erhalten dokumentierte Schema-Defaults. `ConversionProfileStore`
liest begrenzt, hält den Zielordner per Deskriptor, schützt die Namensvergabe mit
einer kurzen nicht wartenden Schreibsperre und publiziert vollständige 0600-Dateien
per exklusivem Hardlink. Ein vorhandenes Ziel wird nicht ersetzt. Die CLI bleibt
für Parsing, Verwaltung und explizite Optionsvorränge zuständig; Konvertierungslogik
bleibt im Kern. Der öffentliche Vertrag steht in [PROFILES.md](PROFILES.md).

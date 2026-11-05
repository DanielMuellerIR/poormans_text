# Umsetzungsplan für Poor Man's Text auf Linux

Stand: 2026-11-05. Planungsbasis: Version 0.41.7, Commit `919c575`.
P00–P04 sind als Entscheidungsproben dokumentiert; Swift ist als gemeinsamer
Konvertierungskern festgelegt. P05 ist integriert. Der Entwicklungsstand 0.41.19
enthält die portierten P06–P10-Formate/Sammlungen, PDF, Standard-OCR, Rasterbilder,
statische RTFD-Anhänge und Legacy-DOC sowie die dünne GTK-Oberfläche und lokale Pakete.
Die ausgeführten Produktprüfungen und noch offenen Abnahmen stehen getrennt in
den Berichten; die [aktuellen Produktnachweise](linux-port/P16-04119/README.md) binden die finalen Artefakte. HEIC ist als optionale lokale Decoderfähigkeit integriert; strukturierte OCR ist mit separat geprüfter lokaler Runtime optional integriert; ihre Inhaltsqualitätsfreigabe bleibt offen.
GTK4 ist seit 2026-11-05 die gemeinsame reversible Entwicklungswahl mit Fastra.
Die endgültige Desktopabnahme bleibt ein separates Tor und blockiert die Oberfläche nicht. Es gibt keinen Rust-Neubau des Konvertierungskerns.

| Paket | Implementierung / nachgewiesener Stand | Noch offene Abnahme |
| --- | --- | --- |
| P05/P06 | [Swift-Kern](linux-port/P05-INTEGRATION.md), [CLI/Datei-/Prozessschutz](linux-port/P06-INTEGRATION.md) | Native Mac-Gesamtregression bestanden; vollständige Zielsystemmatrix offen |
| P07/P08 | [Tabellen, Präsentationen, Notebooks, Mail und Sammlungen](linux-port/P07-P08-INTEGRATION.md) | Externe Referenzkorpora und finale Plattformabnahme |
| P09/P10 | [PDF, Raster und Standard-OCR](linux-port/P09-P10-INTEGRATION.md), [statische RTFD-Anhänge](linux-port/P10-RTFD-STATIC.md), [DOC/UNO](linux-port/P10-DOC-UNO.md) | Breitere natürliche Qualitätsdaten einschließlich HEIC, PDF-/RTFD-Parität und Zielsystemmatrix |
| P11 | [Optionale strukturierte Produkt-OCR und lokale Wortverfeinerung](linux-port/P16-04119/README.md); strenge synthetische Tabelle jetzt8/8 | Breiter unabhängiger Korpus und allgemeine Inhaltsvollständigkeit; natürliche PDF-Qualitätsfreigabe bleibt FAIL |
| P12/P14 | [GTK über CLI, Zwischenablage und Profile](linux-port/P12-P14-GUI.md) | PDF-/Bildrastervergleich mit Zoom und gebundener Clipboardvergleich integriert; GUI-Präferenzen integriert; echte Desktops und Systemintegration offen |
| P13 | [Echte Importmatrix und .16-RTFD-Delta](linux-port/P13-FASTRA.md), gebundener Fastra-1.165.1-Consumer | Positive ENEX-PDF-GUI-Umgebung, harte Consumerverluste und echte Desktopabnahme |
| P15 | [Vier Paketformate und native Installer](linux-port/P16-04118/README.md), optionale GTK-Paketierung | Native isolierte apt-/pacman-Zyklen und X11-/Wayland-Proben bestanden; echte Host-/Desktopintegration und öffentliche Distribution offen |
| P16 | [48 finale CLI-Neustarts](linux-port/P16-04113/series.json), [aktuelle Vollregression](linux-port/P16-04119/README.md) und paketbezogene Teilprüfungen | Mac: 1.092 Fälle mit neun Skips, Linux: 392 Fälle mit zwölf Skips, jeweils keine Fehler; Gesamtqualitäts- und Desktopabnahme offen |

Die früheren Entscheidungsproben bleiben im [Entscheidungsbericht](LINUX-DECISION.md)
erhalten und werden nicht nachträglich als Produktabnahme ausgegeben.

Ziel ist eine eigenständig verwendbare Linux-App samt CLI für CachyOS mit
KDE/Wayland und Linux Mint 22.2 mit Cinnamon/X11 auf x86_64. Beide Anwendungen
sollen mit Fastra zusammenarbeiten, ohne sich gegenseitig vorauszusetzen.
Die vorhandene native Mac-App und ihre CLI bleiben erhalten.

## Architekturentscheidung und ihre Bedingungen

**Gewählte Architektur (2026-11-04):** Den vorhandenen Swift-Konvertierungskern auf Linux nutzbar machen,
Apple-spezifische Backends abtrennen und eine Linux-Oberfläche in Rust über die
lokale CLI anbinden. P02 hat diesen Weg anhand einer lauffähigen Probe samt
Laufzeitlieferung auf beiden Linux-Zielen bestätigt. Swift ist als gemeinsamer
Konvertierungskern festgelegt. Die erste Produktintegration steht im P05-Bericht;
Rust ist keine Voraussetzung für jeden Konverter.

Der Bestand umfasst etwa 28.000 Zeilen in 107 Swift-Dateien unter dem Core-Target.
GUI und CLI sind bereits weitgehend getrennt. Der Core ist jedoch nicht einfach
Linux-kompatibel: PDFKit, Vision, AppKit/ImageIO, Darwin, CryptoKit und
Foundation-Unterschiede müssen an ihren tatsächlichen Import- und Aufrufstellen
behandelt werden. Allein ein `#if os(Linux)` um Imports löst diese Abhängigkeiten
nicht. Ein vollständiger Rust-Neubau würde auch ausgereifte Parser, Diagnosen,
Sammlungen und Schutzregeln erneut implementieren müssen.

| Bereich | Zuständigkeit |
| --- | --- |
| Portabler Swift-Kern | Erkennung, vorhandene Parser, Modelle, Markdown-/Asset-Verarbeitung, Diagnosen, Profile, Berichte und Ablaufsteuerung |
| Plattformadapter | Sicheres Lesen/Publizieren, Prozesse, PDF, OCR, Bilddecodierung und betriebssystemspezifische Konverter |
| CLI | Bestehender maschinenlesbarer Vertrag; dünner Adapter für beide Plattformen |
| Native Mac-App | Vorhandene SwiftUI-/AppKit-Oberfläche, Services/Shortcuts und Mac-Distribution |
| Linux-App in Rust | Dateien, Optionen, Vorschau, Fortschritt, Abbruch, Diagnosen und Linux-Desktopintegration; Aufruf der lokalen CLI |
| Fastra | Importentscheidung, Editor und Weiterbearbeitung; keine zweite Konverterimplementierung |

Die SwiftPM-Targets müssen so getrennt werden, dass ein Linux-CLI-Build weder
Sparkle noch AppKit/AppIntents auflösen oder bauen muss. FoundationXML, zlib,
Regex/Encoding und Hashing bekommen ausdrücklich getestete Abhängigkeiten.
Für Hashing eine portable bestehende Bibliothek prüfen; keine eigene Kryptografie.
Ein neuer FFI-Layer zwischen Rust-GUI und Swift ist zunächst unnötig.

Der frühere Rust-Ausweichweg bei gescheitertem P02 ist durch den bestandenen
Durchstich nicht ausgelöst. Eine spätere Abweichung von Swift braucht eine neue,
belegte Architekturentscheidung. Keine automatische Generalumschreibung und
keine dauerhaften zwei Konverter.

## Gemeinsam mit Fastra, aber in getrennten Repositories

Poor Man's Text bleibt im bestehenden Repository. Fastra entwickelt seine
Linux-App und den selektiv geteilten Rust-Kern im Repository `fastra`.
Der dortige Plan steht unter `docs/LINUX-PORT.md`.

Der [CLI-Vertrag](FASTRA-CONTRACT.md) gehört diesem Repository. PMT pflegt
Produzent und Vertrags-Fixtures; Fastra pflegt Verbraucher und Importdarstellung.
Die CLI-Grenze erlaubt unterschiedliche Kernsprachen ohne doppelte Formatlogik.
GTK4 ist als gemeinsame reversible Entwicklungswahl festgehalten. Fastra prüft
den anspruchsvolleren Editor; PMT P12 nutzt die belegten Ergebnisse, soweit sie
die eigenen Anforderungen erfüllen. Die endgültige Desktopabnahme bleibt separat. Keine gemeinsame UI-Bibliothek auf Vorrat.

Gemeinsame Ressourcen oder Pakete nur extrahieren, wenn beide Apps denselben
konkreten Bedarf haben. Ein PDF-Backend kann gemeinsam gewählt werden, ohne dass
beide Produkte denselben Viewer oder dieselbe Konverter-API erhalten müssen.
PMTs sichere Markdown-Vorschau zeigt HTML als Text und deaktiviert Links; sie
darf nicht durch einen unkontrolliert aktiven Editor-Webview ersetzt werden.

## Unverhandelbare Eigenschaften

- Quellen bleiben unverändert; bestehende Ausgabeordner werden nicht überschrieben.
- Erst vollständig in einem eigenen Bereich konvertieren, dann am Ziel atomar
  veröffentlichen. Keine halbfertigen Ergebnisse als Erfolg melden.
- Nur lokale Verarbeitung. Keine versteckten Downloads, OCR-Dienste oder
  Konvertierung auf einem entfernten Mac als Linux-Ersatz.
- Fehlende Werkzeuge und unterstützte Formate ehrlich melden. Eine Endung in
  einer Liste belegt noch keinen funktionierenden Konverter.
- Bilder, Anmerkungen, Tabellen, Sammlungen und Verlustdiagnosen gehören zur
  Portierung; reiner Fließtext allein bedeutet keine Funktionsgleichwertigkeit.
- Vorhandene Ressourcenlimits, Pfad- und Archivschutz, Abbruch und Kindprozess-
  Cleanup erhalten. Unterschiede der Dateisysteme ausdrücklich prüfen.
- Keine Erweiterung um iWork, XLSB, MHTML oder Markdown-nach-Office-Export.
  Die bestehenden Produktgrenzen gelten weiter.

## Frühe Entscheidungstests

P00 und P01 sichern den gemeinsamen Ausgangspunkt. P02–P04 sind begrenzte
Machbarkeitsversuche mit reproduzierbaren Eingaben. Zunächst höchstens vier
Stunden pro Versuch, dann Befund, Restaufwand und nächste Entscheidung berichten.
Das ist ein Diagnosepunkt, keine Aufwandsschätzung für die fertige Portierung.
Zweimal derselbe erfolglose Prüfweg ohne neue Erkenntnis führt zum Wechsel des
Ansatzes. Ein gescheiterter Backendversuch darf unabhängige Arbeit nicht blockieren.

### P02 Portabler Swift-Kern und Laufzeit

In einem isolierten Stand einen Linux-CLI-Build für repräsentative Konvertierungen
herstellen: CSV, XLSX, IPYNB und DOCX mit Bild; zusätzlich einen RTF-Fall für die
Encoding-Grenze. Keine Mac-Oberfläche portieren. Parser-, FoundationXML-,
NSRegularExpression-, CoreFoundation-Encoding-, Hashing- und zlib-Anforderungen
einzeln erfassen. Mindestens eine reale erfolgreiche Konvertierung pro gewähltem
Probeformat sowie Abbruch und Fehlerausgabe zeigen.

Eine auf Ubuntu-24.04-Basis gebaute Ausgabe auf Mint und CachyOS **ohne installierte
Swift-Entwicklungsumgebung** starten. Zuerst deklarierte bzw. mitgelieferte
Laufzeitbibliotheken prüfen. Das statische Swift-Linux-SDK ist eine Alternative,
keine Voraussetzung: dynamisches Nachladen ist dort eingeschränkt und verlinkte
Abhängigkeiten müssen zur statischen Auslieferung passen. Externe Programme wie
Pandoc/Tesseract verschwinden dadurch nicht.

**Entscheidung:** reproduzierbarer Build, vollständige Abhängigkeitsliste,
geprüfte Paketierungsrichtung und begrenzte verbleibende Anpassungen. Große
Foundation-Lücken oder eine nicht beherrschbare Laufzeitlieferung sind Gründe,
vor P05 die Rust-Alternative zur Entscheidung vorzulegen. Ein einzelnes fehlendes
Modul ist noch kein Beleg gegen Swift.

### P03 Linux-Dateisicherheit und Prozessverwaltung

Die bestehende Zusage des Kerns auf Linux mit realen Systemaufrufen prüfen:
eigenes Staging, Kollision am Ziel, Symlink/FIFO, ausgetauschte Quelle, volle
Platte, Rechtefehler, Abbruch und Prozessverlust. Publikationsstaging auf dem
Zieldateisystem verwenden oder eine gleichwertige Strategie nachweisen; ein
Rename über Dateisystemgrenzen ist keine atomare Veröffentlichung. Keine
Overwrite-Race durch getrenntes Existenzprüfen und anschließendes normales Rename.

Der Mac-Prozessrunner verlässt sich auf beobachtetes Foundation-Verhalten bei
Prozessgruppen. Auf Linux eine eigene Prozessgruppe nachweisen und bei Timeout/
Abbruch sämtliche Nachkommen beenden. Ausgabe begrenzen, Pipes ohne Deadlock
leeren und Argumente ohne Shell-Interpolation übergeben. Ein Kindprozess darf
nicht weiter in bereits freigegebene temporäre Verzeichnisse schreiben.

**Entscheidung:** Original und bestehendes Ziel bleiben in allen Fehlerfällen
erhalten; keine veröffentlichten Teilpakete und keine übrig gebliebenen Prozesse.
Btrfs und ext4 prüfen. Wechsel-/Netzlaufwerke erhalten eine belegte Behandlung
oder eine verständliche Einschränkung, keinen unsicheren Fallback.

### P04 Apple-Backends ersetzen

Vier kleine Proben mit gepaarten Mac-/Linux-Ergebnissen:

| Probe | Erster Linux-Kandidat | Zu belegende Eigenschaften |
| --- | --- | --- |
| PDF | Poppler; PDFium nur bei begründetem API-/Qualitätsbedarf vergleichen | Text, Koordinaten/Lesereihenfolge, Seiten, Bilder, Links, Annotationen und Fehlerfälle; `pdftotext` allein reicht nicht |
| Standard-OCR | Lokales Tesseract mit expliziten Sprachdaten | Scans, gedrehte Seiten, gemischter Digitaltext, Mehrsprachigkeit, Textpositionen, reproduzierbare Diagnosen |
| Bilder | Geeignete lokale Decoder, HEIC gesondert | Dimensionen vor großer Decodierung, Orientierung, mehrere Frames, bekannte Formate, beschädigte/überdimensionierte Dateien |
| DOC/RTFD | LibreOffice für DOC prüfen; RTF-/RTFD-Paketpfad aus vorhandener Logik ableiten | Listen, Bilder, Encoding, eingebettete Verweise und sichere Ausgabe; keine AppKit-Abhängigkeit |

LibreOffice braucht ein isoliertes Benutzerprofil und einen begrenzten Prozess.
`--headless` allein schützt weder vor Makros noch vor entfernten Ressourcen:
deren Deaktivierung und Ausbleiben von Netzwerkladevorgängen ausdrücklich prüfen.
Auch Pandocs Sandbox-Option ersetzt nicht pauschal den Schutz aller Ein-/Ausgaben.
Abhängigkeiten mit Versions-, Lizenz-, Redistributions- und Updatebedingungen
erfassen, bevor sie in ein Paket aufgenommen werden.

Strukturierte Dokumenterkennung separat vergleichen: Tabelle mit verbundenen
Zellen, mehrere Spalten, Listen, Foto und gemischtes PDF. Tesseract-Text oder hOCR
belegt keine Gleichwertigkeit mit dem vorhandenen strukturierten OCR-Pfad.
Gibt es keinen geeigneten lokalen Ersatz, bleibt P11 offen und die vollständige
Portierung blockiert; eine Teilversion benennt die Grenze ausdrücklich.

**Entscheidung:** Backend pro Fähigkeit, echte Vergleichsergebnisse und Grenzen.
Die Auswahl einer Bibliothek allein ist kein bestandener Formatnachweis.

## Arbeitspakete

Die nachfolgenden Arbeitspakete definieren den Zielumfang. Ihren aktuellen
Implementierungs- und Abnahmestand nennt die Kopftabelle; P11 und die vollständige
Systemabnahme bleiben offen. P00–P04 stehen im historischen Entscheidungsbericht.
Erfolgreiche Einzelproben sind keine vollständige Produktabnahme. Jedes Paket liefert eine abgegrenzte Funktion mit echten
Fixtures, gezielter Prüfung und eigenem zusammenhängenden Commit. Große
Formatgruppen in dokumentierte Teilpakete zerlegen; keine ungetestete Endung
freischalten. Bei Linux-Änderungen gemeinsame Mac-Pfade mitprüfen.

### P00 Referenz und Funktionsmatrix

**Abhängigkeit:** keine. README, Architektur, CLI-Optionen, Core-Adapter, Tests,
Profile, Berichte und GUI-Befehle erfassen. Für jedes Format und jede Fähigkeit
Referenzdatei, Backend, Linux-Paket, Abnahme und offene Grenze notieren. Kleine
synthetische/weitergebbare Dokumente verwenden; private Originale nicht einchecken.
**Abnahme:** Mac-Baseline mit Commit/Version; Inhalte und Verlustdiagnosen
unabhängig gezählt bzw. verglichen. Kein Produktumbau.

### P01 CLI-Vertrag und gemeinsame Prüfdaten

**Abhängigkeit:** P00. [Vertrag](FASTRA-CONTRACT.md) gegen den aktuellen Producer
und Fastra prüfen. Golden-Fixtures für Katalog, Einzeldatei, Sammlung, Warnung,
Abbruch, Fehler und unbekannte zusätzliche Felder anlegen. Bestandskompatibilität
erhalten; neue Protokollfelder erst bei tatsächlichem Bedarf gemeinsam abstimmen.
**Abnahme:** Producer- und Consumer-Prüfung mit beiden Commit-IDs. Keine Umstellung
auf Library/FFI nur für Fortschritt.

### P02 bis P04 Entscheidungstests durchführen

**Abhängigkeit:** P00, P01 soweit Schnittstellenausgaben betroffen sind.
**Lieferung:** Proben und Entscheidungsbelege aus dem vorherigen Abschnitt.
**Abnahme:** bestanden, verworfen oder konkrete Produktentscheidung erforderlich.
P03 darf als Sicherheitsprüfung parallel zur Sprachauswahl entworfen werden;
Produktadapter erst nach der Entscheidung festlegen.

### P05 Portablen Kern und Plattformgrenzen herstellen

**Implementiert in 0.41.8 als Entwicklungsstand.** Gemeinsame Tests, echte
CLI-Konvertierungen und Grenzen der Mac-/Linux-Abnahme sind im
[Integrationsbericht](linux-port/P05-INTEGRATION.md) getrennt aufgeführt.

**Abhängigkeit:** P02 bestanden oder ausdrücklich geänderter Architekturplan.
SwiftPM-Targets, Backend-Protokolle, gemeinsame Modelle, Erkennung, Markdown-
Postprocessing, Diagnosen, Profile und Berichte abtrennen. Mac-Adapter erhalten
ihr Verhalten; Linux-Targets müssen unabhängig baubar sein. Portable sichere
Byte-/Pfadlogik und Foundation-Unterschiede zentral behandeln.
**Abnahme:** gemeinsame Parser-/Diagnoseprüfungen auf beiden Plattformen; kein
Apple-Framework im Linux-Abhängigkeitsbaum und keine Verhaltensänderung auf Mac.

### P06 Erster nutzbarer Linux-CLI-Durchstich

**Abhängigkeit:** P01, P03, P05. Sichere Datei-/Prozessadapter produktiv anbinden.
Katalog, Hilfe, JSON, Fortschritt, Abbruch, Ausgabeziele und nötige Auswahloptionen
erhalten, einschließlich Ordner-/Stapelmodus mit `--jobs`, Frontmatter,
Textbundle und stdout-Grenzen. RTF, DOCX-Familie und ODT sowie vorhandene
Pandoc-Pfade für HTML,
Webarchive, EPUB, LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText und
FictionBook formatweise portieren. EPUB-Kapitelauswahl sowie DOCX-Kommentare und
Änderungsverfolgung nach dem vorhandenen Options-/Diagnosevertrag erhalten.
Lokale Assets und Remote-Verweisschutz prüfen.
**Abnahme:** jedes aktivierte Format besitzt ein echtes Fixture, klare Diagnose
und frisches Öffnen des Markdown samt Assets. Fehlt ein Werkzeug, meldet der
Katalog dies korrekt. Keine Paket-/Sammlungsunterstützung vortäuschen.

### P07 Tabellen, Präsentationen und Notebooks

**Abhängigkeit:** P05/P06. ODS, XLSX/XLSM/XLTX/XLTM, XLS, CSV/TSV, PPTX/PPTM/POTX,
ODP und IPYNB samt Blatt-/Folien-/Zellauswahl, Tabellenstruktur, Notizen,
Bildressourcen und Formatdiagnosen übernehmen. ODM und seine lokalen Verweise
ebenfalls erfassen. Bestehende eingebettete Inhalte erhalten, nichts ausführen.
**Abnahme:** unabhängige Zeilen-/Spalten-/Folien-/Zellzählung, Reihenfolge,
Sonderzeichen, Auswahlgrenzen und Quellverweise; keine stillen Auslassungen.

### P08 Mail und Sammlungen

**Abhängigkeit:** P03/P05/P06. EML/EMLX, MSG, MBOX als Datei und Apple-Mail-Paket
sowie ENEX portieren. Index, Einzeldokumente, Anhänge, Titel/Metadaten und
ordnerweise Assets erhalten. Paketnamen auf Linux nicht als gewöhnliche Datei
behandeln. Größen-/Anzahlgrenzen aus dem vorhandenen Kern übernehmen.
**Abnahme:** Anzahl und Reihenfolge der Dokumente/Anhänge, sichere relative Links,
Pfadkollisionen, defekte Einträge und vollständiges Entfernen eines abgebrochenen
Stagings. Sammlungswarnungen müssen am richtigen Dokument ankommen.

### P09 PDF, Bilder und Standard-OCR

**Abhängigkeit:** P04/P05/P06. Gewählte PDF-/Bild-/OCR-Backends implementieren.
Seiten-/Frameauswahl, Annotationen, verknüpfte Assets, sichere Bildverarbeitung,
Sprachauswahl und Mischung aus bestehendem Digitaltext und OCR erhalten.
Sprachcodes ausdrücklich auf installierte OCR-Sprachdaten abbilden.
**Abnahme:** gepaarter Qualitätskorpus mit Textbestand, Reihenfolge, Tabellen,
Links/Annotationen; Digitaltext nicht unnötig durch OCR ersetzen. Beschädigte,
verschlüsselte und übergroße Eingaben sowie Abbruch prüfen.

### P10 Legacy-DOC und RTFD-Pakete

**Abhängigkeit:** P04/P06; bei benötigter Bildnormalisierung P09.
Gewählte DOC-Konvertierung und RTFD-Leser ohne Apple-Framework anbinden. Originale
RTF-Bytes, lokale Paketassets, Listen und Encoding möglichst erhalten; tatsächliche
Verluste diagnostizieren. Keine Formatunterstützung durch bloßes Umbenennen.
**Abnahme:** echte DOC-/RTFD-Fixtures mit Bildern und Listen, fremde Pfade,
Makro-/Netzwerkversuche, Fehler und Zeitlimit ohne Hintergrundprozesse.

### P11 Strukturierte lokale Dokumenterkennung

**Abhängigkeit:** P04/P09. Erst nach bestandenem Qualitätsversuch einen lokalen
Backendpfad anbinden. Tabellenzellen, Lesereihenfolge, Überschriften/Listen,
Quellzuordnung und vorhandene Wahlmöglichkeiten erhalten. Modelle nur ausdrücklich
bereitstellen/installieren, keine versteckten Laufzeitdownloads.
**Abnahme:** festgelegter natürlicher und synthetischer Korpus; Inhalte, Zellen,
Reihenfolge, Laufzeit und Speicher. Keine Vollständigkeitsbehauptung bei fehlendem
Backend. Gescheiterte Qualitätsabnahme benötigt eine bewusste Umfangsentscheidung.

### P12 Linux-Oberfläche

**Abhängigkeit:** P06 und Fastra F01-Toolkitentscheidung; P07–P11 werden schrittweise
über CLI-Fähigkeiten sichtbar. Dateiauswahl/Drop, Optionen, Zielwahl, Start/Abbruch,
Fortschritt, sichere Markdown-/Quellvorschau, Diagnosen, Assets und Öffnen im Editor
umsetzen. Mehrdateibedienung nach aktuellem Produktumfang, keine neue Warteschlange.
**Abnahme:** vollständiger realer Bedienweg mit Maus/Tastatur auf Wayland und X11,
DE/EN, schmal/breit, Skalierung und
Fokus. Abbruch/Fehler dürfen keine Erfolgsmeldung oder aktiven Webinhalt hinterlassen.

### P13 Gemeinsamer Fastra-Durchstich

**Abhängigkeit:** P01/P06 und Fastra F13; für Sammlung P08, für App-zu-App P12.
Beide realen Programme prüfen: DOCX mit Bild, Tabelle, Sammlung, Verlustwarnung,
fehlendes Werkzeug, Abbruch und dauerhafte Assetpfade. Aus PMT erzeugtes Markdown
gezielt in Fastra öffnen; aus Fastra temporäres Ergebnis vollständig übernehmen.
**Abnahme:** alter/neuer Producer gemäß Vertrag, Paketversionen getrennt,
unveränderte Quelle, frisches Öffnen nach Beenden beider Apps und keine verwaisten
Prozesse. Testergebnis nennt beide Commits. Keine interne CLI-Kopie in Fastra.

### P14 Profile, Berichte und Systemintegration

**Abhängigkeit:** P05/P06/P12, Backendpakete entsprechend ihrer Fähigkeiten.
Vorhandene Profile, Auswahlbindung, Diagnosegruppen, Konvertierungsberichte,
Quellidentität und Source-Mappings bis in die Linux-GUI erhalten. Quellvergleich
und Zwischenablage unter Linux passend anbinden, einschließlich Import unterstützter
Zwischenablageformate mit transparenter Auswahl des tatsächlich verwendeten Formats.
Services/Shortcuts erhalten
sichtbare Linux-Entsprechungen durch CLI/.desktop-Einstiege, keine AppIntents-Kopie.
**Abnahme:** Hash-/Identitätsprüfung unabhängig, UTF-8-Bytepositionen korrekt,
Profil-Roundtrip ohne stille neue Defaults; Unterschiede im Plattformumfang
in Hilfe und Funktionsmatrix ausdrücklich dokumentiert.

### P15 Paketierung und Installation

**Abhängigkeit:** P02/P06, für GUI-Paket P12. Mint/Ubuntu-24.04-Paket und Arch-Paket
mit festgelegter Swift-/Rust-Laufzeit, Bibliotheken, Ressourcen und optionalen
Werkzeugen bauen. CLI unabhängig von der GUI nutzbar. Katalog muss tatsächlich
installierte Fähigkeiten melden; keine Downloads beim ersten Import.
**Abnahme:** frisches System ohne Entwicklungs-SDK, Start über Desktop/CLI und
aus Fastra, Upgrade/Entfernung ohne Nutzerdatenverlust, Leerzeichen/Unicode in
Pfaden, Offline-Betrieb. Erst später Flatpak/AppImage prüfen, insbesondere
Hostwerkzeuge, Berechtigungen und App-zu-App-Aufruf.

### P16 Vollständige Abnahme und Mac-Regressionsschutz

**Abhängigkeit:** alle Pakete des gewählten Umfangs. Gesamte Format-/Funktionsmatrix
auf beiden Linux-Zielen, lange Serien mit Prozessneustarts und wechselnden
Optionen sowie native Mac-Prüfungen der gemeinsamen Änderungen ausführen.
Bestehende Universal-/Notarisierungs-/CLI-Installationsregeln gelten unverändert.
**Abnahme:** keine ungeklärte Inhaltsverlust-/Quellschutzverletzung, jede
freigegebene Fähigkeit belegt, fehlende Backends klar als Lücke. Öffentliche
Veröffentlichung bleibt ein gesonderter Auftrag.

## Meilensteine und Reihenfolge

| Meilenstein | Pakete | Ergebnis |
| --- | --- | --- |
| M0 Entscheidungen | P00–P04 | Sprache/Laufzeit, sichere IO, Backendpfade und CLI-Vertrag belastbar |
| M1 Linux-Konvertierung | P05/P06, CLI-Anteil P15 | Eigenständig installierbare erste CLI mit ehrlich begrenztem Formatumfang |
| M2 Beide Apps verwendbar | P07/P08/P12/P13/P15 und Fastra F13 | GUI, Tabellen/Sammlungen und gemeinsamer Import mit vollständigen Assets |
| M3 Funktionsgleichwertigkeit | P09–P11/P14/P16, übrige Pakete abgeschlossen | Vollständige Format- und Funktionsmatrix; keine versteckten Plattformlücken |

P02/P03/P04 können nach der Referenzaufnahme unabhängig untersucht werden.
Ein Writer pro Arbeitskopie; normalerweise ein Writer für PMT und einer für
Fastra. Zusätzliche Parallelisierung innerhalb eines Repos nur mit ausdrücklicher
Pfad-/Worktree-Zuordnung. Keine gleichzeitigen Commit-/Build-Mutationen derselben
Arbeitskopie auf mehreren Betriebssystemen.

Fastra muss nicht auf alle Formate warten: F13 startet mit P06. P12 baut auf der gemeinsam bestätigten reversiblen GTK4-Wahl auf und wartet
nicht auf Fastras fertige App. P13 ist eine gemeinsame
Abnahme, keine Voraussetzung für die Implementierung von Fastra F13. Dadurch
entsteht keine Kreisabhängigkeit. Bei P11-Problemen können andere Formate fertig
werden; eine vollständige Portierung darf trotzdem nicht behauptet werden.

## Prüfumfang und Arbeitsübergaben

Die Funktionsmatrix enthält je Zeile Quelle im Bestand, Plattformbackend,
Fixture, erwartete Inhalte/Diagnosen, zuständiges Paket und Status. Insbesondere:
alle Formate/Container, Auswahloptionen, Profile, temporäre/dauerhafte Ausgabe,
stdout/JSON, Sammlungen, Source-Mappings/Berichte, Vorschau, CLI/GUI und Fastra.
Grenzwerte und exakte Optionen aus dem aktuellen Code übernehmen, nicht neu erfinden.

Ausgaben nicht allein byteweise mit einem einzelnen Konverter vergleichen:
Whitespace kann backendbedingt abweichen. Text-/Assetbestand, Reihenfolge,
Tabellenbeziehungen und Diagnosen unabhängig prüfen. Jede erlaubte semantische
Differenz muss dokumentiert sein. Dateibytes/Hashes bleiben verbindlich, wo
Originaltreue oder Quellidentität zugesagt wird.

Vor Performanceoptimierung in P00/P02/P04 Startzeit, Laufzeit, Spitzen-RAM,
Abbruchzeit und Hintergrundlast auf demselben Korpus messen; daraus messbare
Budgets festlegen. Keine feste Zeit-/Energieeinsparung ohne Messung zusagen.

Jeder Entwicklungsblock erhält Paket-ID, Basis-Commit, erlaubte Dateien,
Abhängigkeiten, Akzeptanzfälle und Stoppgrenze. Abschluss nennt Tests, Grenzen,
Commit, Schnittstellenänderungen und nächstes freies Paket. Nach P00–P04 zuerst
Entscheidungsbericht; keine automatische große Umschreibung bei einem Fehlschlag.
Dokumentation allein erhält keinen Versions-Bump. Nutzerwirksame Änderungen,
Hilfe und Releaseangaben folgen den bestehenden Projektregeln.

## Referenzen

- [Architektur und Adapter](ARCHITECTURE.md)
- [Build und Tests](BUILD-AND-TEST.md)
- [Sammlungen](COLLECTIONS.md), [Diagnosen](DIAGNOSTICS.md),
  [Profile](PROFILES.md), [Konvertierungsbericht](CONVERSION-REPORT.md)
- [PDF-Import](PDF-IMPORT.md) und [strukturierte OCR](STRUCTURED-OCR.md)
- [Statisches Swift-Linux-SDK und Grenzen](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
- [Poppler](https://poppler.freedesktop.org/) und [GLib-API](https://poppler.freedesktop.org/api/glib/)
- [Tesseract-Dokumentation](https://tesseract-ocr.github.io/tessdoc/)
- [LibreOffice-Startparameter](https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html)
- [Pandoc-Handbuch](https://pandoc.org/MANUAL.html)

Externe Referenzen geprüft am 2026-11-04. Sie belegen mögliche Werkzeuge, keine
bestandene Portierung. Versionen und Paketverfügbarkeit in P02/P04 erneut prüfen.

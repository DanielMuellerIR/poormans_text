# CLI-Vertrag zwischen Poor Man's Text und Fastra

Stand: 2026-11-05. Dokumentationsstand 6; **keine neue Protokollversion**.
Bestandsbasis: Poor Man's Text `919c575` (0.41.7), Fastra `6f59816` (1.157.1).
Diese Datei dokumentiert den vorhandenen Vertrag und trennt geplante
Linux-Abnahmen davon. Sie implementiert keine neue Schnittstelle.

P00/P01 wurden gegen PMT `17328f17` und Fastra `55ca7057` untersucht.
Die [historische Vertragsprüfung](linux-port/P01-CONTRACT.md) enthält reale
Mac-Producer-Antworten und den damaligen falschen Sammlungs-Öffnungspfad.
Fastra hat diesen Consumerfehler inzwischen korrigiert; die vorhandenen
Mac-App-zu-App-Belege sind im [aktuellen P13-Bericht](linux-port/P13-FASTRA.md)
zugeordnet. Der [Entscheidungsbericht](LINUX-DECISION.md) bleibt historische Basis.

Der Linux-Producer ist integriert und der bestehende Vertrag ist benutzbar.
Die [aktuelle echte Linux-Matrix](linux-port/P13-CURRENT-EVIDENCE/REPORT.md)
bindet PMT 0.41.14 und Fastra 1.164.0/372: CSV, MBOX, DOCX/PNG/Tabelle,
ENEX/PNG/Diagnosen, RTF-Codepages, Kollision und Abbruch mit tatsächlichen
Werkzeugkindern bestehen. Ein frischer Fastra-Prozess rendert das adoptierte
DOCX-Ergebnis mit Bild und Tabelle. Das vollständige Consumer-Manifest wurde
vor und nach dem Lauf unabhängig geprüft; dessen vorhandene Buildnachweise
binden Commit f8e2bdc4933327ce2334ccb5450cb431273ef5bd. Es gab keine
Fastra-Quelländerung oder einen Ersatzconsumer.

[0.41.15](linux-port/P16-04115/README.md) ergänzt isolierte Linux-PDF-
Anhangvalidierung für ENEX und erhält MissingBackend als Exit 69. Der gezielte
aktuelle Fastra-Dialoglauf besteht DOCX/PNG unverändert und sperrt die Adoption
bei fehlendem PDF-Backend. Positive ENEX-PDF-Konvertierungen sind separat an der
Produkt-CLI belegt; die entsprechende positive GUI-Umgebung fehlt noch.
Die übrige echte .14-Matrix bleibt ihrem ursprünglichen Artefakt zugeordnet.
Die spätere optionale strukturierte OCR ist
keine Voraussetzung für Fastras bestehenden Importweg. Vollständige Desktop-
und Prozessverlustabnahmen des Consumers bleiben getrennte Freigaben.

[0.41.16 mit Fastra 1.165.1](linux-port/P16-04117/fastra-04116/REPORT.md)
besteht den echten RTFD-Import samt optionaler Textidentität, unreferenzierter
Anhangänderung und korrekter Adoption. Der Beleg bindet beide Produktcommits;
er verlangt `--source-map` nur im privaten Prüflauf. Normale Consumeraufrufe
bleiben unverändert und müssen fehlende `sourceIdentity` weiterhin erlauben.

Ab [0.41.17](linux-port/P16-04117/README.md) ist strukturierte Linux-OCR mit
separat geprüfter lokaler Modellruntime ausdrücklich optional integriert.
Standard bleibt `standard`; fehlende oder veränderte Runtime ergibt 69 ohne
Ausgabe. Es gibt keine neue Protokollversion, keinen automatischen Download
und keine neue Voraussetzung für Fastras normalen Import. Die allgemeine
Inhaltsqualitätsfreigabe bleibt wegen belegter Erkennungsfehler FAIL.

[0.41.18](linux-port/P16-04118/README.md) verbessert ausschließlich die Linux-GUI-
Diagnose bei fehlgeschlagenem Sandboxstart. Konvertierungsvertrag, Protokollversion
und normale Fastra-Aufrufe bleiben unverändert.

[0.41.19](linux-port/P16-04119/README.md) erhält RTF-Texthintergründe im gemeinsamen
Importpfad als `==Text==`, bei wörtlichem `==` im Inhalt als konstantes
`<mark>Text</mark>`. Die ursprünglichen Hintergrundfarben werden abgeflacht;
`richText.highlightColorApproximation` benennt dies zusätzlich. Der echte
Produktfall ergibt `Plain **Bold** ==Marked== Ä`. Das ist eine Verbesserung des
Dokumentinhalts im bestehenden Vertrag; keine neue Protokollversion oder
Consumer-Voraussetzung. Die separat gepinnte neue optionale Modellruntime wird
weiterhin nicht für Fastras normalen Import benötigt.

Die .12-Operation `--json --preview-page N -- quelle.pdf` beziehungsweise
`--json --preview-frame N -- bild` ist eine getrennte passive Leseoperation.
Sie liefert PNG-Base64, Hash, Maße, Auswahl und Quellidentität; weder
`outputDirectory` noch ein künstlicher Markdown-Konvertierungserfolg werden
erzeugt. Ein Consumer muss sie ausdrücklich aufrufen; der bestehende
Konvertierungsvertrag und dessen Erfolgsauswertung bleiben unverändert. Mac
meldet diese Linux-Previewfähigkeit kontrolliert mit69 als nicht verfügbar.
[SourcePreview-Nachweis](linux-port/P16-04112/preview/README.md).

## Zuständigkeit

Poor Man's Text erkennt und konvertiert lokale Dokumente, erzeugt Markdown und
Assets und berichtet Verluste. Fastra fragt sichtbar nach, startet einen lokalen
Prozess, zeigt Fortschritt/Diagnosen und übernimmt das Ergebnis zum Bearbeiten.
Beide Apps bleiben unabhängig installierbar. Keine doppelte Endungsliste und
keine Office-/Mail-Konvertierung im Fastra-Code.

PMT pflegt diese Datei und Producer-Fixtures. Änderungen am vorhandenen Verhalten
benötigen eine abgestimmte Verbraucherprüfung. Maßgebliche Implementierung:
`Sources/PoorMansTextCLI/CLIOutput.swift`, CLI-Argumente/-Runner sowie im
Fastra-Repository `MarkdownImportService` und die Import-/Publikationslogik.

## Vorhandene Aufrufe

```text
poormans-text --formats --json
poormans-text --json --output <neues-ziel> -- <quelle>
poormans-text --progress --json --output <neues-ziel> -- <quelle>
```

Argumente als einzelne Prozessargumente übergeben, niemals als interpolierten
Shell-Befehl. `--` trennt Optionen von einem potenziell mit Bindestrich beginnenden
Quellpfad. `<neues-ziel>` darf kein bestehendes Ausgabepaket überschreiben.

Fastra prüft derzeit `--help` auf `--progress`, hält den Formatkatalog fünf Minuten
im Speicher und begrenzt einen Import auf 120 Sekunden. Das sind aktuelle
Verbraucherentscheidungen, keine Protokollgarantien oder zugesagten OCR-Laufzeiten.
Für Linux in P01/F13 überprüfen; Änderungen gemeinsam begründen. Das CLI-
Werkzeugzeitlimit und die Gesamtdauer eines Importjobs sind unterschiedliche Dinge.

### Formatkatalog

Die Wurzel enthält `ok`, `version` und `formats`. Ein Eintrag besitzt
`format`, `extensions`, `container`, `containers`, `requires`, `available`
und `unavailableReason` (Text oder `null`). Die Implementierung ist für Feldtypen
und exakte Formatnamen maßgeblich. `container` bleibt das ältere Hauptmerkmal;
`containers` beschreibt die unterstützten Ablageformen, etwa Datei und Paket.

`version` ist die Produktversion, **kein Schemaindikator**. `requires` beschreibt
Werkzeuganforderungen; `available` die derzeit ermittelte Verfügbarkeit. Das ist
kein vollständiger Laufzeittest jedes Werkzeugs. Fehlende Abhängigkeiten müssen
spätestens bei der Ausführung kontrolliert gemeldet werden. Fastra darf Paket-
Formate nicht aufgrund einer gewöhnlichen Dateiendungsprüfung ausschließen.

### Ergebnis und Fehler

Die JSON-Antwort enthält `ok` und `version`; je nach Ergebnis zusätzlich:

| Feldgruppe | Vorhandene Bedeutung |
| --- | --- |
| `input`, `outputDirectory`, `markdownFile`, `assets` | Eingabe und erzeugte Dateien; erfolgreiche Pfade werden vom Producer absolut/kanonisch ausgegeben |
| `warnings`, `diagnostics`, `diagnosticGroups` | Verständliche Warnungen und strukturierte Verlust-/Informationsdiagnosen |
| `sourceIdentity`, `sourceMappings` | Quellidentität und Zuordnung zum erzeugten Text, soweit verfügbar |
| `outputFiles`, `reportFile` | Ausgabebestand und optionaler Konvertierungsbericht |
| `documents`, `metadata` | Sammlungsdokumente und Metadaten |
| `error` | Fehlerbeschreibung bei fehlgeschlagener Ausführung |

Ab 0.41.16 kann `sourceIdentity.memberPath` bei RTFD exakt `TXT.rtf`
enthalten. `input` bleibt der Paketpfad. SHA256 und `byteCount` binden nur die
ursprüngliche Textdatei, ausdrücklich keine Anhänge oder das gesamte Paket.
Der vorhandene MBOX-Paketfall verwendet entsprechend `mbox`. Consumer müssen
unbekannte optionale Mitglieder ignorieren oder den Vergleich als unverfügbar
zeigen; weder Paketpfad hashen noch frei gelieferte Mitgliedspfade öffnen.
Bestehende Mac-Consumer dürfen das Zusatzfeld ignorieren.

Ein Sammlungsdokument führt `sourceIndex` (einsbasiert), `title`, `markdownFile`,
`assets` und `metadata`. Eine Sammlung ist ein vollständiger Ergebnisbaum mit
Übersicht, Einzeldokumenten und Assets. Nur die erste Markdown-Datei zu kopieren
verliert Inhalte. Bei Stapelaufrufen liefert die CLI `ok`, `version` und `results`;
ein Fehler beendet nicht zwingend die Bearbeitung der weiteren Eingaben. Fastras
bisheriger Importpfad startet eine einzelne Quelle.

Historische Besonderheit: `assets` des Sammlungsergebnisses enthält auch dessen
Markdown-Unterdokumente, nicht ausschließlich Bilder oder Anhänge. Der vorhandene
Fastra-Verbraucher entscheidet anhand dieser Liste, ob er den ganzen Baum
übernimmt. Producer dürfen diese Einträge nicht still entfernen. Bei der
Übernahme muss der tatsächlich gemeldete relative Markdownpfad erhalten bleiben:
Sammlungen verwenden `index.md`, nicht `<quellname>.md`. Der in P01 geprüfte Fastra-
Service berechnete nach dem Verschieben den falschen Öffnungspfad; die Proben
weisen den Fehler für MBOX und ENEX nach, während der Baum erhalten bleibt.

Bei `--json` gehört die finale JSON-Antwort auf stdout, Fortschritt auf stderr.
`--stdout` ist ein anderer Modus und nicht mit `--json` kombinierbar. Sammlungen
werden im stdout-Modus vor der ersten Markdown-Ausgabe abgewiesen.

| Exitcode | Bedeutung |
| --- | --- |
| 0 | Erfolg |
| 64 | Ungültiger Aufruf |
| 65 | Ungültige Daten |
| 66 | Eingabe fehlt/nicht lesbar gemäß Fehlerzuordnung |
| 69 | Benötigte Fähigkeit/Werkzeug nicht verfügbar |
| 70 | Interner Softwarefehler |
| 73 | Ausgabe kann nicht angelegt werden |
| 74 | Ein-/Ausgabefehler |
| 124 | Zeitlimit |
| 130 | Abbruch |

Exitstatus und JSON zusammen auswerten. Ein unbekannter Fehlercode oder defektes
JSON darf keine erfolgreiche Übernahme auslösen. Fehlertexte nicht als gültige
Dateinamen oder weitere Befehle interpretieren.

### Fortschritt und Abbruch

`--progress` erzeugt derzeit **Textzeilen**, keinen JSON-Ereignisstrom:

```text
Progress: <quellname>: <phase> [<einheit> <erledigt>[/<gesamt>]]
```

Die eckigen Klammern oben kennzeichnen optionale Bestandteile und sind keine
literalen Zeichen der Ausgabe. Bei Stapelläufen kommen Dateizähler und Angaben
zu laufenden Jobs hinzu; deren Zeilen sind nicht mit Einzelimporten gleichzusetzen.

Bekannte Phasen: `detectingInput`, `preparingOutput`, `converting`, `publishing`,
`finished`. Bekannte Einheiten des Producers: `file`, `page`, `sheet`, `frame`,
`slide`, `chapter`, `cell`, `message`, `note`. Consumer müssen unbekannte Einheiten kontrolliert behandeln. Der in P01
geprüfte Mac-Parser kannte nicht alle Einheiten.
Fortschritt kann unvollständig sein; Ausbleiben einer Zeile bedeutet keinen
Stillstand. Unbekannte stderr-Zeilen sind Diagnosetext, kein Erfolgssignal.
Dateinamen können Trennzeichen enthalten: Parser-Fixtures müssen das abdecken.
Die P01-Proben bestätigen Doppelpunkt und fragmentierte UTF-8-Übertragung.
Unbekannte Einheiten und Zähler ohne Gesamtzahl werden von Fastra ignoriert;
generische Phasen bleiben nutzbar. Ein LF im Dateinamen lässt sich im vorhandenen
Zeilenprotokoll nicht zuverlässig darstellen. Das ändert nicht die JSON-Ausgabe.

Abbruch wird über SIGINT/SIGTERM angefordert. Der Prozessrunner beendet externe
Werkzeuge einschließlich ihrer Nachkommen und räumt seine temporären Daten auf.
Für PMT ist diese Zusage unter Linux mit Runner-/Wrapper-/Guardverlust und
Namespace-pidfds [produktiv geprüft](linux-port/P06-INTEGRATION.md). Fastras eigener
Besitz-/Abbruchpfad benötigt seine gesonderte Abnahme. Fastra liest stdout/stderr begrenzt und ohne Deadlocks.

### Diagnosen und Quellzuordnung

Die bestehende Diagnosebedeutung `kind` unterscheidet `information`,
`approximation` und `contentLoss`; das sind keine Fehler- oder Vertrauensstufen.
Codes bleiben stabil; unbekannte Codes werden konservativ als
Annäherung behandelt. Fehlende Ortsangaben sind unbekannt, nicht null.
Der Host zeigt Verluste verständlich vor oder beim Öffnen; er entfernt sie nicht
allein deshalb, weil die Konvertierung erfolgreich endete.

Ausgabepositionen der Source-Mappings sind UTF-8-Bytebereiche, keine UTF-16-
Editorpositionen. Bereich `[offset, offset + length)` zentral und geprüft umrechnen.
Der Konvertierungsbericht besitzt sein eigenes `schemaVersion: 1`; das ist
**nicht** die Version der gesamten CLI-Schnittstelle. Source-Hashes beziehen sich
auf belegte Originalbytes. Eine unbekannte Identität samt `unavailableReason`
darf nicht als bestätigte Gleichheit gelten. Details:
[Diagnosen](DIAGNOSTICS.md), [Bericht](CONVERSION-REPORT.md),
[Profile](PROFILES.md), [Sammlungen](COLLECTIONS.md).

## Sicherheits- und Besitzgrenze des Verbrauchers

1. Fastra bestimmt einen eigenen temporären Arbeitsbereich und ein neues Ziel.
2. PMT schreibt ausschließlich in sein Staging und veröffentlicht vollständig.
3. Fastra behandelt zurückgelieferte Pfade weiterhin als unvertrauenswürdig.
   Zuerst das Ausgabeverzeichnis selbst per `lstat` als echten Ordner innerhalb
   des eigenen Bereichs bestätigen; erst danach Kandidaten auflösen und prüfen.
   Zwei aufgelöste Pfade mit gleichem Präfix schützen nicht vor einer bereits
   umgebogenen Wurzel. Verzeichnisgrenzen, Symlinks und unerlaubte Dateitypen prüfen.
4. Vollständigen benötigten Ergebnisbaum übernehmen; Links bleiben relativ und
   funktionieren nach dem Ende beider Prozesse. PMTs Arbeitsordner erst danach
   freigeben. Dauerhaftes Speichern und temporärer Import haben getrennte Besitzer.
5. Vor dem Öffnen prüfen, ob Zieltab, Projekt und Importgeneration noch gültig sind.
   Ein verspätetes Ergebnis darf keinen inzwischen anderen Tab überschreiben.

Die Quelle wird nie ersetzt. Ergebnisdateien dürfen weder fremde Dateien
einschleusen noch beim Aufräumen fremde Verzeichnisse löschen. Linux-Pfade mit
ungültigem UTF-8 werden vom Linux-Producer vor der Konvertierung kontrolliert
abgewiesen: direkte ungültige argv-Bytes mit64, ungültige Einträge innerhalb
eines gelesenen Quellordners mit74. Verzeichnislesen, Aliasziele und Ausgabeeltern ersetzen solche Bytes
nicht still im JSON-Pfad; die Produktregressionen stehen in der P06-Abnahme.
Der frühe isolierte P02-Harness wird dafür nicht als Produktbeleg verwendet.

## Geplante Ergänzungen und Kompatibilitätsabnahme

Die folgenden Punkte sind Arbeitsaufträge für P01/P13 und Fastra F13, noch keine
umgesetzten neuen Felder:

- Den heutigen Vertrag als echte Producer-/Consumer-Fixtures sichern, mit
  unbekannten Zusatzfeldern und fehlenden optionalen Angaben.
- Der historische Mac-Consumer las hauptsächlich `markdownFile`, `assets` und
  `warnings`. Der aktuelle Linux-Rust-Consumer erhält auch Diagnosen, Dokumente,
  Berichte und Zusatzfelder. Vollständige Nutzung und Ziel-/Prozessbesitz bleiben
  getrennte Consumerabnahmen; die alten Felder weiterhin liefern.
- Falls Textfortschritt oder optionale Fähigkeiten nicht robust genug sind,
  einen ausdrücklich angeforderten strukturierten Modus samt Versions-/Capability-
  Aushandlung entwerfen. Nicht unangekündigt stderr auf JSON umstellen.
- Laufzeitbudgets für große PDF-/OCR-Jobs anhand realer Messungen bestimmen.
  Unbegrenztes Warten ist ebenso wenig ein zulässiger Ersatz wie ein stiller Timeout.

Abnahme mindestens gegen: vorhandenen Mac-Producer und vorhandenen Fastra-
Verbraucher als Basis; neuen Producer mit altem Verbraucher; neuen Verbraucher
mit altem Producer im bisherigen Umfang; neue Linux-Kombination auf beiden
Zieldesktops. Neue Fähigkeiten bei alten Partnern verständlich begrenzen.
Jeder Beleg nennt beide Produktcommits und den geprüften Dokumentationsstand.

Pflichtfälle: DOCX mit Bild, RTF-Encoding, Tabelle, MBOX/ENEX-Sammlung, Verlust-
diagnose, fehlendes Tool, unbekanntes Zusatzfeld, defektes JSON, fremder absoluter
Pfad, Symlink-Wurzel, Abbruch/Timeout mit Kindprozess, wechselnder Zieltab und
frisches Öffnen mit Assets nach Prozessende. Konverterausgaben im Consumer-Test
dürfen gezielt bösartig sein; reale Arbeitsverzeichnisse sind keine Fixtures.

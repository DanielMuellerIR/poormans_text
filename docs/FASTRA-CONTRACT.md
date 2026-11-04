# CLI-Vertrag zwischen Poor Man's Text und Fastra

Stand: 2026-11-04. Dokumentationsstand 1; **keine neue Protokollversion**.
Bestandsbasis: Poor Man's Text `919c575` (0.41.7), Fastra `6f59816` (1.157.1).
Diese Datei dokumentiert den vorhandenen Vertrag und trennt geplante
Linux-Abnahmen davon. Sie implementiert keine neue Schnittstelle.

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

Ein Sammlungsdokument führt `sourceIndex` (einsbasiert), `title`, `markdownFile`,
`assets` und `metadata`. Eine Sammlung ist ein vollständiger Ergebnisbaum mit
Übersicht, Einzeldokumenten und Assets. Nur die erste Markdown-Datei zu kopieren
verliert Inhalte. Bei Stapelaufrufen liefert die CLI `ok`, `version` und `results`;
ein Fehler beendet nicht zwingend die Bearbeitung der weiteren Eingaben. Fastras
bisheriger Importpfad startet eine einzelne Quelle.

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
`slide`, `chapter`, `cell`, `message`, `note`. Der bisherige Fastra-Parser kennt
nicht alle diese Einheiten; P01 muss unbekannte Einheiten kontrolliert behandeln.
Fortschritt kann unvollständig sein; Ausbleiben einer Zeile bedeutet keinen
Stillstand. Unbekannte stderr-Zeilen sind Diagnosetext, kein Erfolgssignal.
Dateinamen können Trennzeichen enthalten: Parser-Fixtures müssen das abdecken.

Abbruch wird über SIGINT/SIGTERM angefordert. Der Prozessrunner beendet externe
Werkzeuge einschließlich ihrer Nachkommen und räumt seine temporären Daten auf.
Diese Zusage muss unter Linux separat belegt werden; Mac-Prozessgruppenverhalten
ist dafür kein Nachweis. Fastra liest stdout/stderr begrenzt und ohne Deadlocks.

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
ungültigem UTF-8 brauchen eine ausdrückliche Fehler-/Transportentscheidung in
P01; keine stille Ersetzung von Bytes im JSON-Pfad.

## Geplante Ergänzungen und Kompatibilitätsabnahme

Die folgenden Punkte sind Arbeitsaufträge für P01/P13 und Fastra F13, noch keine
umgesetzten neuen Felder:

- Den heutigen Vertrag als echte Producer-/Consumer-Fixtures sichern, mit
  unbekannten Zusatzfeldern und fehlenden optionalen Angaben.
- Heute liest Fastra im Ergebnis hauptsächlich `markdownFile`, `assets` und
  `warnings`. Strukturierte Diagnosen, Sammlungen und Berichte schrittweise
  vollständig nutzen; die alten Felder weiterhin liefern.
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

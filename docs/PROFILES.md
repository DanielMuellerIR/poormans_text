# Benannte Konvertierungsprofile

Profile speichern wiederkehrende Konvertierungsoptionen lokal. Die CLI kann sie
anlegen, auflisten, auswählen und als versioniertes JSON importieren/exportieren.
App- und Kurzbefehle-Bedienung folgen separat. Profile starten keine Konvertierung
automatisch und enthalten keine Warteschlange.

## Wiederverwendbare Optionen

```sh
poormans-text --save-profile "Scans deutsch" --pdf-ocr always \
  --ocr-language de,en --ocr-method structured --report
poormans-text --profile "Scans deutsch" --pdf-ocr auto --json dokument.pdf
poormans-text --list-profiles --json
poormans-text --profile "Scans deutsch" --export-profile scans.json
poormans-text --import-profile scans.json
```

Verwaltungsvorgänge nehmen kein `INPUT` und wandeln kein Dokument um. Import,
Export und Auflistung lassen sich nicht mit Konvertierungsoptionen kombinieren.
Ein Export braucht `--profile NAME`. Ein bestehender Name oder eine bestehende
Exportdatei wird nie überschrieben. Namen sind ohne Beachtung der Großschreibung
und nach kanonischer Unicode-Normalisierung eindeutig. Es gibt kein automatisches
Umbenennen und keinen impliziten Ersatz. Profile enthalten keine Secret-Felder.

Die Reihenfolge lautet: explizite CLI-Optionen, dann Profilwerte, dann stabile
Defaults des bekannten Schemas. Die Position von `--profile` in der Argumentliste
ändert diesen Vorrang nicht. Wiederholte gewöhnliche Optionsschalter behalten
weiterhin ihren letzten angegebenen Wert.

`--no-frontmatter`, `--markdown-folder`, `--no-source-map`, `--no-report`,
`--no-pdf-remove-headers-footers` und `--no-pdf-dehyphenate` schalten entsprechende
Profilpräferenzen ausdrücklich aus. Enum-Optionen wie `--pdf-ocr off`,
`--image-ocr off`, `--ocr-method standard` oder `--docx-changes accept` überschreiben
wie bisher. Ein profilierter Bericht bleibt ein Bericht, bis `--no-report`
angegeben wird; `--no-source-map` allein schaltet die Zuordnung im Bericht nicht aus.
`--stdout` behält seine bisherigen Konflikte mit Bericht/Textbundle/Zielordner.

Portable Optionen umfassen Tabellenformat, Bild-OCR, Frontmatter, Ausgabeform,
PDF-OCR/-Layout/-Bereinigung, OCR-Methode/-Sprachen, DOCX-Änderungsmodus,
Präsentationsnotizen sowie Bericht/Quellzuordnung. Die Notizpräferenz wirkt nur
bei Präsentationen. Dokumentpositionen und lokale Pfade gehören in eigene Bereiche.
`--json`, `--progress`, `--jobs`, `--timeout`, Eingabepfade und der Speicherort der
Profile sind Aufrufentscheidungen und werden nicht im Profil gespeichert.

## Inhaltsauswahl an eine Quelle binden

```sh
poormans-text --save-profile "PDF-Auszug" --profile-source bericht.pdf \
  --pdf-pages "1,3-5" --pdf-ocr off
poormans-text --profile "PDF-Auszug" --json bericht.pdf
poormans-text --profile "PDF-Auszug" --clear-profile-selection --json anderes.pdf
```

Seiten, EPUB-Kapitel, Folien sowie Blatt-/Zellbereiche werden nur mit einer
expliziten `--profile-source` gespeichert. Die Inhaltsübersicht prüft Format,
Positionsgrenzen und Blattnamen; die Bindung speichert SHA-256 und Bytezahl,
keinen Quellpfad. Auch gleichnamige, aber geänderte Dokumente werden abgelehnt.
Eine bytegleiche Kopie bleibt gültig. Das Prüfen und Konvertieren verändert die
Quelle nicht. Die Konvertierung kontrolliert die erwartete Identität erneut vor
Veröffentlichung; ein Austausch zwischen Vorprüfung und Import wird abgefangen.

Ein solches Profil nimmt genau eine Datei. Mehrfach-/Ordnerimporte erfordern
`--clear-profile-selection`; diese Option verwirft die gespeicherte Auswahl
und ihre Bindung ausdrücklich. Weitere explizite Auswahloptionen beziehen sich
dann auf die aktuelle Eingabe. Ohne diese Freigabe gelten Quellprüfung und Bindung
auch bei explizit geänderten Bereichen weiter. Blattwahl und Zellbereiche werden
unabhängig überschrieben. Beim Ableiten eines gebundenen Profils mit
`--profile ALT --save-profile NEU` die Quelle erneut mit `--profile-source`
angeben oder die Bindung ausdrücklich verwerfen.

## Ausdrücklich lokale Ziele

```sh
poormans-text --save-profile "Lokaler Import" --profile-local \
  --output "$HOME/Documents/neues-ergebnis"
poormans-text --profile "Lokaler Import" --profile-local dokument.docx
```

Ein Ausgabeordner oder `--pandoc`-Pfad kann nur mit `--profile-local` gespeichert
werden. Ein Profil mit solchen Angaben verlangt dasselbe Opt-in bei Import,
Export und Anwendung. Ohne Opt-in wird vor dem Schreiben/Konvertieren abgebrochen;
Pfadangaben werden nicht still entfernt. Exportierte lokale Profile sind für den
bewusst gewählten Rechner bestimmt. Eine explizite `--output`- oder `--pandoc`-
Angabe hat Vorrang; vorhandene Ergebnisordner bleiben geschützt. Die Auflistung
zeigt Namen und Geltungsbereich, keine lokalen Pfade.

## Dateivertrag und Grenzen

Schema 1 verwendet `schemaVersion`, `name`, `options` sowie optional
`documentBinding` und `localTargets`. Ein kleines portables Profil:

```json
{
  "schemaVersion": 1,
  "name": "Scans deutsch",
  "options": {
    "pdfTextRecognition": "auto",
    "ocrMethod": "standard",
    "ocrLanguages": ["de", "en"]
  }
}
```

Fehlende bekannte Optionsfelder erhalten die Defaults von Schema 1: Tabellen als
Markdown, Bild-OCR an, kein Frontmatter, Markdown-Ordner, PDF-OCR/Layout automatisch,
keine Sprachbeschränkung, Standard-OCR, DOCX-Änderungen akzeptieren, keine PDF-
Randbereinigung/Dehyphenierung, Notizen an, kein Bericht/keine Quellzuordnung.
Falsche Typen, `null` statt eines Optionswertes, unbekannte Felder, unbekannte
Versionen und doppelte Schlüssel werden abgelehnt. Es gibt noch keine historische
Profilversion zu migrieren; unbekannte Versionen werden nicht geraten. Das Ergänzen
fehlender bekannter Felder ist der definierte Kompatibilitätsweg innerhalb Schema 1.
OCR-Sprachen müssen auf dem ausführenden System unterstützt sein; strukturierte
OCR verwendet die bereits dokumentierte Verfügbarkeitsprüfung und den Rückfallweg.

Der Standardspeicher liegt unter `~/Library/Application Support/PoorMansText/Profiles`.
`--profiles-directory VERZEICHNIS` wählt ausdrücklich einen anderen lokalen Speicher.
Neue Dateien haben Modus 0600, neu angelegte Verzeichnisse 0700. Dateinamen werden
aus dem normalisierten Namen gehasht; fremde symbolische Verweise werden nicht
beschrieben. Gleichzeitige Schreibvorgänge bekommen einen Fehler und können erneut
aufgerufen werden. Eine vollständige Datei wird atomar publiziert.

Ein Profil ist höchstens 256 KiB groß, ein Name höchstens 128 UTF-8-Byte; Separatoren,
Steuerzeichen und umgebender Leerraum sind unzulässig. Höchstens 32 Sprachcodes,
256 Profile und 2.048 Verzeichniseinträge werden verarbeitet. JSON ist auf 16
Verschachtelungsebenen und 8.192 Werte begrenzt. Inhaltsauswahlen behalten ihre
bestehenden Formate-/Mengenlimits; gebundene Quelldateien höchstens 1 GiB.
Verzeichnisdokumente bekommen keine erfundene Bytebindung. Defekte gespeicherte
Profile werden beim Laden/Auflisten gemeldet und nicht still übersprungen.

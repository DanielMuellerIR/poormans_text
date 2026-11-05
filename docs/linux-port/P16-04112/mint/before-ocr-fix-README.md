# Mint: relocierte Core-Laufzeit 0.41.12

Geprüft am 2026-11-05 auf Linux Mint 22.2 (Zara), x86_64. Die gebündelte Core-Laufzeit wurde einschließlich bin/lib/resources/Lizenzen kopiert; UI-Artefakte waren ausgeschlossen. CLI-SHA256 vor, in jedem Fall und danach: `8791293d05acc68774bc05abc0dde7429aa2ae8281a1d260dc090124a586374d`. Kein sauberer Commitstand wird behauptet. Keine Installation, GUI-Aktivierung oder Systemkonfiguration. Swift, Pandoc und Tesseract fehlten; vorhandene Python/Pillow/libheif/bwrap-Fähigkeiten wurden verwendet. Dies ist kein frischer Paketinstallationsnachweis.

19 Fälle in 3,292 Sekunden; 110 benannte Prüfungen, davon 107 erfüllt und drei Abweichungen in zwei Fällen. Quellen blieben unverändert. Jeder Fall endete ohne eigene lebende Nachkommen; die Probe verwendete Subreaper, pidfds für die Hauptprozesse und Reaping vor dem nächsten Fall. Das prüft diese abgeschlossenen Abläufe, keinen absichtlich injizierten Parentverlust.

Erfüllt: Version; vollständiger Katalog mit 29 Zeilen und Abhängigkeiten; vier getrennte NFC/NFD/Groß-/Kleinschreibung-CSV-Pfade; unabhängige vier XLSX-Zellen; Ausgabemanifeste mit Bytezahl/Hashes und UTF-8-Grenzen der 20 CSV/XLSX-Quellzuordnungen; PNG sowie ein- und zweibildrige HEIC mit byteidentischem Originalasset; PNG-/HEIC-Vorschauen einschließlich HEIC-Frame 2 mit Quellhash, PNG-Hash, Bytezahl und Dimensionen; fehlender PDF-Poppler/Cairo-Renderer und fehlender DOCX-Pandoc kontrolliert Exit 69; bestehendes Ziel Exit 73 bei unveränderten alten Bytes; Symlink-Zieleltern Exit 74 ohne fremde Ausgabe.

Offene Abweichungen, unverändert im JSON belassen:

- `missing-ocr`: Explizites `--image-ocr on` bei fehlendem Tesseract endet mit Exit 0 und veröffentlicht Bild-Markdown/Original. Diagnosen enthalten `ocr.backendFailure` als Inhaltsverlust, zugleich fälschlich `image.ocrApplied` („OCR text was added“). Die Auftragserwartung Exit 69/keine Ausgabe ist nicht erfüllt. Produktstelle: `LinuxImageAdapter.swift` Zeile 70 und 86–91; Backend-unavailable wird allgemein abgefangen. Kleinster vertragsgerechter Fix: diesen Fehlertyp weiterwerfen; „Applied“ erst nach tatsächlich erhaltenem Text melden.
- `invalid-utf8`: ungültige UTF-8-Bytes im argv-Dateinamen ergeben kontrolliert Exit 64 und keine Ausgabe. Erwartet war 74. `PoorMansTextCLI/main.swift` Zeile 33 weist dies ausdrücklich als ungültiges Argument zurück; keine neue Dateisystem- oder Crashregression behauptet.

## Wiederholung

Die synthetischen Fixtures liegen in `fixtures/`; keine natürlichen oder privaten Dokumente. PNG/HEIC und das zweiseitige PDF stammen aus den vorhandenen synthetischen Projektproben, DOCX enthält ein synthetisches Bilddokument. CSV und das kleine, unabhängig erzeugte Store-ZIP-XLSX enthalten Name/Value/Grüße β/42. `fixture-manifest.json` bindet alle Eingaben.

Einen neuen privaten leeren Arbeitsordner anlegen. Dorthin `runtime/` aus dem zu prüfenden vollständigen Build, `fixtures/`, beide Manifestdateien, `cli` und `probe.py` kopieren. Der hier eingefrorene CLI-Hash ist in der Probe ausdrücklich gebunden; für andere Builds muss er vor dem Lauf bewusst geändert und neu dokumentiert werden. Kein Downloader, keine Installation. Die Probe erwartet Linux mit Python 3 und pidfd-Unterstützung. Aufruf:

```sh
python3 probe.py "$WORK"
```

`$WORK` muss ein absoluter neuer eigener Ordner sein; `outputs`, `home` und `tmp` dürfen dort noch nicht existieren. CLI-Ausgaben werden ausschließlich dort angelegt. Originale Erwartungen bleiben in dieser historischen Probe erhalten; deshalb werden die genannten Abweichungen bei identischem Verhalten erneut rot protokolliert. Das Shellskript `cli` setzt die Swift-Bibliothekssuche nur für seinen CLI-Kindprozess.

`evidence.json` enthält portable Pfade als `$WORK`, Rohdiagnosen, Katalog, Source-/Asset-/Output-Hashes und Einzelfallprüfungen. PNG-Base64 wurde nach erfolgreicher Validierung für den kleinen Beleg entfernt. `runtime-manifest.json` bindet alle 40 mitgeführten Laufzeitdateien. `cleanup.json` belegt die Entfernung des eigenen entfernten temporären Baums nach Identitäts- und Prozessprüfung. Lokale große Laufzeit-/Transportkopien wurden ebenfalls entfernt; die kleine Lieferung bleibt zur Übernahme erhalten.

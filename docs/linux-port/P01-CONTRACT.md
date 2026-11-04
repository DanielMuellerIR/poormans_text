# P01: Vertrag gegen Producer und Consumer 2026-11-04

PMT-Quellstand: `17328f17d63843025b33b45a87fa3d13db5e11d7`.
Fastra-Quellstand: `55ca70579861954a21cfbd22d96e12059fec68db`.
Reale Mac-CLI 0.41.7, SHA-256 `39da1018a09a76a801cf7c35c1670ffba0d28458d72343cb9f699df1f3e0ba3e`.
Mac-Host macOS 26.7.2 arm64. Binary nicht neu gebaut: Hash und Version sind belegt,
Zuordnung dieses Binaries zum Quell-HEAD ist ohne Build-/Signaturmanifest offen.
Fastra auf Linux: Originalparser und originaler Service mit vorhandenem
runProcess-Testhaken; AppKit-/ObservableObject-/GitRunner-Typen ausschließlich
für Kompilation gestubbt. Keine echte App-/GUI-/GitRunner-Abnahme.

## Konkrete Vertragsbefunde

1. **Realer Sammlungsimport meldet falschen Öffnungspfad.** PMT gibt für MBOX und
   ENEX `markdownFile=index.md` aus; deren Unterdokumente stehen auch in `assets`.
   Fastra verschiebt dadurch korrekt den ganzen Baum, berechnet danach aber den
   zu öffnenden Pfad aus dem Quellnamen (`mail/mail.md`, `notes/notes.md`).
   Diese Dateien fehlen; tatsächlich liegt dort `index.md`.
   Beleg: `MarkdownImportService.swift:289`, `MarkdownImport.swift:289` ff.
   Der Originalservice wird mit echten Producer-JSONs durchlaufen; Beleg in
   `consumer-results.txt`. Dieser Befund ist Fastra-Arbeit, keine PMT-Änderung.
2. **Fortschritt wird teilweise verworfen.** Producer `CLIExecution.swift:110-119`
   erlaubt completed ohne total und note/message/chapter. Fastra
   `MarkdownImportProgress.swift:5,68-72` kennt diese Einheiten nicht und verlangt
   completed/total. Echte MBOX-Ausgabe enthält `message 0`, `message 1`, `message 2/2`;
   ENEX `note 0/2`, `note 1/2`. Generische Phasen bleiben lesbar.
3. **Zeilenumbruch im Dateinamen ist nicht darstellbar.** Producer fügt
   `lastPathComponent` unescaped in LF-Protokoll ein; Fastras Parser verarbeitet
   nur vollständige LF-Zeilen. Doppelpunkt/Leerzeichen/Slash in Parserprobe sind
   durch festen Quellnamenpräfix unproblematisch; LF-Fall wird verworfen.
4. **Zusatzfelder und optionale Felder**: aktueller Fastra-Parser ignoriert
   unbekannte Felder; fehlende assets/warnings werden leer. Defektes JSON und
   ok:false werden nicht als Erfolg dekodiert. Katalog unterstützt MBOX als Datei
   und Paket. Fehlendes Werkzeug bleibt als unavailable sichtbar.
5. **Pfadgrenze**: tatsächlicher Guard lehnt fremde absolute Datei, Symlinkdatei
   und Symlink-Ausgabewurzel ab. Ein eigener Pfad wird akzeptiert. Der Service
   prüft beim Verschieben eines ganzen Baums nur markdownFile, nicht jeden
   enthaltenen Dateityp/Pfad; vollständige bösartige Baumabnahme bleibt offen.
6. **Synthetische Robustheitsgrenze**: Antwort mit documents aber assets=[] lässt
   Fastra nur den Index übernehmen und den Rest bereinigen. Reale PMT-Sammlungen
   liefern die Unterdokumente in assets; darum hier kein realer Inhaltsverlust
   behaupten. JSON-Dokumentationsvertrag sollte diese historische Bedeutung von
   assets für Sammlung explizit festhalten.
7. Ungültiges UTF-8 in Linux-Pfaden, neuer Producer/alter vollständiger Mac-Consumer,
   wechselnder Zieltab, Timeout/Kindprozesse und frisches Öffnen in beiden echten
   Apps sind noch nicht abgenommen. Kein neues Protokollfeld daraus ableiten.


## Reproduktion und Grenzen

Die [Vertragsproben](../../scripts/linux-probes/contract) enthalten echte,
auf `/fixture/pmt-p01` pfadnormalisierte Mac-Producer-Antworten und getrennt
benannte synthetische JSON-Fälle. `run-consumer.sh <Fastra-Quellpfad>` kompiliert
die Originalparser und den Original-Publikationsservice mit dessen bestehendem
Prozess-Testhaken. AppKit-/GitRunner-Typen sind Teststubs, kein Ersatz für echte
App-zu-App- oder Prozessabnahme. Der Quellpfad und die Goldens können read-only
gemountet sein; Kompilierung und Szenarien entstehen nur in temporären Ordnern.

Geprüft: 33 Beobachtungschecks. Erwartete Fehlbeobachtungen bleiben Produktfehler.
`verify-baseline.py <PMT-Quellpfad>` prüft zusätzlich sieben reale Konvertierungen,
Berichts-/Quell-/Ausgabehashes, UTF-8-Bereiche, DOCX-Inhaltszahlen und PNG-Bytes.
`mac-baseline.py <PMT-Quellpfad>` wiederholt den Producer-Lauf auf macOS ohne GUI.
Kein neuer Protokollmodus wurde eingeführt und Fastra wurde nicht verändert.

Für Linux-Pfade lautet die Transportentscheidung: ungültiges UTF-8 vor Beginn
der Konvertierung mit kontrolliertem Fehler ablehnen. JSON-Pfade werden nicht
durch Ersatzzeichen repariert. Diese Validierung ist noch nicht im Produkt
implementiert und bleibt Voraussetzung für die Linux-CLI-Abnahme.

Offen bleiben die echte Fastra-App mit einem neuen Producer, Zieltabwechsel,
vollständiger bösartiger Ergebnisbaum, frisches Öffnen nach Prozessende und
Kindprozess-Timeout. P01 ist wegen des realen Sammlungsfehlers nicht abgenommen.

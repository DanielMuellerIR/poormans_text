# P12/P14: GTK-Oberfläche über dem gemeinsamen Swift-Kern

Stand: 2026-11-05, Entwicklungsvorschau 0.41.10. Die Oberfläche ist ein dünner
Rust-/GTK-Adapter; sie enthält keinen zweiten Konverter. GTK bleibt eine
vorläufige Entwicklungswahl auf Basis des vorhandenen Fastra-Durchstichs.
Die nachfolgenden bestandenen Proben sind keine vollständige Desktopabnahme.

## Integrierte Bedienung

Datei-/Ordnerdialog, mehrere Quellen, lokaler Drop und Startargumente verwenden
native Pfade. Nichtlokale Drops werden vollständig abgewiesen. Quellenwechsel
während eines Laufs sind gesperrt; verspätete Dialogantworten besitzen eine
Generationsprüfung. Optionen sind in Ausgabe, OCR/PDF, Inhaltsauswahl und
Ausführung gruppiert. DE/EN folgt der Umgebungssprache. Die Ansicht scrollt und
Aktionen brechen bei schmalen Fenstern um.

Fortschritt, Abbruch, Diagnosen/Katalog und die passive Markdown-Textvorschau
verwenden den vorhandenen CLI-Vertrag. Die Vorschau interpretiert kein HTML und
aktiviert keine Links. Ein Ergebnis muss ausdrücklich in der Standardanwendung
geöffnet werden. Vollständige Markdown-Dateien lassen sich begrenzt kopieren;
Assets bleiben als Dateien im Ergebnisbaum erhalten. Berichte und rohe
JSON-Details bleiben verfügbar.

Clipboardübernahme erfolgt ausschließlich auf Klick und mit expliziter Auswahl
einer tatsächlich angebotenen Kodierung: PNG, JPEG, GIF, TIFF, BMP, WebP, HTML
oder RTF. Originalbytes werden bis maximal 64 MiB gelesen und in einem privaten
0700-Verzeichnis/0600-Datei gehalten. Kein stiller Texture-/Plaintext-Ersatz.
Eine Konvertierung verlangt ein ausdrücklich gewähltes neues Ziel außerhalb
dieses privaten Bereichs. Abbruch/Schließen wartet auf die Prozessbarriere vor
Quellcleanup; unerwartete fertige Dateien werden nicht rekursiv entfernt.

Profile werden über die vorhandenen Core-CLI-Operationen gelistet, gewählt,
gespeichert, importiert und exportiert. Im Profilmodus werden ausgegraute
GUI-Konverterdefaults nicht zusätzlich übertragen. Quellenbindung, lokale Ziele
und das ausdrückliche Verwerfen einer gebundenen Auswahl bleiben Coreentscheidungen.
Allgemeine GUI-Einstellungen werden noch nicht automatisch gespeichert; hierfür
wurde kein ungeprüfter dauerhafter Writer eingebaut.

## Prozess- und Buildgrenzen

Die gesamte CLI läuft in einem zusätzlichen privaten PID-/Netznamespace. Der
Guard startet sie erst nach erfolgreicher Bindung des Namespace-pidfd und einem
Bestätigungsbyte der UI. Ohne diese Barriere beginnt keine Konvertierung. Der
Lebensdauerkanal bleibt beim Besitzer, nicht bei CLI-/Werkzeugkindern. Abbruch und
Runnerverlust beenden auch abgetrennte Kindprozesse; Abschluss verlangt
Namespace-Ende, eingesammelten Wrapper und geschlossene Captures. stdout ist auf
16 MiB, stderr auf 64 KiB, Fortschritt auf begrenzte Zeilen/Queue beschränkt.
Die äußere Namespaceaufsicht ersetzt nicht den Dateischutz des Swift-Kerns.

`build_linux_gui.py` hält Cache-, Target- und Veröffentlichungsverzeichnisse per
FD. Native Builds schreiben über gehaltene FDs; Container prüfen beide
Bind-Inodes vor dem Bau. Ersetzt werden nur erkannte eigene Artefakte mit
Producerkennung, Version, Binärhash und exakt bekanntem Dateibestand. Der nach
Rename tatsächlich bewegte Inode wird nochmals geprüft. Fremde/veränderte
Verzeichnisse bleiben erhalten. Rust-Crate- und Toolchain-Lizenzen werden aus
dem tatsächlich verwendeten Cache/Builder beigefügt.

## Bestandene Proben

- 28 Rust-Unit-Tests und 15 gesonderte Hosttests der Bridge bestanden. Die
  Bridgeproben prüfen unter anderem sofortiges Fork/setsid/Exit, UI-Verlust vor
  Bestätigung, erzwungenes pidfd-EMFILE, echte CLI-Konvertierung, Abbruch und
  vollständigen Prozessbaumabschluss. Der neue Guard besteht zusätzlich seinen
  bestehenden v1-Vertrag und alle 17 CLI-Runnerverlustfälle.
- Der GTK-Kandidat bestand im privaten Xvfb/D-Bus mit leerem Home reale
  Mehrdatei-/NFC-/NFD-Konvertierung, Startargumente, zweite Instanz, Ablehnung
  ungültiger UTF8-Pfade und Quellenwechsel während eines Jobs sowie Abbruch und
  Schließen. Datei-, Ordner- und Zieldialoge wurden separat tatsächlich bedient.
- Acht Clipboardkodierungen blieben bytegleich; Limitüberschreitung und Abbruch
  wurden abgewiesen. Ein echtes PNG wurde konvertiert und sein Assethash geprüft;
  die vollständige Markdown-Datei wurde über GdkClipboard identisch zurückgelesen.
  Ein gebundenes XLSX-A1:B2-TSV-Profil blieb trotz anderer GUI-Defaults erhalten;
  geänderte Quellbytes wurden vor Ausgabe abgewiesen. Lokale Profilziele benötigen
  ausdrückliche Zustimmung, Import/Export/Liste erhalten den Namen.
- Die echte Ubuntu-Release-GUI lief ohne Swift-/Rust-SDK auf privatem Xvfb. Ein
  Unicode-CSV wurde über Startargument geöffnet, Bericht per Maus aktiviert und
  mit Strg+Return konvertiert. Die passive Ergebnisansicht wurde visuell geprüft;
  Quell-/Ausgabehashes und Bericht wurden unabhängig verifiziert.
- Sechs isolierte Ausführungen des echten Buildskripts mit Fake-Compilern und
  30 Assertions prüfen unbekannte Dateien, eigenen Artefaktaustausch, Cache-/
  Target-/Elterntausch und den Tausch unmittelbar vor dem UI-Rename. Fremdziele
  bleiben unberührt. Dies sind Dateisicherheitsproben, keine Compiler-/ABI-Abnahme.

Kleine Belege stehen unter [P12-P14-EVIDENCE](P12-P14-EVIDENCE/sdkfree-release-gui.json).
Reproduktion der GTK-Proben: `linux/app/selftest.py` und
`linux/app/p14_selftest.py` ausschließlich mit Testfeature-Binary, eigenen
synthetischen Daten, privatem Xvfb/D-Bus und abgeschirmtem Home ausführen.
Die normale Release-App enthält diese Testhooks nicht. Die Buildwriterprobe
steht in `scripts/linux-probes/p15/verify_gui_build_safety.py`.

Offen bleiben echte KDE/Wayland- und Cinnamon/X11-Bedienung, Dateimanager-Drops,
externe Standardanwendungen, Skalierung, Fokus, Eingabemethoden und Barrierefreiheit.
PDF-/Bildrastervergleich, paketinterne Quellströme und allgemeine GUI-Präferenzen
sind nicht vollständig integriert. Eine visuelle Xvfb-Probe ersetzt diese Systemabnahmen nicht.

## Verifizierter Textvergleich und gemeinsame Dateizugriffe

Der Quellvergleich prüft die protokollierte Quellidentität und Ausgabemanifeste,
zeigt passive Ergebnisreferenzen und markiert die gelieferten UTF8-Bytebereiche
an den richtigen GTK-Zeichenpositionen. Er erfindet keinen Originalformatparser.
Vorschau, vollständiges Kopieren, Vergleich und externes Öffnen benutzen denselben
FD-Leser: jede Komponente ohne Symlinkverfolgung, nicht blockierend und nur
reguläre Dateien; Größe/SHA256 sowie physische Root-/Dateiidentität werden geprüft.
Ein fehlendes Prüfmanifest sperrt diese Aktionen verständlich. Profile werden
hierfür nicht still durch GUI-Defaults oder zusätzliche Flags überschrieben.

Eine tatsächliche Unicode-CSV liefert im Beispiel Byteoffset 82/Länge 23; die
Ansicht selektiert genau die GTK-Zeichen 80 bis 92. Eine gleich große Quelländerung
sperrt die Positionen und scheitert beim Rehash. Die bisherigen Clipboard-/Profil-
proben bestehen weiterhin. Zwei Reviewbefunde wurden mit eigenen Regressionen
korrigiert: Der tatsächlich geprüfte Snapshot bleibt bis zum GUI-Commit gebunden;
2048 überlappende Bereiche eines 12 MiB großen Textes erzeugen zusammen höchstens 573440
Snippetbytes. Endpunkte werden einmal linear umgerechnet und alte Prüfungen
regelmäßig abgebrochen. [Belege](P12-P14-EVIDENCE/source-comparison.json).

Externes Öffnen prüft unmittelbar vor GIO erneut. Die anschließende Übergabe
eines normalen Dateipfades an eine fremde Anwendung besitzt weiterhin ein
Austauschfenster; eine atomare Fremdapp-Öffnung wird nicht behauptet. Ein tatsächlicher
Start eines Standardeditors ist noch keine ausgeführte Abnahme.

Der finale Release-Build besteht zusätzlich einen englischen SDK-freien
Xvfb-Bedienweg bei zweifacher Skalierung und 700×850 logischen Pixeln.
Umbruch, Scrollbarkeit, Tastaturstart und geprüfte passive Vorschau funktionieren;
[Beleg](P12-P14-EVIDENCE/sdkfree-release-scale2.json). Das ist eine konkrete
Skalierungsprobe, weiterhin keine reale Compositor-/Desktopabnahme.

Lokale Einstiegsskripte werden nicht mehr durch namensbasierte Renames ersetzt.
Erkannte vorhandene Wrapper bleiben gebunden und unverändert; fehlende Namen
werden atomar ohne Ersetzen mit vollständigen versionierten Helfern verknüpft.
Unbekannte Dateien/Links und nachträgliche Ersetzungen bleiben erhalten.
Fehlgeschlagene Stages und alte Laufzeit-/GUI-Backups werden für gesonderten
Cleanup behalten. Elf gezielte zusätzliche Raceproben bestehen; die regulären
CLI-/GTK-Containerbuilds wurden danach tatsächlich wiederholt.

# P05: gemeinsamer Swift-Kern im Produkt

Stand: 2026-11-04. Basis `c18b903ae9e80f6a1fdd7e483e4d8e1f4a148176`,
Entwicklungsstand 0.41.8 / Build 93. Änderungen ausschließlich in PMT.
Fastra und der dort bearbeitete Consumerfehler gehören nicht zu diesem Block.

**P05 ist als Entwicklungsbuild implementiert.** Der vollständige Kern baut auf
Linux ohne Apple-Frameworks, Sparkle oder Ersatzparser. Echte Konvertierungen und
die SDK-freie Laufzeit sind auf beiden Linux-Zielen geprüft. Die auch im
Basisstand reproduzierte Mac-OCR-Blockade verhindert eine uneingeschränkte
Regressionsfreigabe. P06 ist nicht vollständig umgesetzt; seine
Sicherheitsgrundlage ist bereits angebunden.
Eine öffentliche Linux-Version oder ein vollständiger Rust-Neubau ist damit
nicht beauftragt oder geliefert.

## Implementierte Grenzen

- SwiftPM trennt die Linux-CLI und ihren C-Prozessguard von Mac-App, AppSupport
  und Sparkle. Der Mac-Lockfile bleibt unverändert; Linux besitzt einen eigenen
  Lockfile mit Swift Crypto. FoundationXML, CoreFoundation-Encoding, Regex,
  zlib und Hashing verwenden die tatsächlichen Bibliotheken.
- Gemeinsame Text-/OCR-Ergebnisdaten haben keine Vision-/CoreGraphics-Abhängigkeit.
  PDFKit, Vision, AppKit und ImageIO bleiben innerhalb der Mac-Adapter. PDF,
  Bildimport/OCR, Legacy-DOC und RTFD melden auf Linux fehlende Backends;
  der Katalog bietet dafür keinen vorgetäuschten Erfolg an.
- Eingebettete statische PNGs werden auf Linux mit libpng bis zu den Pixeln
  dekodiert. Grenzen gelten vor der Pixelallokation; beschädigte, abgeschnittene,
  übergroße, animierte PNGs und andere Bildformate werden abgewiesen.
  Breite Rasterbildunterstützung gehört weiterhin zu P09.
- Der echte Konverter verwendet den Linux-Publikationsadapter: gehaltene
  Ziel-/Staging-Verzeichnisdeskriptoren, privates Staging auf dem Zieldateisystem,
  `renameat2(RENAME_NOREPLACE)` und Elternidentitätsprüfung. Bei ESTALE bleibt
  das vollständige Ergebnis erhalten. Cleanup folgt keinen fremden Symlinks.
- Externe Konverter laufen im privaten PID-/Netz-Namespace mit Guard als PID 1,
  Lebensdauerkanal und pidfds. Der Runner bindet explizite Schreibbereiche,
  Lesepfade und Capture-Inodes. Er wartet auf das Namespace-Ende vor seinem
  Cleanup. Fehlender Guard, Bubblewrap, pidfd oder verweigerte Namespaces führen
  zum Fehler; es gibt keinen Prozessgruppen-Fallback.
- `./build.sh` erzeugt unter Linux CLI, Guard und lokales Laufzeitpaket.
  Swift-/Foundation-/Dispatch- sowie XML-/ICU-/PNG-Bibliotheken werden gebündelt,
  glibc/Loader bleiben Systemabhängigkeiten. Pandoc und Bubblewrap sind lokale
  Werkzeuge, keine versteckten Downloads. Ungültige UTF-8-Argumentbytes werden
  vor verlustbehafteter Pfadumwandlung mit Exit 64 abgewiesen.

## Ausgeführte Produktprüfungen

Kleine maschinenlesbare Belege und Binärhashes stehen unter
[p05-evidence](p05-evidence/integration.json). Die Probeformate begrenzen die
Aussage; der Build aller Parser ersetzt deren spätere formatweise Abnahme nicht.

| Prüfung | Ergebnis | Grenze |
| --- | --- | --- |
| Vollständiger Linux-Core, CLI und Guard, Swift 6.2.1 / Ubuntu 24.04 | bestanden | Entwicklungsbuild, keine installierbaren Distributionspakete |
| Linux-Unit-Tests | 14 ohne Fehler | sieben gemeinsame Parser-/Konverterfälle, sieben Linux-Publikationsfälle |
| Gemeinsame Tests auf nativem Apple Silicon | sieben ohne Fehler | identische Quellen, keine Linux-Testdoubles |
| Übrige native Mac-Regressionen | 1.051 Fälle, neun übersprungen, kein Fehler | ein zusätzlicher blockierter OCR-Test ausdrücklich ausgeschlossen |
| Echte CLI auf CachyOS und Mint 22.2 ohne Swift-SDK | je fünf Dokumente bestanden | CSV, XLSX, IPYNB, DOCX mit PNG, CP1252-/Unicode-RTF |
| Unabhängige Inhaltsprüfung auf beiden Linux-Zielen | bestanden | exakte Tokenzahlen, Quell-/Output-Hashes, PNG-Bytegleichheit |
| Kollision, Timeout, SIGTERM und ungültige UTF-8-Argumente auf beiden Linux-Zielen | bestanden | kein publiziertes Ergebnis bei Timeout/Abbruch; Exit 124/130/64 |
| Echter CSV-Konverter bei Ziel-Elternaustausch während Publikation | bestanden | ESTALE; Quelle/Fremdsentinel unverändert, Markdown/Bericht/sechs Mappings vollständig erhalten |

Der wiederholbare CLI-Prüflauf steht in
`scripts/linux-probes/verify_product.py`; die permanenten Tests liegen in
`Tests/PoorMansTextPortableTests` und `Tests/PoorMansTextLinuxTests`.
Die fünf Dokumente werden synthetisch erzeugt. Pandoc 3.1.3 war das ausdrücklich
bereitgestellte Fixture-/Konvertierungswerkzeug und wird nicht mit PMT gebündelt.

## Ergänzende gezielte Proben

Mit den tatsächlichen Prozessrunner-/C-Guard-Quellen wurden nach der
Capture-FD-Korrektur neun Prozessfälle, vier Scopefälle und zwei Austauschangriffe
bestanden. Darunter Runner-/Wrapper-/Guard-SIGKILL, abgelöste Enkel, Capturelimit,
literal übergebene Shellzeichen, readonly Quellen sowie ersetzte Capture-Namen.
Diese gezielten Runner-Harnessprüfungen sind von den vollständigen CLI-Läufen
oben getrennt. Zwölf sehr frühe Runnerverluste wurden vor dem Capturefix geprüft;
sie werden ausdrücklich nicht als erneute Prüfung des finalen Gesamtstands
gezählt. Der gezielte Review fand nach der Korrektur keine weitere konkrete
P1-/P2-Lücke in diesem Capturepfad.

Die ext4-/echten-ENOSPC-Nachweise aus [P03](P03-FOLLOWUP.md) bleiben
Entscheidungsproben. Sie sind keine erneute ext4-/ENOSPC-Abnahme des jetzt
integrierten vollständigen Konverters. Diese Wiederholung gehört zur weiteren
P06-Sicherheitsabnahme, ebenso der breite Produktkorpus für Runnerverlust.
Nach hartem Verlust des gesamten Runners muss ein äußerer Besitzer vor eigenem
Stagingcleanup weiterhin eine separate Namespace-Endebarriere verwenden;
Runnerexit allein genügt dafür nicht. Ununterbrechbare Kernel-/Hardware-I/O
ist nicht abgenommen.

## Offene Abnahme und nächster Block

Der vollständige Mac-Lauf blieb in
`StructuredOCRTests.testSynchronousBridgeRunsFromCooperativeTasksAndPropagatesContext`
stehen. Die Stackprobe zeigt wartende kooperative Tasks in `OCRAsyncBridge.run`.
Die Brücke und der Testkörper sind gegenüber dem Basiscommit unverändert;
`DocumentOCR.swift` erhielt ausschließlich die Mac-Plattformklammer.
Der gesonderte Lauf ohne diesen Fall bestand. Der anschließend ausgeführte
Vergleich am unveränderten Basiscommit baute erfolgreich und blieb im selben
einzeln gestarteten Test ebenfalls bis zur 90-Sekunden-Grenze stehen. Eine
einsekündige Stackprobe zeigt auch dort den Test in `OCRAsyncBridge.run`.
Damit ist die Blockade in der geprüften Mac-Umgebung bereits vor P05
reproduziert; die genaue Ursache und ihre Korrektur sind weiterhin offen.
Der begrenzte Vergleich ist keine bestandene Testausführung und keine
vollständige Mac-Regressionsfreigabe. Der
[kleine Ergebnisbeleg](p05-evidence/ocr-baseline.json) hält Compiler,
Betriebssystem, Frist und Cleanup fest. Beide Teststände sowie alle eigenen
temporären Mac-Kopien wurden nach der Prüfung entfernt.
GUI, Universal-Bundle, Notarisierung und Installation wurden nicht geprüft.

**Empfehlung:** P06 als nächsten begrenzten Produktblock bearbeiten: den
CLI-/Formatvertrag systematisch auf beiden Linux-Zielen abnehmen, die produktive
ext4-/ENOSPC-/Runnerverlust-Matrix wiederholen und dann die weiteren
Pandoc-Formate samt Assets/Diagnosen freigeben. Die bestehende Mac-OCR-Blockade
separat beheben, bevor eine uneingeschränkte plattformübergreifende Freigabe erfolgt.
P07–P16 bleiben eigenständige Arbeitspakete; PDF/OCR/DOC/RTFD sind weiterhin
ausdrücklich offen. Temporäre Testinstallationen und Arbeitskopien werden nach
Sicherung der kleinen Belege entfernt.

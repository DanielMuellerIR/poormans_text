# P02 – isolierter Swift-Linux-Durchstich

2026-11-04. Diagnoseprobe auf dem unveränderten PMT-Bestand; kein P05-Umbau.

## Ergebnis

Swift ist für den geprüften Kern technisch tragfähig. Swift 6.2.1 auf Ubuntu
24.04 baut die Probe; CSV, XLSX, IPYNB, DOCX mit Bild und RTF werden tatsächlich
konvertiert. Dasselbe Noble-Binary mit beigefügten Bibliotheken und Pandoc läuft
nativ auf CachyOS und Linux Mint 22.2, jeweils ohne Swift im PATH/Entwicklungs-SDK.
Die Konvertierungen laufen nach dem Setup ohne Netzwerk. Alle fünf Formate
bestehen auf beiden Hosts unabhängige Textzählung, SHA256-Quellidentität und
Quellunverändertheit; das eine DOCX-PNG bleibt byteidentisch.

Die Probe ist ein eigener dünner CLI-Harness über DocumentConverter, nicht der
vollständige bestehende CLI-Vertrag. Nur die fünf Probeadapter sind registriert.
Apple-Backends bleiben ausgeschlossen; daraus folgt keine Aussage über deren
Linux-Portierbarkeit. Die erreichte Machbarkeit erlaubt die Entscheidung für P05,
nicht die Freigabe einer fertigen Linux-App.

## Tatsächlich notwendige Anpassungen

- FoundationXML: explizite Imports sowohl für XMLParser als auch für die DOM-API
  XMLDocument/XMLElement/XMLNode. XLSX und DOCX-Paket-/Reviewpfade bauen und laufen.
- Foundation/Regex: NSRegularExpression aus Foundation bleibt vorhanden. UTF-8,
  Umlaute sowie RTF-CP1252 (`Größe`) und Unicode-Escape (`α`) kommen korrekt an.
  CoreFoundation CFStringConvertWindowsCodepageToEncoding und die Umsetzung zur
  String.Encoding funktionieren für dieses Fixture; weitere Codepages sind offen.
- Hashing: CryptoKit durch offizielles swift-crypto 4.2.0 / `Crypto` ersetzt,
  swift-asn1 1.7.4 transitiv gepinnt. Die geprüften SHA256-Werte stimmen mit Python
  hashlib überein. Keine eigene Kryptografie. BoringSSL wird aus dem Swift-Paket
  eingebaut; kein dynamisches OpenSSL/libcrypto nötig.
- zlib: System-Library-Modul mit zlib.h und `link z`; Noble zlib 1.3. ZIP-Fixtures
  sind DEFLATE-komprimiert und werden von den vorhandenen Parsern gelesen.
- Darwin durch Glibc; off_t wird bei einer bestehenden Int64-Schnittstelle explizit
  konvertiert. autoreleasepool wird als direkter Closure-Aufruf ersetzt.
- Darwins statfs/MNT_LOCAL ist nicht verfügbar. Probe deaktiviert an dieser Stelle
  mmap vollständig und verwendet den bestehenden lesenden Fallback. Eine sichere
  produktive Mount-/Dateisystembehandlung ist P03/P05.

## Bewusste Grenzen und Stubs

Der vollständige Patch ist core.patch. Apple-Pfade sind über excluded.json
entfernt. RTFD, PDF-/Präsentationsübersichten und Notebook-Bilddecodierung werfen
explizit `P02Unavailable`/ImportFailure. RTF-Farbdetektion meldet in dieser Probe
keine Farben; das Fixture enthält keine Farben. OCR-Sprachvalidierung ist im
Harness pass-through und OCR ist nicht registriert. MBOX-Verzeichnisidentitäten
werfen unavailable. Keine dieser Probevereinfachungen darf unverändert produktiv
übernommen oder als unterstützte Fähigkeit angeboten werden.

## Laufzeit und Paketierungsrichtung

Dynamische Auslieferung reicht für diese Probe. package-runtime.sh erfasst ldd
und liefert Swift/Foundation/Dispatch sowie FoundationXML mit. Nur Swift zu
kopieren scheiterte auf CachyOS an libxml2.so.2: Die Noble-ABI ist dort nicht mehr
installiert. Zusätzlich gebündelte libxml2.so.2 und ICU74 lösen dies; Linux Mint
22.2 nutzt dieselben Dateien erfolgreich. Keine Hostinstallation erforderlich.

Erfasste Systemabhängigkeiten: glibc/Loader, libm, libstdc++6, libgcc_s, zlib,
liblzma; für FoundationXML libxml2/ICU74. Beigefügtes Pandoc 3.1.3 benötigt
libyaml, Lua 5.4, GMP und libffi sowie `/usr/share/pandoc`-Daten. Der Launcher setzt
den eigenen `--data-dir`; ohne Daten scheitert Pandoc trotz vorhandenem Binary.
Alle tatsächlich aufgelösten Bibliotheken stehen in den
[Laufzeitbelegen](../../scripts/linux-probes/swift-core/evidence).
Dies ist eine Debug-Probe, keine optimierte Paketgrößenmessung.

Vor Distribution bleiben vollständige Lizenz-/Quellangebotspflichten (insbesondere
Pandoc GPL), Bibliotheksupdates/Sicherheitswartung, Loader/RPATH-Konzept,
Systempaketabhängigkeiten und Release-Build zu entscheiden. Das statische
Swift-Linux-SDK wurde nicht geprüft, weil der dynamische Weg bereits funktioniert.

## Fehler, Abbruch und Messgrenzen

Ungültiges IPYNB: Fehler auf stderr, Exit 1, kein publiziertes Verzeichnis.
Vorab gesetztes Abbruchtoken: `Conversion cancelled.`, Exit 1, kein Ergebnis.
Abbruch während externer Prozesse gehört zur separaten P03-Probe; hier nicht belegt.
Die Fehlercodes des Harness sind nicht die bestehenden Produkt-CLI-Exitcodes.

Ein warmer Korpuslauf mit fünf neuen Ausgabeordnern auf CachyOS: 0,220 s gesamt,
0,119 s Kindprozess-CPU User, 0,069 s System, maximal 39.988 KiB Kindprozess-RSS.
Einzelne Stichprobe, kein Performanceversprechen; `resource.RUSAGE_CHILDREN`
liefert das Maximum eines Kindprozesses, keinen addierten gleichzeitigen RAM.
Der restriktive Agent-Sandboxlauf blockierte Foundations lokales CFSocket beim
Prozessstart; native Ausführung außerhalb dieser Sandbox und auf Mint bestand.
Das war eine Testumgebungsgrenze, keine auf dem Zielhost benötigte Sonderfreigabe.

## Reproduktion

Die Dateien liegen unter [`scripts/linux-probes/swift-core`](../../scripts/linux-probes/swift-core).
Von dort aus:

```sh
python3 prepare.py /pfad/zum/repo /tmp/pmt-neue-probe
bash build-and-run.sh /tmp/pmt-neue-probe
python3 verify.py /tmp/pmt-neue-probe /tmp/pmt-neue-probe/runtime-output.XXXXXX
```

prepare.py liest nur das Repo, verlangt ein neues Ziel und wendet core.patch an.
Der Generator wurde auf ein frisches Ziel ausgeführt; alle erzeugten aktiven
Core-Swift-Dateien sind byteidentisch mit der erfolgreich gebauten Probe.
Setup benötigt Netzwerk für Ubuntu-Pakete und die gepinnten Swift-Abhängigkeiten;
Build/Konvertierung danach im Container mit `--network none`.
`run-runtime.sh` kann samt runtime/ und fixtures/ auf den Zielhost kopiert werden.
Kein komplettes Swift-Quellsnapshot muss dauerhaft gespeichert werden.

Grundlagen: [Swift Linux Packaging](https://docs.swift.org/latest/documentation/swiftlinux/packaging/),
[Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
und [swift-crypto](https://github.com/apple/swift-crypto).
Der dynamische Versuch verwendet bewusst die tatsächlich geprüfte Toolchain
6.2.1; daraus folgt kein automatischer Versionssprung auf die aktuelle Toolchain.

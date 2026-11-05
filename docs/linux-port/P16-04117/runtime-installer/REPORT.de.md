# Lokaler OCR-Runtimeinstaller: begrenzte Nachhärtung

2026-11-05. Basis: /tmp/pmt-runtime-installer-20261105/delivery. Ausschließlich
neue eigene /tmp-Kopie bearbeitet; keine Repo-, Runtime- oder Gitänderung.

Geändert sind nur der bestehende Installer und seine Tests:

- Relative Manifestpfade: strikt UTF8, maximal4096 UTF8-Bytes und64 Komponenten
  einschließlich Dateiname; vorhandene255-Byte-Komponentengrenze bleibt bestehen.
- Absolute normalisierte Quell-/Runtimeparentargumente: strikt UTF8 und
  maximal4096 UTF8-Bytes, vor jedem Dateisystemzugriff geprüft.
- Maximal65536 unterschiedliche abgeleitete Unterverzeichnisse; der interne
  leere Wurzelmarker zählt nicht dazu. Inkrementelle Prüfung während Manifest-
  validierung, vor Anlage eines Stages.
- JSON-Decoder-RecursionError wird zu InstallError mit verständlicher Meldung.
  Die CLI fängt RecursionError zusätzlich defensiv ab. Keine neue behauptete
  versionsunabhängige JSON-Nestinggrenze.

Ergebnis:34/34 Testmethoden bestanden auf Host Python3.14.9 und erneut unter
Python3.12.3 im bestehenden pmt-linux-package-test:latest, UID1000, cap-drop ALL,
Read-only-Containerroot, Netzwerk aus und64MiB eigenem tmpfs.27 ursprüngliche
Tests plus7 zusätzliche Methoden. Belege: tests.log und noble-tests.log.

Zusätzlich geprüft: exakte4096-Byte-/64-Komponenten-Grenzen mit Mehrbyte-UTF8,
4097Bytes und65 Komponenten, ungültige UTF8-argv für beide absoluten Argumente,
Surrogates in JSON-Pfaden, exakt65536 und65537 abgeleitete Verzeichnisse sowie
kontrollierter Fehler ohne Traceback und ohne Stage/Publikation. Das große
Verzeichnisinventar ist nur ein kleines generiertes Manifest, kein echter
65536-Verzeichnisbaum. Der echte tiefe JSONfall hat2000 Arrayebenen; Python3.12
wirft dabei kontrolliert, Python3.14 kann ihn parsen und weist danach sein
nicht unterstütztes Schema zurück. Eine zusätzliche deterministische Decoder-
RecursionError-Injektion belegt die Fehlerumwandlung auch auf Python3.14.

Keine Downloader-/Archivfunktion, kein neues Werkzeug und keine2GB-Kopie.
Der vollständige echte Runtimeinstallationslauf bleibt bei Root auf SSD. Die
frühere Kandidatmanifestvalidierung wird hier nicht als erneute Prüfung mit
den neuen Grenzen ausgegeben. Prüfsummen stehen in delivery-manifest.json;
hardening.patch bezieht sich auf die genannte ursprüngliche Lieferung.

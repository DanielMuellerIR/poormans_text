# Nativer Mac-Abschluss 0.41.14/build99

2026-11-05: bestanden. Explizit freigegebener aktueller 337-Dateien-Quellsnapshot
nativ arm64 auf macOS 26.7.2/Apple Swift6.4.2. CLI und AppExecutable kompiliert,
beide einzeln mit lipo -verify_arch arm64 geprüft. CLI meldet 0.41.14.
Genau ProductInfoTests: 5 ausgeführt, 0 übersprungen, 0 Fehler. Geprüft werden
Version/CFBundle 99, Dateitypregistrierung, ENEX-Aliasse, öffentliche Versions-/
Lizenzangaben. App niemals gestartet, aktiviert, installiert oder notarisiert;
keine Rosetta-/globaleCLI-/Applications-/Hostdesktop-/PreferencesDaemon-Nutzung.

Der bewährte bestehende Runner wurde nur für Snapshot/Frist/gezielten Umfang
angepasst. HOME/CFFIXED_USER_HOME/TMPDIR, SwiftPM-cache/config/security/scratch,
Modulcaches und Preferences waren ausschließlich privat; vorhandene bare
Repositories und Sparkle-Artefakte wurden nur lesend als Seeds kopiert.
Eigene prozessgebundene caffeinate wurde beendet. Keine Quelländerung am
Mac-Checkout, kein Git/Fetchen/Push und keine neuen Infrastrukturwege.

SourceTreeSHA256:
d9f405aea7cd3521c992a990eda53705ca4af0a396741c8eb437e5f4748c5949

CLI:
d4a7f86fb325683bece1909ed47d6465a0a03b1adbd27af278258b5ad45d3ff5

AppExecutable, nur gebaut:
a28ba2808ee0d86474d0d0d4373ee6e11119f14d7c868df645cf4de58fb25713

manifest.json bindet alle 337 übertragenen Dateien. Remote-Quellen vor/nach
hashgleich; auch die ausgewählten ursprünglichen Rootdateien blieben bis zum
abschließenden Vergleich identisch. evidence.json bindet Resultate und Grenzen.

Ein anfänglicher eigener lipo-Aufruf enthielt zwei Dateien und wurde abgewiesen;
kein Produktfehler. Danach dieselben bereits fertigen Executables einzeln
korrekt geprüft, kein unnötiger Neubau. Der Ergebnisexport verlangte zunächst
zusätzlich tests.xml, das dieser SwiftBuild-Lauf nicht erzeugte; das Export-Tar
enthielt trotzdem vollständig die angeforderten vorhandenen Logs. Die fünf
wirklich ausgeführten Tests sind namentlich im vollständigen tests.log belegt.
Bestehende Testtarget-Kompilation meldet Actor-Isolationswarnungen außerhalb der
gewählten ProductInfoTests sowie unzugeordnete Dateien; kein Testsuitefehler
oder Mac-Paritätsnachweis daraus abgeleitet. --skip-update ist als deprecated
markiert und wurde aus dem bewährten Runner beibehalten.

Bekannte 24-Task-OCR-Blockade und vollständige 1052-Test-Regressionssuite wurden
absichtlich nicht wiederholt. Dieser Abschluss belegt native Kompilierbarkeit
und finale Produktmetadaten; keine neue GUI-, vollständige Konverter- oder
Mac-Releaseabnahme. Historische .12-Nachweise bleiben separat.

cleanup.json: keine übrigen eigenen Prozesse, 9706 Dateien/2402 Verzeichnisse
am 2026-11-05T06:32:15Z über gehaltene Verzeichnisdeskriptoren und NoFollow entfernt.
Remote-Quellen/Build-/Profil-/Cachekopie vollständig weg; eigene lokale Upload-
und Exportarchive ebenfalls entfernt. Kleine Belege bleiben erhalten.
Logpfade wurden zu $WORK neutralisiert und ANSI-Farben entfernt; ursprüngliche
Rohhashes stehen separat in raw-log-hashes.json. SHA256SUMS bindet die portablen
Belegdateien. Runner-/Fortsetzung-/Cleanupskripte dokumentieren exakt diesen
begrenzten Lauf, sind auf den freigegebenen Snapshot und seine Frist gepinnt.

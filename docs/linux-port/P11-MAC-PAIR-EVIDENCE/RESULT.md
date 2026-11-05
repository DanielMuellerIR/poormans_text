# Nativer Mac-Paarvergleich 0.41.14

2026-11-05T07:20:30Z bis07:20:45Z, ausschließlich frisch gebautes arm64-CLI; keine App, keine Installation, keine Downloads. 337 aktuelle Quelldateien geprüft. CLI SHA256 cbbd6dcb0a505f8ce9d968f481885865dd843a9f9773e79d37922f087d688a6a. Native Umgebung und Buildprotokoll liegen bei.

Beide exakt gehashten Rasterinputs liefen mit `--json --report --source-map --ocr-method structured` und äußeren45s-Grenzen erfolgreich (0.539s/0.548s). Beide melden `ocr.structuredApplied`, kein Fallback. Quellen, CLI und sämtliche337 Quellfiles blieben unverändert. Bewahrte Originalassets sind bytegleich mit den Inputs.

Synthetik: Tabelle mit drei Spalten, leerer Markdown-Kopfzeile und drei Datenzeilen; acht nichtleere Zelltexte. Sieben von acht erwarteten Zelltexten stimmen exakt, `A1` wird zu `Al`. Die zusammengeführte Kopfzelle steht einmal links oben; der Kern meldet `ocr.tableSpansFlattened`. Kein verlustfreier Spannachweis.

Naturseite132: Alle neun erwarteten Tabellenzelltexte sind im Markdown vorhanden, jedoch als Absätze, ohne Markdown-Tabelle oder exportierte Zell-/Colspanstruktur. Außerdem unterbricht die Figure6.3-Beschriftung den Satz „behind-the-scenes experience“. `structuredApplied` belegt hier keine vollständige Tabellen-/Lesereihenfolgequalität. Keine allgemeine Qualitätsabnahme oder unbelegte Gleichheit mit Docling.

Unveränderte Markdownausgaben, Reports, CLI-JSON, stderr und Originalassets sind vollständig unter evidence/ gesichert; analysis.json enthält das knappe Text-/Tabelleninventar. Ausgangsreferenz ist die bereits vorliegende öffentliche DPBench-Annotation (Hash und Tabellen-HTML in analysis.json). Originalquellen/Herkunft siehe bestehende P11-Korpusbelege; keine neuen Fremddaten.

Isolation: eigener privater HOME/CFFIXED/TMP/Cache/Preferences; vorhandene SwiftPM-Seeds nur lesend als Kopiervorlage. Reproduktion: reproduction/mac_runner.py erwartet eine eigene /private/tmp/pmt-mac-p11-*-Wurzel mit source.tgz, manifest.json und beiden input/-Dateien, validiert Hashes und baut nur das CLI; die absolute Deadline ist bewusst auf den autorisierten Lauf fixiert. Kein zeitlich unbegrenzter Hintergrundauftrag. Für spätere Wiederholung ist die Deadline ausdrücklich neu festzulegen.

Cleanup: eigener M5/tmp-Baum vollständig über gebundene Directory-FDs/nofollow entfernt; zuvor keine eigenen Restprozesse. 6382 Dateien/2132 Verzeichnisse entfernt. Kleine lokale Belege bleiben; Quellarchiv und große lokale Zwischenstände werden entfernt. Dies ist ein Paarvergleich, keine Produktänderung.

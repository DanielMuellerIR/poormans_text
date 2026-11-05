# Produktnachweise 0.41.12

Stand: 2026-11-05. Swift bleibt der gemeinsame Kern; GTK4 ist die gemeinsame
reversible Entwicklungswahl. Dies ist eine geprüfte Entwicklungsvorschau,
keine vollständige Portierungs-, Desktop- oder Distributionsfreigabe.

## Artefakte und tatsächlich ausgeführte Prüfungen

Linux-CLI SHA256 `2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c`,
GTK SHA256 `918a8d2bdd3658a92494a1e278d3ac6b1c241fa9536f5a3dbf9f63638998f2ed`,
Core-/UI-Guard SHA256 `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`.
Die beiden Runtime-Manifeste binden Quellen und Artefakte. Ein bestandener
Teilnachweis wird hier nicht zur vollständigen Formatparität hochgestuft.

| Prüfung | Ergebnis und offene Grenze |
| --- | --- |
| Linux Swift-Tests | 348 ausgeführt, 9 übersprungen, 0 Fehler, 37,997 s. Der sonst bedingt übersprungene Missing-OCR-Test zusätzlich wirklich mit fehlendem Tool: 1/0/0. |
| Rust | 35 GTK- und 3 Bridge-Units; Clippy für alle Targets/Features mit `-D warnings` bestanden. 16 echte Bridge-Hosttests; interne Hilfseinstiege nicht doppelt gezählt. |
| [48 CLI-Neustarts](series.json) | 40 positive Jobs und 8 erwartete Fehler, 374/374 Fallprüfungen, 25,800 s; alle laufenden ELF-Hashes identisch. Quellen, Ausgabemanifeste, UTF8-Bereichsgrenzen und Prozess-Cleanup geprüft. |
| [Drei Paketformate](packages.json) | Debian, Arch und portables Tar unter umask 077: reguläre öffentliche Dateimodi, relocierte Unicodepfade und echte CSV-Konvertierung. Kollision 73 verändert kein Paket; Symlinkeltern abgewiesen. |
| [Arch/Wayland](arch-fastra/REPORT.md) | Regulär .11 installieren, .12 upgraden, entfernen; UID1000, kein Swift-SDK. CSV, 6 HEIC-, 15 Raster- und 12 PDF-Fälle; der verschlüsselte dreizehnte PDF-Fall separat am selben ELF bestanden (Host-qpdf erzeugt nur das Fixture, SDK-freier Arch führt das Produkt aus). Produktions-GTK unter privatem nativem Weston/Pixman tatsächlich bedient und visuell geprüft. |
| [Mint](mint/README.md) | Native relocierte Laufzeit ohne SDK: 20 CLI-Fälle, 114/114 Checks; Produktions-GTK mit Mint-GTK4.14.5 unter eigenem Xvfb/DBus bis Completed, visuell geprüft. Keine Paketinstallation oder Cinnamon-Abnahme. |
| [SourcePreview](preview/README.md) | 18 SDK-freie PDF-/Raster-/HEIC-Fälle plus 5 Fehler-/Timeout-/Cancel-Fälle. Unabhängig dekodierte PNGs, Bytezahlen, Hashes, Dimensionen, Metadatenentfernung und unveränderte Quellen. |
| [Clipboard/Quellvergleich](clipboard/README.md) | Neun Originalkodierungen, versiegelter FD statt benannter UI-Datei, private /dev read-only, echte Frame-/Textvergleiche und Closebarriere. Konkrete Quell-FDs nach Clear/Close 1→0 bei weiter offener Hauptapp; Fenster/Textur ebenfalls freigegeben. Diese GUI-Proben verwendeten den .12-Kandidaten, nicht sämtliche späteren OCR-Korrekturen. |
| [OCR-Fehler](ocr/README.md) | 11 finale echte CLI-Fälle: fehlendes Tool/Sprachen 69, kontrollierter I/O-Fehler 74, tatsächlicher Erkennungstimeout 124; acht Fehler ohne Veröffentlichung. OCR off bleibt nutzbar; leeres echtes OCR meldet kein falsches Applied. |
| [Native Mac-Regression](mac/README.md) | App und CLI nativ kompiliert, App nicht gestartet. Core-Restlauf 1052 Tests/9 Skips/0 Fehler, Portable 15/0/0, echte CSV-/DOCX-Manifestprüfungen. Bekannte unveränderte 24-Task-OCR-Blockade ausdrücklich ausgespart. |
| [PMT → Fastra](arch-fastra/REPORT.md) | Echter GIO-Button startet Fastra1.158.0 im neuen PID; vollständiger Editorpuffer, Unicode, Markdownbildlink und PNGhash passen. Frischer Neustart mit neuem Home/Display und vorher leerem Clipboard erneut erfolgreich. Kein Nachweis des Bildrenderers oder unabhängiger Fastra-Gitcommitbindung. |

Der Mac-Nachweis bindet den ausgewählten 509-Dateien-Snapshot mit SHA256
`7859118b1d27a37de1b4e7f6b9f9143545daec11f1ce8ce6e6f87c568e3f91b3`.
Nachher wurden ausschließlich vollständig Linux-bedingte OCR-Dateien geändert;
der Mac-Lauf wird nicht als Ausführung dieser späteren Linux-Zweige ausgegeben.
Die echte DTD-Regressionslücke wurde korrigiert und negativ mit DOCX geprüft.
Der anschließende XMLParser-SIGTRAP betraf die Delegate-Lebensdauer im Test und
wurde durch Halten des Delegates korrigiert.

Die erste neue Serie brach nach zwei Fällen ab: eine historische fest kodierte
Versionsassertion erwartete .10, und die zusätzliche Werkzeugsandbox blockierte
NETLINK_ROUTE vor Pandoc. Nach versionsbezogener Prüferkorrektur und regulärem
Hostlauf bestand eine neue vollständige Serie. Kein Produktfallback wurde dafür
eingebaut. Der Serienscript liest die erwartete Version aus dem gewählten Repo.

## Grenzen und nächste Freigabe

P03s reale volle ext4-, Zieltausch- und Runnerverlustnachweise bleiben gültig;
die hier unveränderte Dateipublikation wurde nicht durch eine Simulation ersetzt.
[P11/Docling](../P11-DOCLING.md) liefert einen belegten Strukturkandidaten, ist
aber noch nicht in das Produkt integriert. Strukturierte OCR bleibt unavailable.
Natürliche Scan-/Fotoqualität, vollständige RTFD-/PDF-Parität, echte KDE-/Cinnamon-
Bedienung samt Portalen/Drop/Clipboard/Skalierung, native Mint-Paketinstallation,
vollständige Consumer-Matrix und Distributionsprüfung bleiben offen. Eine
allgemeine Linux-Freigabe folgt aus diesen Teilprüfungen nicht.

## Reproduktion und Aufräumen

Die Unterordner enthalten kleine JSON-Belege, synthetische Fixtures und die
benutzten begrenzten Prüfer. Bereits vorhandene qualifizierte Images/Werkzeuge
müssen ausdrücklich gewählt werden; kein automatischer Download im Produkt.
Die ursprünglichen Kandidatenmanifeste bleiben als Herkunftsnachweis erhalten;
Binärdateien und Modelle gehören nicht in diesen Beleg. Die Kompilierpfadangabe
im finalen Bridge-Log wurde zu `$REPO` neutralisiert; dessen Rohhash im gelieferten
Manifest bezeichnet weiterhin das ursprüngliche Log.

Eigene Mac-/Mint-Testkopien sind entfernt; jeweilige Cleanup-Belege liegen bei.
Arch-/Fastra-Testcontainer und große Kopien sind ebenfalls entfernt, Originale
hashgleich. Temporäre laufende Testprofile lagen ausschließlich im eigenen Bereich.
Die native Mac-App wurde weder installiert noch gestartet. Kleine Belege bleiben
mit Prüfdatum erhalten; entbehrliche Rohbäume werden nach Sicherung entfernt.

Bei der Übernahme wurden reine Log-Leerzeichen/Leerzeilen neutralisiert; die
Herkunftsmanifeste bezeichnen die ursprünglichen Logs. Das erfolgreiche
PDF-Markdown im OCR-off-Beleg bleibt bytegetreu als `.md.gz` erhalten.

# Linux-RTFD: statische lokale Bildanhänge

Stand: 2026-11-05, Implementierung 0.41.13. Der Linuxpfad verwendet denselben
vorhandenen Rastervalidator wie Bildimporte, keine neue Decoderimplementierung.
Der native Macpfad und der gemeinsame abschließende HTML-/Assetwriter bleiben
unverändert. Bestandene Proben belegen den folgenden Umfang, keine vollständige
RTFD-/AppKit-Layoutparität.

## Verhalten und Schutzgrenzen

PNG, JPEG (jpg/jpeg), TIFF (tif/tiff), GIF, BMP, WebP und optional HEIC sind als
lokale Paketanhänge erlaubt. Tatsächlich dekodiertes Format und Dateiendung
müssen passen; genau ein Frame ist erforderlich. Mehrbildrige GIF/TIFF/APNG/WebP/
HEIC werden vor Veröffentlichung abgewiesen. Das bestehende libpng-Gate erkennt
acTL und reicht APNG an den vorhandenen vollständigen Rasterdecoder weiter;
kein bloßes Lesen des ersten Bildes ersetzt den Framecheck.

Die vorhandene FD-geprüfte private Paketkopie, Grenzen, sichere Verweise und
Platzhalter erhalten den Bildort zwischen den umliegenden Texten. Der gemeinsame
HTML-Schlussweg kopiert die unveränderten Originalbytes; Endungsaliases bleiben
bestehen, ihre Schreibweise wird wie bisher klein (`.JPEG`→`.jpeg`). Die Probe
prüft BEFORE/Bild/AFTER unabhängig und vergleicht Quell-/Asset-SHA256 und Bytes.
Das ist keine Behauptung geometrisch identischer Positionierung.

TIFF und HEIC erhalten `rtfd.viewerCompatibility`: manche Markdownviewer können
diese Originalformate nicht anzeigen; dieser RTFD-Pfad erzeugt keinen PNG-Ersatz.
Das allgemeine `rtfd.layoutNotPreserved` bleibt erhalten. Inline-pict, Objekte,
PDF-/Vektoranhänge und Mehrframes sind nicht freigegeben. Fehlender Decoder,
Abbruch, Timeout und Dateisystemfehler bleiben ihre eigenen Fehler und werden
nicht als beschädigtes RTFD verschluckt.

## Ausgeführte Kandidatenprüfungen

[Finaler BMP-Kandidat](P10-RTFD-STATIC-EVIDENCE/README.md): neun RTFD-Units,
0 Fehler; 23 echte CachyOS-CLI-Fälle einschließlich unabhängig erzeugtem BMP,
alle Erwartungen erfüllt. Alle Quellen bleiben bytegleich, alle negativen Fälle
ohne Ausgabe. [Einzelfälle und Sourcehashes](P10-RTFD-STATIC-EVIDENCE/evidence.json).
Der gezielte Vierdateienpatch hat SHA256
`3412da78decfaefbd2791e05908cbf1b70e5a9d619f6e4bf0903bb23f3ce9aa1`;
der Repoverlauf und die gehashten Quellen enthalten die integrierte Änderung.

Der [Kandidat vor BMP](P10-RTFD-STATIC-EVIDENCE/README-before-bmp.md) besteht
getrennt 24 CachyOS- und 24 SDK-freie Noble-Fälle: dort auch echtes statisches HEIC
mit Originalbyte-/Positions-/Diagnoseprüfung sowie zweibildriges HEIC 65. Fehlendes
Pillow 69, echter Timeout 124 und SIGTERM 130 während beobachtetem Python-inspect-
Worker veröffentlichen nichts; keine eigenen Restkinder. Diese 48 Läufe gehören
zu ihrem eigenen Binärhash und werden nicht als Wiederholung des späteren
BMP-Binarys ausgegeben. Die konsolidierte CLI-Probe hat ohne HEIC 23, mit beiden
optionalen HEIC-Fixtures 25 Fälle.

Die Kandidaten hatten 0.41.12-Versionstext; Root übernimmt vier gehashte Dateien
und versioniert die Produktintegration als 0.41.13. Die [finalen .13-Produktläufe](P16-04113/rtfd/README.md) bestehen 25/25 Fälle
im SDK-freien Noble am CLI 26470eaf… einschließlich BMP/HEIC; Quellen und Originalassets
bleiben gleich. Arch besteht dieselbe Matrix im regulär aktualisierten Paket. Keine Mac-, GUI- oder
universelle Viewerabnahme aus diesen CLI-Fällen abgeleitet.

Reproduktion: `scripts/linux-probes/p10-rtfd/verify_rtfd.py` mit expliziter CLI,
qualifiziertem Pandoc und neuem eigenem Root. Optionale `--heic-single` und
`--heic-multi` verwenden die synthetischen P09-Fixtures; keine Downloads.
Der kleine Kontrollprüfer verlangt dieselbe eigene Runtime und ein ausdrücklich
angegebenes Pandoc. Die eigenen Kandidaten-Source-/Runtime-/Cachekopien und
Container sind nach Sicherung der Belege entfernt; Cleanupbelege liegen bei.

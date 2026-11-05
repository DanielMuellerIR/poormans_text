# Produktnachweise 0.41.16

Stand: 2026-11-05. Swift bleibt der gemeinsame Kern. Diese Etappe integriert
RTFD-Textidentität und lokale GTK-Einstellungen sowie den streng typisierten,
noch inaktiven Docling-Parser. Sie aktiviert keine strukturierte OCR und ist
keine vollständige Linux-, Mint- oder Desktopfreigabe.

## Tatsächlich ausgeführte Prüfungen

- Gemeinsame/Linux-Regression: **369 Tests, 12 übersprungen, 0 Fehler** im
  SDK-freien Backend-Testimage, [Log](backend-units-04116.log.gz). Die getrennte
  [16-Fälle-Auswahl](units-04116.log.gz) besteht die 13 Parser- und drei echten
  RTFD-Identitätsfälle; diese Fälle sind Teil der Gesamtsumme, keine Zusatzsumme.
- GTK/Bridge: 40 und drei Unit-Tests bestehen; 18 externe Host-/Helperfälle
  bleiben ausdrücklich ignoriert. [Log](rust-04116-scoped.log.gz),
  [native Clippy-Prüfung](clippy-04116-scoped-final.log.gz): keine Warnungen.
- [Drei finale Pakete](packages.json) bestehen tatsächliche relocierte
  Unicode-CSV-Konvertierung, Hash-/Rechteprüfung, Kollision und Symlinkelternschutz.
  Sie wurden ausdrücklich mit umask077 gebaut. [Artefaktbindungen](artifacts.json).
  Das ist keine Installation auf Mint oder Desktopabnahme.
- [GUI-Buildschutz](gui-build-safety.json): neun Fälle/41 Prüfungen. Unbekannte
  oder veränderte Schemadateien bleiben erhalten; gültige eigene Schemata können
  sicher ersetzt werden. Kein globales GSettings-Schema wird installiert.
- Der gemeinsame Parser besteht die vollständige isolierte
  [Reproduktion](projection-results.json): vier Original-JSON-Fälle und 18
  Negativfälle. [Buildlog](projection-build.log.gz). Der binärgeprüfte gemeinsame
  Swift/C-Quellstand steht in [source-files.json](source-files.json).

## Produktverhalten und Grenzen

RTFD bindet ausschließlich die direkte reguläre TXT.rtf ohne Symlinks. Ein
geänderter Text wird erkannt; Anhänge sind ausdrücklich nicht durch diesen
Textfingerprint abgedeckt. Die GTK-Anzeige benennt diese Grenze. Das optionale
`memberPath=TXT.rtf` erweitert den bestehenden Vertrag ohne neue Protokollversion.

Gio.Settings speichert Fenstergeometrie, maximierten Zustand, Optionstab und
allgemeine Konvertierungsoptionen erst nach der bestehenden Abschlussbarriere.
Quell-/Zielpfade und quellbezogene Seiten-, Kapitel-, Blatt-, Zell- und
Folienauswahlen bleiben sitzungsgebunden. Fehlendes Schema oder nicht schreibbare
Einstellungen werden sichtbar gemeldet. Tatsächliche GUI-Belege stehen in
[gui](gui/); die isolierten Xvfb-Läufe ersetzen keine echte Desktopabnahme.

Die [abschließende GUI-Deltaprobe](gui/final-delta/evidence.json) besteht
alle fünf befüllten und nach Neustart leeren Quellauswahlen, weiter gespeicherte
allgemeine Optionen und das tatsächliche RTFD-Anhanglabel. Beide normalen
App-Abschlüsse liefern 0; die endgültigen UI-/Schema-/CLI-Hashes sind gebunden.

Die erste Paketquittung von 0.41.15 behauptete einen nicht aufgezeichneten
Build-umask077. Das Feld wurde korrigiert, nicht nachträglich behauptet. Die
seinerzeit tatsächlich geprüften öffentlichen Rechte bleiben belegt. Alte
Delivery-Prüfsummen sind neben neu korrekt relativ auflösbaren Summen erhalten.

Die [lokale isolierte DPKG-Lebenszyklusprobe](mint-scaffold-local/) besteht den
Ansatz mit schreibgeschütztem Host und eigener Paketdatenbank. Sie ist noch
keine native Mint-Probe. Native Mac-OCR-Regression, Mint und endgültige Desktop-
abnahme bleiben offen. Die unabhängige [Inhaltsqualität](../../CONVERSION-QUALITY.md)
bleibt wegen belegter natürlicher und modellbedingter Verluste FAIL.

Kleine Rohbelege bleiben zur Regression erhalten; Bildschirmbilder liegen
privat. Nächste Referenzprüfung: 2026-12-05. Entbehrliche eigene Testkopien und
Prozesse werden nach Sicherung entfernt; Entwicklungspakete bleiben bewusst lokal.

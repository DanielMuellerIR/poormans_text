# Linux-Produktprüfung 0.41.19

Stand 2026-11-05. Swift bleibt der gemeinsame Konvertierungskern. RTF-Hintergründe
bleiben jetzt als Hervorhebung erhalten; die optionale strukturierte OCR erhält
einen separat qualifizierten zweiten Wortleser. Fastras normaler Import benötigt
weiterhin keine Modelle. Eine vollständige Linux-Abnahme wird nicht behauptet.

## Produktänderungen

Der gemeinsame RTF-Pfad bewahrt `highlight`, `chcbpat` und `cb` über verschachtelte
Formatgruppen, `plain`, Unicode und Absatzwechsel. Er erzeugt `==Text==`;
bei wörtlichem `==` im Inhalt verwendet er konstantes `<mark>…</mark>` ohne
Attribute. Originalfarben werden abgeflacht und ausdrücklich diagnostiziert.
Interne Marker werden vollständig gebunden und nach der Konvertierung geprüft;
fehlende oder vervielfachte Marker verhindern die Veröffentlichung.

Die [echte finale CLI-Probe](rtf-product.json) ergibt exakt
`Plain **Bold** ==Marked== Ä`, bei unveränderter Quelle und geprüften
Ausgabefingerprints. Sieben neue portable Dokumenttests prüfen zusätzlich
Gruppenwechsel, mehrere Absätze, Quellbytes, Unicodepaare, maskierte Steuerwörter
und den sicheren Markup-Ausweichfall. Der Vertragsumfang bleibt unverändert;
`richText.highlightColorApproximation` ist eine zusätzliche Diagnose.

Die neue optionale Runtime bindet Manifest
`aab3d38bb01bfdb8e0e29df133b6bbf7848609842ab38d97a632631cdccbbdce`,
Adapter2, [30.994 Dateien mit 2.257.343.859 Bytes](runtime-candidate.json).
Der bisherige Adapter1-Pin bleibt zulässig. Der Installer akzeptiert nur die
expliziten Versionen1/2; der Swift-Kern bindet beide an ihren eigenen festen
Manifesthash. Alle Inhalte werden vor der Ausführung geprüft.

Der zusätzliche lokale Leser darf nur Wörter mit Modellscore mindestens0,99
ersetzen, deren Satzzeichen und Abstände identisch bleiben. Wortgeometrie und
ursprüngliche Tesseract-Konfidenz bleiben erhalten; der Score ist ausdrücklich
keine kalibrierte Fehlerwahrscheinlichkeit. Englisch und Deutsch sind qualifiziert;
andere gewählte Sprachen behalten Tesseract und erhalten eine Information.
Es gibt keinen Modell- oder Sprachdatendownload während einer Konvertierung.
[Quellpins und reproduzierbare Kontrollbilder](../../../scripts/linux-probes/p11/refinement/README.md).

## Bestandene Prüfungen und ihre Grenzen

- [Linux-Vollsuite](linux-units.log.gz): 392 registrierte Fälle, zwölf bestehende
  Skips, keine Fehler; tatsächlich als normaler Benutzer ohne Entwicklungs-SDK
  ausgeführt. Die sieben neuen RTF-Fälle sind enthalten.
- [Native Mac-Vollsuite](mac-units.log.gz): 1.092 registrierte Fälle in beiden
  Testbundles, neun bestehende Skips, keine Fehler. ARM64, macOS26.7.2,
  Swift6.4.2; kein Skipfilter. [Umgebung](mac-environment.log),
  [Quellenbindung und Ablauf](mac-result.json). Ein erster Lauf fand ausschließlich
  die veraltete Buildnummer102 im Produkttest; nach Anpassung an104 besteht der
  vollständige neue Lauf. Nach dieser Prüfung wurde nur der Linux-PDF-Rasterversuch
  verworfen; sämtliche geprüften Swift- und Testquellen blieben gleich.
- [Runtime-Installer](installer-tests.log): 38 Fälle bestanden, einschließlich
  expliziter Adapterversionen und unverändertem Ablehnen unbekannter Werte.
- [Vier finale Pakete](packages.json): DEB, Arch, Tar-Zstandard und ZIP bestehen
  Entpacken, Verschieben, Unicode-Konvertierung, Quell-/Ausgabefingerprints,
  Rechte, Kollision und Symlinkeltern. Optionale Modelle sind ausgeschlossen.
  [apt-/pacman-Zyklen](installers.json) bestehen reguläre Installation, echte
  nichtprivilegierte Konvertierung und Entfernung in eigenen netzlosen Containern.
- Finale Produktions-GUI unter privatem [Wayland](wayland.json) und X11:
  echte AT-SPI-Konvertierung, unveränderte Quelle, drei reale Portaldialoge
  geöffnet und abgebrochen. [DBus-Protokoll](portal.log), visuell geprüfte
  [Wayland-](wayland.png) und [X11-Aufnahme](x11.png). Kein Benutzerdisplay beteiligt.
- [13 finale PDF-Fälle](pdf-cases.json) und [15 Raster-/OCR-Fälle](raster-cases.json)
  prüfen die tatsächlichen Backends; die PDF-Matrix wurde nach Verwerfen des
  Auflösungsversuchs vollständig wiederholt.
- Die strenge synthetische Produktprobe besteht auf
  [Ubuntu](structured-ubuntu.json) und [Arch](structured-arch.json): acht von acht
  Zelltexten, vollständiger Absatzbestand und Reihenfolge, verbundene Zelle,
  Originalbild, Quellidentität und Ausgabefingerprints. Zuvor waren fünf von acht
  Zelltexten richtig. Dies ist eine begrenzte Inhaltsprobe.
- [Native Mint-Komponente](mint-component.json): dieselbe unveränderte Runtime,
  sämtliche Dateihashes geprüft, acht richtige Zelltexte, drei verfeinerte Wörter.
  Tesseract und Bibliotheken wurden nur temporär bereitgestellt. Das belegt die
  native Modellkomponente, keine vollständige CLI-Backendentdeckung oder Desktop-
  abnahme auf Mint. Der Hostpaketbestand blieb unverändert.
- [Echter Modellabbruch](model-cancellation.json): nach beendetem Tesseract-TSV-Lauf
  wurde der laufende Verfeinerungsworker abgebrochen. Alle20 beobachteten eigenen
  pidfds endeten; fremder Kontrollprozess blieb aktiv; Exit130, keine Ausgabe,
  keine Stagingreste, unveränderte Quelle.
- [Manipuliertes Modul](model-corrupted.json): gleicher Dateiumfang, anderer
  Inhalt; Exit69 vor Ausführung, kein Ergebnis. [Fehlende Runtime](model-missing.json)
  liefert ebenfalls69 ohne Veröffentlichung.
- [Sechs zusätzliche Kontrollbilder im echten Produkt](holdout-product.json):
  273 von294 Referenzwörtern richtig statt zuvor258. Keine zuvor richtige
  geprüfte Wortposition oder Tabellenzelle geht verloren. Vollständige
  Zeichenerkennung bleibt FAIL; beispielsweise `O0`/`I1` sind weiter mehrdeutig.
  Der Vergleich verwendet ausdrücklich dieselbe Sprachreihenfolge `eng,deu`;
  ein vorheriger Lauf mit umgekehrter Reihenfolge war kein gültiger Paarvergleich.

Die endgültigen CLI-, Guard-, GTK-, Ressourcen- und Schemahashes stehen in
[artifacts.json](artifacts.json). Der [vollständige Runtimebestand nach den
Produktläufen](runtime-after.json) blieb unverändert. Die aktuelle gemeinsame
Swift-Quelle entspricht dem nativen Mac-Snapshot:
[Dateibindung](mac-current-swift-binding.json).

## Qualitätsgrenze und verworfene Alternative

Die [Gesamtqualitätsmatrix](quality.json) bleibt **FAIL**. Zehn synthetische
Formatfamilien, Raster-/OCR- und PDF-Sicherheitsproben bestehen. Die festen
natürlichen PDF-Referenzen zeigen weiterhin verlorene Diagrammtexte und fehlende
Tabellenstruktur. Erfolgreiche Prozessausführung und bytegleiche Assets ersetzen
keine vollständige Inhaltserkennung.

Ein tatsächliches300-dpi-PDF-Raster verbesserte einzelne isolierte OCR-Wortbestände,
führte aber im wirklichen Produkt bei allen drei natürlichen PDFs zur sicheren
Ablehnung der räumlichen Zusammenführung mit digitalem Text. Der paarweise alte
Produktlauf verarbeitete sie. Deshalb ist300dpi **verworfen**, nicht integriert;
144dpi und sämtliche bestehenden Sicherheitsgrenzen bleiben erhalten.
Der [finale paarweise Produktvergleich](natural-comparison.json) besteht alle
sechs Läufe bei identischen Wortbeständen zum unveränderten0.41.17-Stand.
Gemischte digitale/OCR-Seiten behalten dabei ihren diagnostizierten
Standard-Zeilenrückfall. Die fehlenden Wörter und Tabellenstrukturen werden
ausdrücklich weiter als Qualitätsfehler geführt.

## Noch ausstehende Abnahme

Echte Benutzerdesktops, erfolgreiche Auswahl über die realen Desktopportale,
fremde Clipboard-/Drag-and-drop-Anbieter, HiDPI und die vollständige Mint-/CachyOS-
Matrix bleiben eigenständige Abnahmen. Die öffentliche Verteilung optionaler
Modelle braucht zusätzlich die vollständige Lizenz-/Quellangebotsprüfung.
Das Basisprodukt verteilt diese Modelle nicht. Es erfolgte kein GitHub-Push.

Die vier [Nacht-Review-Funde](../REVIEW-2026-11-05.md) bleiben einzeln geprüft und
im zuständigen Status erledigt. Die Änderungen dieses Berichts erzeugen keine
Freigabe der noch offenen Qualitäts- oder Desktopgrenzen.

Die beiden eigenen Mac-Testverzeichnisse und das eigene Mint-Testverzeichnis
wurden nach Sicherung der kleinen Belege vollständig entfernt:
[Mac](mac-cleanup.json), [Mint](mint-cleanup.json). Keine Hostinstallation und
kein Zugriff auf den Benutzerdesktop.

# Markdown-Vorschau

Die App öffnet über **Preview / Vorschau** eine eigene Ergebnisansicht. Sie kann
zwischen formatiertem Markdown und auswählbarem Quelltext wechseln. Die Suche
mit ⌘F, Eingabe und den Tasten für vorherigen/nächsten Treffer bleibt auf den
geladenen Ausschnitt beschränkt. **Fertig** oder Escape schließt die Ansicht.
Öffnen und Kopieren im Ergebnisbereich verwenden weiterhin die vollständige Datei.

Überschriften, Listen, Aufgabenmarkierungen, Hervorhebungen, Tabellen, Code,
Zitate und lokale Bilder werden dargestellt. Führende YAML-Dokumentangaben
erscheinen in einem aufklappbaren Bereich. Math- und andere nicht unterstützte
Erweiterungen bleiben Text. Raw HTML wird sichtbar als Text übernommen; nur
das einfache, vom Tabellenkonverter verwendete `<br>` wird als Umbruch behandelt.

## Begrenzte, lokale Darstellung

Der Leser übernimmt höchstens 256 KiB für die Anzeige. Ein abgeschnittenes
UTF-8-Endzeichen fällt aus dem Ausschnitt; die Datei selbst bleibt vollständig.
Parser und Renderer laufen im Hintergrund. Ihre Grenzen liegen bei 50.000
Knoten, Tiefe 64 und ungefähr 1 MiB erzeugtem HTML. Eine Begrenzung ist in der
Ansicht sichtbar. Ein Ergebniswechsel oder Schließen verwirft ausstehende
Lese- und Rendering-Ergebnisse.

Swift Markdown 0.8.0 und der in `Package.resolved` fixierte Swift CMark 0.9.0
parsen die Struktur. Ein eigener Renderer maskiert Text und Attribute; der
allgemeine HTML-Formatter des Pakets wird nicht zum Anzeigen fremder Inhalte
verwendet. Seine Quellpositionen sind UTF-8-basiert, wie in der
[Parser-Schnittstelle](https://github.com/swiftlang/swift-markdown/blob/0.8.0/Sources/Markdown/Infrastructure/SourceLocation.swift)
dokumentiert. Die Drittanbieterhinweise liegen als `Markdown-LICENSES.txt` im Bundle.

WebKit verwendet einen flüchtigen Datenspeicher, deaktiviertes
[Inhalts-JavaScript](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)
und eine Content Security Policy ohne entfernte Ressourcen. Links sind in
dieser Vorschau nicht aktiv. Die Navigationssperre akzeptiert ausschließlich das
intern erzeugte Dokument. Suche und Ankersprünge verwenden eigene WebKit-Aufrufe;
keine Skripte aus dem Quelldokument werden ausgeführt.

## Bilder und Pfade

Ein Bildziel muss genau einem registrierten Ergebnis-Asset entsprechen. Das
Ziel wird einmal dekodiert und auf relative, sichere Komponenten geprüft.
Die Bildanforderung enthält danach nur eine zufällige Vorschaukennung und eine
Assetnummer. Pfade aus Browseranforderungen werden nicht als Dateipfade geöffnet.

Ein gehaltener Ergebnisordner und `openat` ohne Symlink-Verfolgung binden jeden
Pfadbestandteil. Auch Hardlinks, FIFOs, fremde Vorschaukennungen und übergroße
Dateien werden abgewiesen. Vor dem Dekodieren muss eine Rasterbildsignatur
vorliegen; SVG wird nicht geöffnet. Es gelten 16 MiB Quelle je Bild,
64 Millionen Quellpixel, höchstens 2.048 Pixel Vorschaukante und 64 MiB
gespeicherte Vorschaubilder. Höchstens 64 unterschiedliche Bilder werden im
geladenen Ausschnitt eingebunden. Bei mehrteiligen Bildern zeigt das Thumbnail
den ersten Frame. Fehlende oder nicht darstellbare Bilder werden sichtbar gemeldet.
Originalbilder werden nicht verändert.

## Bekannte Ergebnisstellen

Bei einem vorhandenen [Ausgabemanifest](CONVERSION-REPORT.md) kann der Leser
denselben Byte-Strom prüfen, aus dem der angezeigte Ausschnitt stammt. Eine
geänderte Datei erhält keine bestätigten Sprungpositionen. Der Renderer ordnet
bekannte Bereiche ihren tatsächlich dargestellten Elementen zu; unvollständig
dargestellte Elemente behalten keinen behaupteten Anker. Bereiche außerhalb
des Ausschnitts bleiben als nicht verfügbar erkennbar.

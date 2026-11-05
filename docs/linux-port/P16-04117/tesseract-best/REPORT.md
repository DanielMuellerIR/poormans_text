# Tesseract best: kein Modellwechsel empfohlen

2026-11-05. Die offiziellen Bestmodelle beheben die bekannten A1/B1/C1-Tabellenfehler nicht. Ein kleiner Gewinn auf Naturseite132 steht zusätzlichen Diagrammfehlern auf134 gegenüber. Die gemischte deutsche/englische Standard-OCR verbessert sich nicht und wird hier langsamer/speicherhungriger. **Keine Integration und kein Defaultwechsel.** Die bestehende allgemeine Qualitätsgrenze bleibt offen.

## Primärpins und Downloadbudget

Die [offiziellen Tesseractdaten-Dokumente](https://tesseract-ocr.github.io/tessdoc/Data-Files.html) beschreiben best als größere Float-LSTMmodelle mit einem Genauigkeits-/Geschwindigkeitstausch. Sie unterstützen keinen Legacy-OEM0/2. Hier blieben Enginebinary und dessen bisherige automatische Enginewahl unverändert; es wurde kein OEM-/PSMwechsel vorgenommen.

Offizielles Repository tessdata_best, fester Commit [e12c65a915945e4c28e237a9b52bc4a8f39a0cec](https://github.com/tesseract-ocr/tessdata_best/tree/e12c65a915945e4c28e237a9b52bc4a8f39a0cec), Apache2.0 laut beigefügtem unverändertem LICENSE.

| Modell | Bytes | SHA256 |
|---|---:|---|
| eng |15400601|8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba|
| deu |8628461|8407331d6aa0229dc927685c01a7938fc5a641d1a9524f74838cdac599f0d06e|

Metadaten wurden zuerst gelesen, Dateigrößen gegen den125MiB-Cap geprüft, Downloads dann gegen exakte Bytes, offiziellen Gitblob-SHA1 und selbst berechneten SHA256 geprüft. Gespeicherte tatsächliche HTTPnutzdaten einschließlich API/LICENSE/README: **24045771Bytes**. Mit Roots948632735Bytes einschließlich dessen10MiB-Reserve: **972678506Bytes**, unter1073741824Bytes. Keine weiteren Modell-/Engine-/SDKdownloads.

Docling ruft OSD auch bei ausdrücklich ausgewählten Sprachen auf. Deshalb wurden ausschließlich das vorhandene Noble-osd und TSVconfigs bytegleich in den privaten Testprefix kopiert, ohne Netzwerkdownload. Dieses osd ist identisch zur Basis. Keine Systemmodelle, Arch-/Nobleinstallation oder qualifizierte Candidate-Datei wurden geändert. Die privaten Daten samt Kopien umfassen34595263Bytes, ebenfalls unter125MiB.

## Ausgeführter Vergleich

Genau derselbe gebündelte Produktworker mit AS4GiB, CPU120s, Offline-/zwei-Thread-Einstellungen, denselben Docling-/Heron-/TableFormer-Pins, demselben FULL_PAGE-Modus und unveränderten Erkennungsoptionen. Einziger Modellunterschied: im Kindprozess gesetztes TESSDATA_PREFIX auf explizit read-only gebundene Bestdaten. Kein ROI, keine neue Dichte, kein Schwellwert und keine Groundtruthkorrektur.

Sechs unveränderte Quellen: e37ca92…structured300dpi, dessen dpi-freie Kontrolle, natürliche132/134/135 sowie das vorhandene deutsche/englische OCRfixture. Zunächst wurden die exakten Original-PNGs verglichen. Danach wurde die vollständige kleine Matrix zusätzlich auf ihren tatsächlichen generischen Produktframes mit dem unveränderten DPI-Fix abgesichert. Pixel-/DPIgleichheit und Original-/Framehashes sind in production/inputs.json gebunden. Standard-OCR wurde ergänzend sowohl am Original als auch am bisherigen dpi-freien Standardframe mit dessen unverändertem PSM1 geprüft.

**24 tatsächliche Modellaufrufe und4 Standardaufrufe bestanden. Alle28 JSON-/TSVausgaben bestanden den aktuellen gehärteten Produktparser/Renderer beziehungsweise LinuxOCR-TSVparser; das vollständige Modellinventar blieb erhalten.** Das ist ein Komponentenaustauschtest über Produktworker/Normalizer/Core, keine neue GUI-/Installerfreigabe. Der Runtimepfad wechselte zwischen den beiden Matrices nach Roots verifiziertem Cleanup auf den identischen SSDbestand. Ein gestarteter Zwischenversuch fand den entfernten alten Pfad nicht; er wurde ohne Modelllauf am benannten SSDpfad wiederholt. Keine neue Runtimequalifikation wird daraus abgeleitet.

## Qualität in beide Richtungen

Metrik: unveränderte unabhängige Tabellenreferenzen und DP-Benchannotation; Wortinventar mit NFC, Unicodew+ und casefold, exakten Häufigkeiten. Keine Akzentkorrektur, Dehyphenierung oder Buchstabenreparatur. Rohdiffs und vollständige Fehlerlisten liegen bei. Original- und Produktionsframematrix ergeben dieselben folgenden Qualitätsmetriken.

| Fall | Basis → best |
|---|---|
| Synthetisch300dpi |5/8Zelltexte,8/8Spannen unverändert; A1/B1/C1 bleiben Al/Bl/Cl.3fehlende/3zusätzliche Wörter in beiden Varianten. |
| Nodpi-Kontrolle |1/8Zelltexte,4/8Spannen unverändert; weiterhin2statt3Spalten.3fehlende/3zusätzliche Wörter in beiden Varianten. |
| Natur132 |Tabelle9/9Texte und9/9Spannen in beiden Varianten. Fehlende Wörter22→21, zusätzliche2→1: ein a kehrt zurück, ein falsches a_ verschwindet. |
| Diagramm134 |Keine falsche Tabelle in beiden Varianten. Fehlende Wörter16→18, zusätzliche10→11.120 und lbs werden besser erkannt;10/40/50/80 gehen zusätzlich verloren, neue Fehllabels kommen hinzu. Gemischt, netto schlechter. |
| Negativseite135 |Weiterhin keine falsche Tabelle.1fehlendes/0zusätzliche Wörter unverändert. |
| Gemischtes OCRfixture |0fehlende/0zusätzliche Wörter unverändert, sowohl strukturierter Worker als auch Standard-OCR. |

Der kleine positive132-Diff wird nicht verschwiegen. Er rechtfertigt zusammen mit der Regression auf134 und unveränderten Hauptproblemen keinen allgemeinen Wechsel.

## Zeit und Speicher

Produktionsframes, eine feste gepaarte Reihenfolge Basis→best, keine statistische Benchmarkbehauptung:

| Fall | Sekunden Basis → best |
|---|---:|
| structured |19.26→17.88|
| nodpi |22.48→22.61|
|132|20.66→21.78|
|134|18.10→18.77|
|135|20.38→22.21|
| mixed structured |17.48→17.14|
| mixed Standard |0.87→1.20|

Beim Standard-Tesseractprozess steigt VmHWM102844→118932KiB ohne Textgewinn. Alle Modellprozessprofile (VmPeak/Size/HWM/RSS) liegen in den Runs. Der Modellprozess blieb unter AS4GiB. Die zusätzlich äußere Dockergrenze RAM4GiB ist keine Produkt-RAMgrenze; die gemessene Modell-RSS umfasst nicht automatisch sämtliche Tesseractnachkommen. Standardtesseract wurde deshalb separat erfasst. Zeiten können durch Wärme-/Reihenfolge-/Lastunterschiede schwanken; aus kleinen negativen oder positiven Zeitdifferenzen wird kein allgemeiner Geschwindigkeitsanspruch abgeleitet.

## Stand und Aufbewahrung

Kein Repo-, Default-, Runtime-Manifest- oder Candidatewrite. Digest cd4673de… bleibt separat und unverändert. Keine Bestmodelle wurden in den Candidate aufgenommen. Die alte DPI-Lieferung blieb stabil.

Große eigene Checker-/Arbeitskopien werden nach der kleinen Lieferung entfernt. Die exakt heruntergeladenen privaten Modelldaten bleiben für begrenzte Reproduktion im benachbarten models/-Ordner erhalten; sie vermeiden einen weiteren Download im gemeinsamen Budget. Zweck: Nachprüfung dieser verworfenen Variante, nicht Produktintegration. Nächste Prüfung2026-12-05; nach Abnahme entbehrliche Modelldaten spätestens30Tage später entfernen. Root allein entscheidet über weitere Produktarbeit; dieser Versuch ist abgeschlossen.

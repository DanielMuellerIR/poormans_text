# P11 – begrenzte Qualitätsvorprobe ohne neue Modellgewichte

2026-11-04. Ergebnis: **P11 nicht bestanden; keine Produktintegration.**
Die vorhandenen lokalen Werkzeuge belegen keine Gleichwertigkeit mit dem
strukturierten Mac-Pfad. Das ist ein begründeter Abbruch des kurzen Ansatzes,
kein Beweis, dass klassische Verfahren prinzipiell unmöglich sind.

## Vorhandene Mittel und Vergleichsbasis

Tesseract 5.5.4 / Leptonica 1.87.0, vorhandene eng/deu/osd-Daten, Pillow 13.0.0,
NumPy 2.5.4 und ImageMagick sind nutzbar. OpenCV, SciPy, scikit-image,
Layoutparser und zusätzliche OCR-/Layoutmodelle sind nicht vorhanden. Es wurde
nichts installiert und keine Modell- oder Sprachdatei heruntergeladen.

Der unveränderte strukturierte Rasterpräfix aus
`scripts/linux-probes/backends/extra-probe.py` wurde erneut erzeugt:
`fixtures/structured.png`, 1800×1600 Pixel, SHA256
`e37ca92cf5b8ad22e228eed1c1065177bbbdc6b865b9e027965660353f934369`.
Font: DejaVuSans aus dem vorhandenen P04-Pfad. GroundTruth der synthetischen
Geometrie/Texte stammt direkt aus dessen Zeichenbefehlen.

Die damaligen Roh-Macoutputs wurden nach der Verdichtung entfernt.
`docs/linux-port/P04-EVIDENCE/mac-summary.json` enthält nur Status, Laufzeit,
Assetanzahl und Diagnosecodes. Daraus dürfen weder konkrete Zellen noch
Lesereihenfolge/Spannen des Mac-Ergebnisses rekonstruiert werden. Ein gespeicherter
Hash der damaligen strukturierten Mac-Quelldatei liegt hier ebenfalls nicht vor.
Es gibt somit keinen neu bestandenen gepaarten Mac-/Linux-Inhaltsvergleich.

## Tatsächlicher klassischer Versuch

Ein kleiner eigenständiger NumPy-Prototyp erkennt lange horizontale/vertikale
Linien und liest daraus Zellen einschließlich fehlender innerer Trennlinien.
Tesseract liest die begrenzten Zellbilder vollständig; es gibt keine Korrektur
von A1/Al anhand der erwarteten GroundTruth.

| Eigenschaft | Ergebnis |
| --- | --- |
| Unverändertes P04-Gitter | Vier horizontale/vier vertikale Linien, drei Zeilen/drei Spaltenpositionen; acht eindeutige Zellen erkannt. |
| Horizontale Spanne | Verbundener Header in Zeile 0 über Spalten 0–1 korrekt erkannt; keine doppelte Headerübernahme. |
| Zelltexte | Nur 6 von 8 exakt: A1 wird Al, B1 wird Bl. |
| Volltextbestand | 31 Wörter erwartet und 31 erkannt, aber zwei Substitutionen: A1/B1 fehlen, Al/Bl kommen hinzu. Bloße Wortzählung wäre hier irreführend. |
| Lesereihenfolge ohne Eingriff | ALPHA, GAMMA, BETA, DELTA; Spalten werden weiter zeilenweise vermischt. |
| Lesereihenfolge mit manueller Vorgabe | ALPHA, BETA, GAMMA, DELTA nach explizit vorgegebenem oberen Textbereich und Trennung bei x=900. Kein Nachweis automatischer Seitensegmentierung. |
| Zwei Grad Rotation | Naiver Projektions-Linienfinder erkennt kein Gitter. Vorhandenes ImageMagick-Deskew stellt die acht Zellgeometrien wieder her; danach wurde keine neue Textgleichheit behauptet. |
| Dasselbe Dokument ohne Gitterlinien | Null erkannte Tabellenzellen. BBox-Spalten allein liefern noch keine belastbare Tabellen-/Spansemantik. |
| Verlustdiagnosen | Nur der Prüfvergleich benennt die Fehler. Ein produktiver mehrdeutigkeits- und verlustbewusster Fallback ist nicht implementiert. |

Vertikale Spannen, komplexe leere Zellen, automatische Abgrenzung von Textspalten
gegen Tabellen, verschachtelte Listen und ein natürliches Foto-/Scanlayout sind
damit nicht abgenommen. Die synthetische Farbgrafik im P04-Raster ist kein
natürliches Kamerafoto. Der Prototyp ist kein vorgeschlagener Produktadapter.

## Natürliche Referenz und Quellenprüfung

Lokal liegt kein natürliches Dokument mit vorhandener Zell-/Span-/Reihenfolge-
GroundTruth und klarer Weitergabebasis für diese Aufgabe vor. Die offiziellen
PubTables-1M-Quellen beschreiben zwar detaillierte Zellen-/Wort-/Boxannotationen
für wissenschaftliche Dokumente; die Datenkarte nennt CDLA-Permissive-2.0.
Der offizielle Downloadweg bietet jedoch Archive, darunter 2,69 GB Testbilder,
4,17 GB Tabellenwörter und 3,7 GB vollständige PDF-Annotationen. Im kurzen Versuch
wurde kein einzelnes natürliches Bild mit sicher zugehöriger vollständiger
GroundTruth ausgewählt oder heruntergeladen. Weder eine allgemeine Repository-Lizenz
noch ein Beispielbild ohne Annotationspaar gelten als bestandener Nachweis.

Primärquellen, gelesen am 2026-11-04:

- [Offizielle PubTables-1M-Beschreibung](https://github.com/microsoft/table-transformer)
- [Datenkarte und Lizenzangabe](https://huggingface.co/datasets/bsmock/pubtables-1m/blob/main/README.md)
- [Offizielle Archivübersicht](https://huggingface.co/datasets/bsmock/pubtables-1m/tree/main)

Es gab keinen Download von Dokument-/Bildkorpora, keine private Übertragung und
keine Modellinstallation. Nur die öffentlichen Beschreibungsseiten wurden gelesen.

## Entscheidung und nächster zulässiger Schritt

P11 bleibt offen/unverfügbar; die normale Tesseract-OCR darf weiterhin mit ihren
bereits bekannten Grenzen angeboten werden. Aus dieser Vorprobe keinen
strukturierten Linuxmodus freischalten und keine Gleichwertigkeit ableiten.

Eine nächste Qualitätsrunde braucht zuerst einen kleinen festgelegten Korpus:
Original-P04-Pixel plus mehrere reale lizenzierte Dokumente mit vollständigen
Text-/Zell-/Spannen-/Reihenfolgeannotationen. Für denselben Bytebestand Mac-
Markdown und strukturierte Zwischenmodelle erneut sichern. Danach automatische
Segmentierung, leere/verbundene Zellen und einen verlustbewussten Rückfall messen.
Die Wahl weiterer Engines oder neuer Modellgewichte ist eine eigene spätere
Entscheidung; dieser Auftrag autorisiert dafür keine Installation.

Belege: results.json, probe.py und outputs/whole.txt/whole.tsv. Die gesamte
klassische Probe lief in rund 4,3 Sekunden; das ist eine einzelne kleine
Machbarkeitsmessung, keine Performancezusage. Für den nächsten Mac-Lauf ist
`fixtures/structured.png` bewusst erhalten; übrige entbehrliche Crop-/Varianten-
Dateien können nach Übernahme der Belege entfernt werden.

Reproduktion: `bash scripts/linux-probes/p11/regenerate_fixture.sh REPO NEUER_PROBENORDNER`, danach `python3 scripts/linux-probes/p11/probe.py --root PROBENORDNER`. Der Ordner muss neu sein; es werden ausschließlich die bestehenden lokalen Werkzeuge und synthetische P04-Fixtures verwendet.


## Fortsetzung 2026-11-05: natürlicher Startkorpus

Inzwischen sind drei natürliche Vollseiten mit revisionsfesten Originalannotationen
und dokumentbezogen belegten Buch-/Bildlizenzen verfügbar. Das ergänzt den oben
beschriebenen früheren Stand; die damalige Aussage zum fehlenden Korpus ist kein
aktueller Blocker mehr. [Korpus und Reproduktion](P11-NATURAL-EVIDENCE/CORPUS.md),
[Attributionen](P11-NATURAL-EVIDENCE/ATTRIBUTION.md) und
[separate Vorher-/Nachhermessung](P11-NATURAL-EVIDENCE/RESULTS.md) sind erhalten.

Sechs finale Produktläufe prüfen drei Seiten mit OCR off bzw. always/standard/en.
Quellen und alle 14 Ausgabehashes stimmen. Der Korpus deckte zwei verklebte
Wortgrenzen auf; deren Linux-Korrektur ist jetzt integriert und zusätzlich mit
einem unveränderten öffentlichen PDF als dauerhafter Konverterregression geprüft.
Neun statt vorher fünf Tabellenzelltexte besitzen wieder abgegrenzte Tokenfolgen.
Dies erhält weder Tabellenstruktur/colspan noch die weiterhin teilweise falsche
Reihenfolge. Diagramm-OCR erzeugt weiterhin erkennbare Fehler. Kein neuer
strukturierter Backendpfad und keine P11- oder Mac-Paritätsabnahme folgen daraus.

## Weiterer fest gepinnter Modellversuch

Die anschließende [CPU-/Offline-TATR-Probe](P11-TATR-DECISION.md) ist technisch
ausführbar, scheitert jedoch an natürlicher Kopfzelle/Span, einem FalsePositive
und synthetischer Zellrekonstruktion. Das ist ein belegter weiterer Ausschluss,
keine Produktintegration oder pauschale Aussage über andere Modelle.

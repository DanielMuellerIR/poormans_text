# P11: belegter Anschluss an den Swift-Kern

Stand: 2026-11-05. Der vorhandene Swift-Kern bleibt geeignet: Seine Foundation-
Modelle und `StructuredOCRRendering` lassen sich auf Linux unverändert für
Docling-Erkennungsdaten verwenden. Die folgende Probe ist eine wiederverwendbare
Parserprojektion, **keine Produktintegration oder Freigabe strukturierter OCR**.

| Gespeichertes Erkennungs-JSON | Rohe Zellen | Ergebnis der unveränderten Swift-Renderprüfung |
| --- | ---: | --- |
| Naturseite 132 digital | 9 | Zell-, Footer- und Captioninventar vollständig; Spanheader einmal. |
| Dieselbe Seite als 144-DPI-Raster | 9 | Gleiches Inventartor bestanden; kein unabhängiger natürlicher Scan. |
| Naturseite 135 | 0 | Footer und sämtliche Originaltexttokens erhalten. |
| Synthetisches Raster | 8 | Originale Provenance-Fragmente getrennt projiziert; inventartreu einschließlich unverändert falscher Al/Bl/Cl-Texte. |

Alle vier gespeicherten JSONs passieren den bestehenden Renderer. 18 gezielt
beschädigte Varianten werden kontrolliert abgewiesen. Die Auswertung vergleicht
UTF8-Tokenbytes samt Häufigkeiten unabhängig mit den rohen `orig`-/Zelltextarrays;
`grid`, alternative `text`-Felder und Caption-Aliase werden nicht zusätzlich
gezählt. Bilder sind nur inventarisiert, nicht als Assets exportiert. Die
vorhandenen Modelle verlangen keine Confidence; es wird kein Score erfunden.

Der erste eingefrorene Stand verwarf das synthetische Dokument korrekt: Ein
Textknoten besitzt drei räumlich getrennte Provenance-Fragmente. Die finale
Projektion verwendet exakt deren ursprüngliche Charspans und BBoxen, ohne Union-
BBox, manuelle Region oder Schwellenkorrektur. Unicode-Codepoints werden als
Swift-UnicodeScalars adressiert; ein Kontrollstring mit Akzent/Emoji/kombinierendem
Zeichen belegt 4 Scalars/3 Grapheme/5 UTF16/9 UTF8. Mehrdeutige Textbasis, überlappende
oder lückenhaft nichtweiße Spans bleiben Fehler. Weitere Grenzen: exaktes Schema,
eine Seite, 8 MiB JSON, 10000 Knoten, Tiefe 32, 4096 Tabellenslots und 256 Spalten.
Vollständige Grenzen und Einzelfälle: [Originalbericht](P11-SWIFT-PROJECTION-EVIDENCE/README.de.md),
[Ergebnisse](P11-SWIFT-PROJECTION-EVIDENCE/results-final.json),
[Probesource/Reproduktion](../../scripts/linux-probes/p11/docling/swift-projection/README.md).
Der tatsächliche Build/Lauf ist belegt; das konsolidierte Reproscript wurde nur
zusätzlich mit `--prepare-only` geprüft, nicht als zweiter Vollbuild ausgegeben.

## Frischer Mac-Paarvergleich derselben Pixel

Die früher fehlenden unveränderten Mac-Ausgaben sind nun neu gesichert:
[Bericht](P11-MAC-PAIR-EVIDENCE/RESULT.md),[Analyse](P11-MAC-PAIR-EVIDENCE/analysis.json).
Aktuelle 0.41.14-CLI nativ arm64/macOS 26.7.2; beide exakt gehashten Pixelinputs
melden tatsächlich `ocr.structuredApplied` mit Exit 0, ohne Timeout/Fallback.

- Synthetisch 7/8 Zelltexte exakt, A1→Al; die erkannte zusammengeführte Kopfzelle
  wird mit ausdrücklichem `ocr.tableSpansFlattened` abgeflacht.
- Auf Naturseite 132 sind 9/9 erwartete Zelltexte als Prosa vorhanden, aber keine
  exportierte Tabelle/Colspanstruktur. Die Bildcaption unterbricht einen Satz.

Diese zwei Fälle belegen keine generelle Qualität oder vollständige Parität.
Sie zeigen insbesondere, dass das Applied-Signal und der Vergleich allein mit
dem Mac-Output kein ausreichendes Qualitätstor sind. Der Docling-Kandidat besitzt
hier bessere natürliche Tabellenstruktur, aber nur 5/8 synthetische Zelltexte;
beide Ergebnisse benötigen unabhängige Text-/Zell-/Reihenfolge-Referenzen.
Rohmarkdown, Reports, Originalassets und Eingabebytes bleiben unverändert erhalten.
Der eigene Mac-Testbaum und alle Prozesse sind entfernt; kein Appstart/Install.

## Entscheidung

Den nächsten P11-Produktadapter auf **typisierte Erkennungsdaten → bestehende
Swift-Modelle/Renderer** ausrichten. Doclings Markdownexport ersetzt den
vorhandenen PDF-/Assetpfad nicht. Die damalige 317/339-Wortmessung bewertete die
`text`-Sicht; die neue Projektion benutzt autoritative `orig`-Textdaten. Diese
Sichten sind nicht addierbar und ihre Inventartreue ist keine nachträglich
bestandene Erkennungsqualität gegen das Originaldokument.

Vor Freischaltung fehlen weiterhin Source-Snapshotbindung, Mehrseiten-/Asset-
Integration, sichere Offline-Modell-/Prozess-/Speicherpaketierung, vollständige
Lizenz-/Updateprüfung und ein breiterer Korpus natürlicher Scans/Fotos mit
begründeten Verlust-/Fallbackregeln. Der Text-/Spanadapter und der Mac-Paarvergleich
schließen wichtige Entscheidungsnachweise, nicht diese Produktaufgaben. Die
Produkt-CLI meldet strukturierte Linux-OCR weiterhin kontrolliert als unavailable.

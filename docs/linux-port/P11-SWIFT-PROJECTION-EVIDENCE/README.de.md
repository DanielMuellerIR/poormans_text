# P11: isolierte Docling-JSON-Projektion, 2026-11-05

Ergebnis: 4/4 gespeicherte Erkennungs-JSONs passieren die Projektion und den unveränderten `StructuredOCRRendering`-Renderer; 18/18 gezielt beschädigte Varianten werden kontrolliert zurückgewiesen. Dies ist ein Parser-/Projektionsnachweis, keine P11-Produktfreigabe und kein neuer Erkennungsqualitätsnachweis. Produktquellen und verfügbare Produktmodi wurden nicht geändert.

| Autoritatives JSON | rohe Zellen | Textknoten → Provenance-Fragmente | Footer | Captions |
| --- | ---: | ---: | ---: | ---: |
| natürliche 132 digital | 9 | 7 → 7 | 1 | 2 |
| natürliche 132 gerastert | 9 | 9 → 9 | 2 | 3 |
| natürliche 135 | 0 | 4 → 4 | 1 | 0 |
| synthetisch structured | 8 | 5 → 7 | 0 | 0 |

Die unabhängige Auswertung liest `texts[].orig` und `tables[].data.table_cells[].text` unmittelbar über JSONSerialization. Sie zählt weder `grid` noch `text` zusätzlich zu `orig`, noch Caption-Aliasreferenzen ein zweites Mal. Der bestehende Renderer stimmt in allen vier Fällen mit diesem Inventar überein; zusätzlich stimmen die UTF8-Bytes jedes durch Leerraum getrennten Tokens samt Häufigkeit überein. Das ist ein Inventarnachweis, kein unabhängiger Nachweis der Lesereihenfolge oder vollständiger Markdown-Formatsemantik. Die neun natürlichen Zellen und acht synthetischen Spans bleiben jeweils einmal im bestehenden Tabellenmodell; ein Spanheader erscheint im Markdown einmal. Der Renderer meldet die Abflachung der Spans ausdrücklich. Synthetische Erkennungsfehler wie Al/Bl/Cl werden nicht korrigiert.

Die Foundation-Modelle `StructuredDocumentRecognition` und der Renderer verlangen keine Confidence. Es wird kein Score eingefügt oder eine fehlende Erkennungsconfidence als 1.0 dargestellt. Zellparagraphen sind eine notwendige abgeleitete Textsicht derselben rohen Zellen, keine zweite Erkennung und kein Qualitätsbeleg. Es gibt keine zusätzliche Konverter-IR: Nur private Decodable-DTOs und Prüfbelege stehen vor den bestehenden Core-Modellen.

## Provenance und strenge Grenzen

Der eingefrorene erste Stand in `results-before-fragments.json` besteht für drei natürliche Dokumente und weist das synthetische Dokument mit drei Provenance-Rechtecken eines Textknotens ab. Die finale Fassung projiziert exakt dessen ursprüngliche Charspans und Rechtecke einzeln. Sie vereinigt keine BBoxen und repariert weder ROI noch Schwellenwerte. Mehrfachfragmente verlangen bytegleiches orig/text. Bei verschiedenem orig/text ist nur ein vollständiger orig-Span erlaubt, dessen Ende außerhalb des kürzeren text liegt und die orig-Bezugsbasis damit eindeutig bestimmt; das bewahrt den Original-Listenmarker von 135. Unbekannte Bezugsbasis, überlappende/ungeordnete Spans und nichtweißer unbedeckter Text führen zum Fehler.

Python-Codepoints und Swift-UnicodeScalars wurden am unveränderten Kontrollstring `é🙂e◌́` mit tatsächlichem kombinierendem U+0301 geprüft: 4 Scalars, 3 Grapheme, 5 UTF16-Einheiten, 9 UTF8-Bytes. Alle drei Fragmente sind bytegleich; eine kanonisch äquivalente, aber byteverschiedene Alternative wird als mehrdeutige Basis abgewiesen. Es findet keine Unicode-Normalisierung statt.

Weitere Grenzen: Schema exakt DoclingDocument 1.11.0; genau eine Seite Nr. 1; maximal 8 MiB JSON, 10.000 Knoten, Tiefe 32, 4.096 Tabellenslots, 256 Spalten. Referenzen, Elternkette, Erreichbarkeit, Zellspannen, lückenlose Tabellenbelegung, Seitenrechtecke und Koordinatenursprung werden geprüft. Zellmittelpunkte müssen in der Tabellenregion liegen; eine vollständige geometrische Zellrechteck-Inklusion ist hier kein zusätzlich bewiesenes Gate. Listen werden als unveränderter orig-Text projiziert, ohne neue Listen-/Headersemantik. Bilder bleiben ausdrücklich nur inventarisiert und werden nicht als Assets exportiert. JSON und Receipt werden gegeneinander gehasht; sourceSHA256 ist ausschließlich der gespeicherte Receiptwert, kein erneut gelesener PDF-Hash. Deshalb ist dies kein vollständiger Dokumentkonverter und kein Source-Binding-Produktpfad.

Die 18 Negativfälle umfassen fehlende Referenzen/Knoten/Caption-Aliase, zyklische Struktur, überlappende oder widersprüchliche Zellspannen, fehlende Tabellenabdeckung, Seiten-/Ursprungsfehler, Größenbudgets sowie fehlende/überlappende/ungeordnete/zu große Provenance-Spans und mehrdeutige Textbasis. `results-final.json` enthält genaue Fehler, ursprüngliche Quellreferenzen, Originaltexte, Rechtecke, Tabellen und erzeugtes Markdown.

## Reproduktion

`inputs.json` bindet alle 138 unveränderten Core-/C-Quell- und Ressourcen-Dateien sowie acht vorhandene JSON-/Receipt-Dateien bytegenau. Die Kopie wurde gegen die aktuellen Produktquellen verglichen. Der Build verwendet das vorhandene lokale Image `pmt-linux-builder`, Image-ID `sha256:c38018174ed7a07867a78a7d221162d7bce376d2ba1e3069b116679d3ef92d93`, Swift 6.2.1 und vorhandene lokale swift-crypto-/swift-asn1-Checkouts. Docker läuft ohne Netz; kein Modell, Dataset-SDK oder Download wird aufgerufen.

```sh
python3 reproduce.py --repo "$PMT_REPO" --work /tmp/pmt-p11-projection-repro-new
```

`--work` muss neu sein. Das Script kopiert nur die benötigten Sources/JSONs, benutzt einen eigenen Cache dort und behält bei Fehlern seine Belege. Es schreibt nicht in das Repo. Vorhandene Offline-Checkouts unter `.build/linux/docker/checkouts` sind Voraussetzung. Der oben genannte tatsächliche Swift-Build und finale Lauf sind ausgeführt; der neu beigelegte Reproduktionsgenerator wurde zusätzlich im `--prepare-only`-Modus geprüft. Dessen zweite vollständige Neuübersetzung wurde nicht unnötig wiederholt. Der tatsächliche Build nutzte den ausdrücklich freigegebenen isolierten Cache `.build/linux/p11-projection-cache`; er wird nach Sicherung dieses Belegs entfernt.

Entscheidungsvorlage: Ein kleiner strikt begrenzter Foundation-Adapter ist für diese vier gespeicherten JSONs tragfähig. Vor einem Produktpfad fehlen weiterhin qualifizierte Erkennungsqualität, Mehrseiten-/Asset-/Source-Binding-/Prozessintegration und vollständige Semantik. Die weiterhin fehlende P11-Produktfähigkeit wird durch diesen Prototyp nicht freigeschaltet.

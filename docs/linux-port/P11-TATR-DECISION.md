# P11: TATR-Containerprobe und Entscheidung

2026-11-05. Der fest gepinnte Microsoft-Table-Transformer ist auf CPU und offline
lauffähig. **Dieser unveränderte Pfad wird nicht als Produktbackend freigegeben.**
Swift bleibt der gemeinsame Konvertierungskern; die Qualitätslücke begründet
keinen Neubau des Konverters.

| Quelle | Tatsächliches automatisches Ergebnis |
| --- | --- |
| Natürliche DPBench-Seite 132 | Eine Tabelle gefunden, acht statt neun Zellen. Acht Zelltexte vorhanden; die über zwei Spalten reichende Kopfzelle mit sechs Wörtern fehlt. Ohne erste Zeile stimmen null von neun Texten an der exakten GT-Zeile/Spalte. |
| Natürliche Seite 134, ohne Tabelle | Korrekt null Tabellen. Das belegt keine Diagramm- oder Seitenlesereihenfolge. |
| Natürliche Seite 135, ohne Tabelle | Eine falsche Tabelle im Fußnotenbereich, drei falsche Zellen. |
| Identisches synthetisches Mac-Fixture | Tabelle erkannt, aber null von acht Zellen nach dem offiziellen Postprocessing; alle neun Tabellenworttokens unzugeordnet. |

Die fehlende Kopfzeile wird nicht nachträglich aus der Referenz entfernt.
Unzugeordnete Wörter bleiben in der Diagnose erhalten. Eine vollständige
Markdownausgabe wurde nicht erzeugt; aus dem Zellergebnis wird deshalb kein
angeblich gemessener Gesamtdokumentverlust abgeleitet. Automatische Detektion,
Crop und unverändertes offizielles Postprocessing wurden ohne manuelle ROI oder
Tuning auf GroundTruth ausgeführt.

Die Probe nutzte ausschließlich revisions- und SHA256-gebundene Safetensors.
Der vollständige unveränderte State wurde mit `load_state_dict(strict=True)`
geladen. Drei nullwertige Trainingszähler werden durch den dokumentierten
FrozenBatchNorm-Ladepfad behandelt; kein Lerngewicht fehlt und kein `strict=False`
oder Remote-Code-/Pickleloader wurde verwendet. Pretrained-Backbone-Nachladen war
ausgeschaltet. Die tatsächliche Inferenz lief mit Netzsperre, read-only Root,
UID 1000, zwei CPUs, 3 GiB und Seiten-/Prozessfristen. Alle vier Quellen blieben
hashgleich. Je Fall wurden etwa 1,0–1,8 s plus etwa 0,8 s Modellladen gemessen;
der höchste protokollierte Prozess-RSS lag bei etwa 772 MiB. Das sind begrenzte
Einzelmessungen, keine Leistungszusage für andere Hardware.

Setup und Modelle umfassten 525.027.426 Bytes einschließlich des zunächst falschen
PyMuPDF-Pins; das lag unter dem 750 MiB-Setupdeckel. Zwei Setupbefunde wurden
transparent getrennt: Der vorgeschaltete zu strenge Keysetcheck berücksichtigte
die dokumentierten Trainingszähler nicht; PyMuPDF 1.26.5 fehlte `Rect.get_area`
(Fehler #4742), weshalb ausschließlich auf 1.26.6 korrigiert wurde. Das war keine
Änderung an Geometrie, Schwellen oder Modellqualität.

Digitale Wortboxen stammten aus Poppler 24.02; für das synthetische PNG wurde
Tesseract 5.3.4 benutzt. Natürliche Scans/Fotos, vertikale Spans, mehrseitige
Tabellen und allgemeine Seitenlesereihenfolge sind damit nicht qualifiziert.
Die eingefrorene Mac-Basis 0.41.7 bleibt separat: Alle sechs natürlichen
`off`/`structured`-Fälle waren Fallback; das identische synthetische Bild lieferte
sieben von acht Zelltexten und `structuredApplied`. Das ist keine neue
Mac-Regression des Linux-Portstandes.

Modelle/Microsoft-Code sind MIT, Transformers-Code Apache 2.0. Das offizielle
Zellpostprocessing benutzt PyMuPDF mit AGPL/kommerzieller Lizenz. Die isolierte
Probe erteilt keine Produkt-/Distributionsfreigabe. Buch und Bildanteile besitzen
ihre eigenen [Korpuslizenzen](P11-NATURAL-EVIDENCE/ATTRIBUTION.md).

[Kleine Messwerte und Hashes](P11-TATR-EVIDENCE/result.json), Modellrevisionen und
vollständige Wheelpins bleiben erhalten; große Modelle bleiben außerhalb des
Repositories. Das bewusst zu startende Reproduktionsrezept liegt unter
`scripts/linux-probes/p11/tatr/`. Es ist kein Runtime-Downloadmechanismus.

Primärquellen: [Microsoft-Inferenzvertrag](https://github.com/microsoft/table-transformer/blob/16d124f616109746b7785f03085100f1f6247575/docs/INFERENCE.md),
[FrozenBatchNorm-Ladepfad](https://github.com/huggingface/transformers/blob/v4.57.1/src/transformers/models/table_transformer/modeling_table_transformer.py),
[PyMuPDF-Bug4742](https://github.com/pymupdf/PyMuPDF/issues/4742),
[PyMuPDF-Lizenz](https://pymupdf.readthedocs.io/en/latest/about.html#license-and-copyright).

P11 bleibt offen. Ein anderer Struktur-/Layoutansatz braucht neue begründete
Qualitätsbelege; bis dahin meldet die Produkt-CLI strukturierte OCR als unavailable.

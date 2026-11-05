# Begrenzte TATR-Qualitätsprobe

Diese Werkzeuge gehören ausschließlich zur P11-Entscheidungsprobe, nicht zum
Produkt oder dessen Laufzeit. Sie installieren nichts auf dem Host. Das
Docker-Setup lädt bewusst gepinnte öffentliche Modelle/Wheels mit Hashprüfung;
Inferenz läuft anschließend ohne Netzwerk und mit festen Ressourcenlimits.
Microsoft-Postprocessing und alle Modelle bleiben im Containerlayer, werden
nicht als Produktbestandteil gebündelt. PyMuPDF ist AGPL/kommerziell lizenziert;
die isolierte Probe erteilt keine Freigabe zur Produktweitergabe.

`Dockerfile`/`setup.py`/`assets.json` und die vollständig gehashten Pythonpins bilden
das konsolidierte Rezept mit PyMuPDF 1.26.6. Das Rezept wurde nach Auswertung
konsolidiert; es wurde nicht als neuer Imagebuild/Inferenzlauf wiederholt.
Die tatsächlich geprüfte historische Image-ID steht in den Ergebnisbelegen.
`run.sh` verlangt genau diese lokale ID; bei bewusst neuem Aufbau muss die neue
ID unabhängig geprüft und entsprechend gesetzt werden.

Für `input/` die drei gehashten natürlichen PDFs aus der P11-Corpusmanifestdatei
und das unveränderte synthetische `structured.png` sowie
`docs/linux-port/P11-NATURAL-EVIDENCE/selected-reference.json` bereitstellen. `output/` muss
ein eigener beschreibbarer Probeordner sein. Korpus-/Buch-/Bildlizenzen und
Primärquellen stehen im P11-Bericht. Keine Benutzerunterlagen verwenden.

Die Probe erzeugt keine vollständige Markdownkonvertierung und belegt weder
allgemeines Seitenlayout noch natürliche Scan-/Foto-OCR. Die automatische
Tabellenqualität hat die Abnahme nicht bestanden; keine Threshold-/ROI-Anpassung
an GroundTruth vornehmen und diesen Befund nicht als Produktbackend ausgeben.

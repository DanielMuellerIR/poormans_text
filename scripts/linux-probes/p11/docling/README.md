# Begrenzte Docling-/TableFormer-Probe

Die tatsächlichen Ergebnisse stehen in `docs/linux-port/P11-DOCLING.md`.
Wheels und fünf Modell-/Configdateien sind vollständig per Version/Revision,
Bytezahl und SHA256 gebunden. `setup.py` lädt sie ausschließlich beim bewusst
beauftragten Probeaufbau; die normale PMT-Laufzeit verwendet dieses Rezept nicht.

Die konsolidierte Dockerfile ist ein Reproduktionsrezept aus den tatsächlich
verwendeten Pins. Dieser vereinfachte Neuaufbau wurde nach dem Versuch nicht
nochmals ausgeführt. Der echte Versuch ergänzte zunächst fehlendes `convert-core`
(Rtree/SciPy); die erhaltene vollständige Liste umfasst bereits alle 72 Wheels.
Benötigt wird ein ausdrücklich vorhandenes offizielles Swift-/Ubuntu-24-Basisimage.
Der gezählte zusätzliche Setupumfang enthält dessen erneuten Download nicht.

```sh
docker image inspect swift@sha256:0e4716bd34384d22963a63afbdbc93be3129dfd0753185aa1ded27755abdcae8
docker build --pull=false -t pmt-docling-repro scripts/linux-probes/p11/docling
```

Für Inferenz einen eigenen Container mit `--network none`, `--read-only`,
`--cap-drop ALL`, `--security-opt no-new-privileges`, UID1000, zwei CPUs,
4 GiB RAM/Swap und 256 PIDs benutzen. Quellen/Modelle und dieser Probeordner
sind read-only; nur eigene Ausgaben und ein begrenztes `/tmp` sind beschreibbar.
Die Probe erwartet `/input`, `/output`, `/probe` und `/opt/docling/models`.
`timeout -k 5 180 /opt/probe/bin/python -I /probe/probe.py DATEINAME` prüft einen
Fall. `/probe` enthält `probe.py` und `quality.py`. Die bekannte natürliche
Referenz heißt `/input/selected-reference.json`; Quellen und Attributionen sind
im Korpusbericht dokumentiert. Das synthetische Bild heißt `structured.png`.
Die Variante `01030000000132-render.png` ist dieselbe öffentliche PDF-Seite,
unverändert mit Poppler bei 144 DPI gerastert, mit derselben Tabellen-GT.

Eine Bind-Ausgabe mit passender Benutzer-ID verwenden oder bei privatem tmpfs
vor Containerende per `docker exec ... tar` sichern. `docker cp` lieferte in der
Probe den Mountinhalt nicht; daraus wurde keine erfolgreiche Ergebnissicherung
abgeleitet. Keine Modell-/Schwellen-/Regionsanpassung an die Referenz durchführen.
Nach Sicherung der kleinen Resultate eigene Container und Modellimages entfernen.

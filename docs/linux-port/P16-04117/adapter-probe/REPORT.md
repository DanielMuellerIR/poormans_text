# P11: Produktadapter mit quelltreuer Rasterauflösung und begrenztem Modellprozess

2026-11-05. Der echte Linux-Produktpfad für strukturierte OCR ist als isolierter Patch umgesetzt und geprüft. Vorhandene Bild-DPI bleiben ausschließlich für strukturierte OCR erhalten; PDF-OCRraster erhalten ihre tatsächlich berechnete Renderdichte. Alle fünf echten Modell-CLI-Fälle bestehen technisch. Die objektive Erkennungsqualität bleibt **FAIL**, das abzugebende Digesttor bleibt **nil →69**. Keine Aktivierung oder Gesamtfreigabe.

`combined-adapter.patch` enthält den vollständigen Stand gegen die unveränderten Rootbasen: sieben Produktdateien und eine Linux-Testdatei. `dpi-safety-increment.patch` ergänzt den zuvor gelesenen Nilpatch. `original-nil-adapter.patch` und die frühere Lieferung bleiben unverändert erhalten. RootParser, ProcessRunner, CoreModel, ProductInfo, Versions-/Gitstand und Fastra wurden hier nicht geschrieben.

## Quelltreue und physische Bindung

LinuxRasterBackend.withFrames erhält ein optionales preserveResolution=false. Nur LinuxImageAdapter fordert es bei tatsächlich aktivierter strukturierter OCR an. Der gebündelte Rasterhelper übernimmt vorhandene endliche isotrope Quelldichten im begrenzten Bereich1…10000dpi. Fehlende DPI bleiben fehlend. EXIF-Achsenrotation und die tatsächlichen Pixelmaßstäbe beim Downscale werden berücksichtigt. Ungültige, mehrdeutige oder anisotrope Dichten werden verständlich abgewiesen, niemals kosmetisch vereinheitlicht. Eine begrenzte rohe PNG-pHYs-Prüfung verhindert insbesondere, dass vom Bilddecoder ignorierte ungültige Einheiten still als fehlende DPI gelten.

PDF erhält denselben Opt-in ausschließlich im structured-extract. Poppler/Cairo kennt Pixelbreite/-höhe und die echten PDFseitenpunkte. Aus w/page.width×72 und h/page.height×72 wird ein standardkonformer pHYs-Chunk mit stdlib-struct/zlib-CRC erzeugt. Eine begrenzte Streamingkopie ergänzt nur das selbst erzeugte OCR-PNG. Keine Pillow-Abhängigkeit im PDFbackend. Standardextraktion, Preview und extrahierte Bildassets ändern sich dadurch nicht. Der vorhandene0.41.15-Befehl validate-attachment bleibt erhalten.

Swift prüft das gestagte PNG vollständig mit libpng und liest pHYs direkt aus genau diesen validierten Bytes. Workerwrapper bindet SHA256, Pixelabmessungen, beide tatsächlichen DPIachsen und RohJSONhash. Docling-Seitenpunkte müssen für jede Achse zur wirklichen PNGdichte passen. Gerundetes Downscale wird damit nicht über eine größere Seitenverhältnistoleranz kaschiert. pHYs quantisiert DPI entsprechend dem PNGformat auf ungefähr0.0254dpi; gebunden werden die tatsächlichen gespeicherten Werte.

Weiter gelten16MP,8MiB JSON und8MB Text, typisierter Rootparser und unveränderter StructuredOCRRendering. Originalimageassets bleiben bytegleich; SourcePDF wird nicht geändert. PDFStructuredOCRMerge schützt digitalen Originaltext. Nicht sicher vereinbare Struktur fällt mit sichtbarer Diagnose auf die vorhandene Standard-OCR/SupplementaryLines zurück. Fehlende Runtime/Modelle, unsichere Bindung und Prozess-/Dateisystemfehler werden nicht still als Standard-OCR ausgegeben.

## Ausgeführte Prüfung

**20 Swift-Tests bestanden:**13 aktuelle Rootparsertests, sechs neue Adaptertests und ein ausschließlich temporärer realer Read-only-Worker-JSON-/Inventartest. Der dauerhafte Patch enthält die sechs neuen Linuxfälle. `evidence/final-dpi-pdf-tests.log` ist der Abschlusslauf gegen die endgültige Nilquelle.

Rasterregression: sieben echte Quellen (bekanntes Original, natürlicher Raster, nodpi, Downscale, EXIFrotation, anisotrop, zero), fünf zusätzliche ungültige Metadatenfälle (NaN, unendlich, negativ, zu groß, boolean) und eine rohe ungültige pHYs-Einheit. Die abschließende Probe besteht. Standardframes und Preview sind auf denselben Inputs bytegleich zum unveränderten Helper. Downscale5001×4000→4472×3577 erhält die entsprechend skalierten, PNGquantisierten Dichten; EXIF6 ergibt80×120 statt120×80. Diese beiden Fälle wurden als Raster-/Metadatenproben geprüft, nicht mit zusätzlicher Modellinferenz. Keine zusätzliche echte HEICprobe; der Originalasset-/Previewpfad bleibt im Code unverändert.

| Echter vollständiger CLI-Fall | Beobachtung |
|---|---|
| Original e37ca92… |42.3s,Exit0,structuredApplied+Approximation;DPI299.9994 und Pixel bleiben gleich;Docling432.000864×384.000768;3×3Tabelle mit8Zellen. |
| Natürlicher Raster dfe0a1d9… |45.8s,Exit0;DPI143.9926 und Pixel bleiben gleich;Docling576.0296×720.0370.9Zellen/5×2 und vollständige rohe Zelltexte/-spannen stimmen exakt mit der benannten Standaloneprobe überein. |
| Nodpi-Kontrolle |46.9s,Exit0;keine DPI erfunden. Frame5c5975… und RohJSONdad1e590… sind exakt dieselben wie vor dem Fix. |
| Echte Scan-PDFseite |43.5s,Exit0,structuredApplied, Bildasset erhalten. Tatsächliche PDFpunkt-/Pixelmatrix statt impliziter72dpi. |
| Gemischte Scan-/digitale PDFseite |42.9s,Exit0, expliziter konservativer structuredFallback. DIGITAL ORIGINAL MUST SURVIVE 7319 bleibt exakt einmal enthalten; Quellhash unverändert und Bildasset vorhanden. |

Die Pixel-/DPI-/JSONbindungen stehen in dpi-bindings.json, dpi-inference-summary.json und pdfdpi-summary.json. Der rein lesende /proc-/inotify-Observer bewahrte jeweils tatsächlichen Frame und abgeschlossenes Worker-JSON. Die produktiven Helper enthalten keine Testnamen, Groundtruth oder Referenzkorrekturen. Popplerregression auf beiden PDFs: Standard- und Previewdateien jeweils bytegleich; validate-attachment unverändert. Erwartete Renderdichte144dpi wird im PNGformat als143.9926dpi repräsentiert und genau so gegen die Doclingpunkte gebunden.

## Qualität bleibt getrennt

Der vorhandene unveränderte quality.py-Vergleich gegen die unabhängige synthetische8-Zellen-/3-Spalten-Referenz liefert nach der Metadatentreuekorrektur5/8exakte Zelltexte,8/8Spannen und1/1MergedCell. A1/B1/C1 bleiben Al/Bl/Cl. Deshalb **FAIL**. Vor dem Fix zeigte das Modell am DPIlosen Frame6Zellen/2Spalten; nach Übernahme der echten Quelldichte wieder8Zellen/3Spalten. Es wurden weder eine kanonische DPI noch Modellschwellen oder Referenztexte eingesetzt. Die natürliche Standalone-/Produktinventargleichheit ist ein Übertragungsnachweis, keine allgemeine Naturqualitätsfreigabe.

## Harte Grenzen und gemessener Speicher

Der erste Entwurf verwendete ungeprüft12GiB AS. Das wurde vor Übergabe korrigiert: Der echte Worker besteht mit **RLIMIT_AS4GiB**, CPU120s und FSIZE8MiB, gesetzt vor Parser-/Torchimporten. Zwei Rechenthreads und Offline-/No-Telemetry-Einstellungen bleiben fest. Der bestehende ProcessRunner liefert private PID-/Netznamespace, Timeout und Lifetimebarriere; keine neue Prozessarchitektur.

Gemessene fünf Produktfälle: höchstens VmPeak2864800KiB≈2.73GiB und VmHWM/RSS1364540KiB≈1.30GiB im Modellprozess. Eine direkte identische4GiB-Probe besteht ebenfalls. Absichtlich auf256MiB verengter Adressraum verhindert den echten Torch-DSO-Import kontrolliert:Exit69, kein Dokument/kein JSON, failed to map segment. Dies ist ein Ressourcenlimit-Negativfall, kein behaupteter physischer Kernel-OOMtest.

**4GiB AS ist eine harte Grenze pro Modellprozess und wird von dessen Nachkommen geerbt. Es ist weder ein4GiB-RAMlimit noch ein aggregiertes Joblimit.** Die Prüfcontainer hatten zusätzlich außen CPU2/RAM4GiB/PID256. Das Produkt besitzt diese zusätzliche Cgroupgrenze nicht; parallele Prozesse oder der separat über den vorhandenen Standardpfad gestartete Fallback werden damit nicht als gesamter Job auf4GiB beschränkt. Root entscheidet über die Eignung dieses bewusst lokalen Entwicklungsprofils. Kein systemd-/Cgroupneubau wurde eingeführt.

Private PID-/Netznamespace und die tatsächlichen4GiB-/CPU-/FSIZEwerte sind aus laufenden Workern in den Prozessbelegen erfasst. Vorherige echte MissingRuntime-/Manifestabweichungs-/Cancelproben bleiben in der ursprünglichen Lieferung; sie wurden nicht als neue DPI-/AS4-Abbruchabnahme umetikettiert.

## Übergabe und Grenzen

Der feste Runtimepfad ist weiterhin `<CLI-bin-dir>/../structured-ocr`.30192 Dateiinhalte/2158493598Bytes werden gegen das5.78MB-Manifest vollständig geprüft; erwarteter Digest im Liefercode **nil**. Nur die eigene Smokebinary wurde zeitweilig mit cd4673de443d7e2570d6c4c4666cecb4924e2ceaf22703cba2a273a544eface6 gebaut. Root setzt einen Digest erst nach seiner Qualifikation. Kein Environmentoverride und keine editierbare Boolselbstfreigabe.

Keine zusätzliche Mehrseiten-/Mehrframe-Modellabnahme, keine allgemeine OOM-/Gesamtjob-RAMzusage und keine semantische Vollparität. Alle natur-/formatübergreifenden Qualitätsgrenzen bleiben offen. Die konservative erneute vollständige Runtimeprüfung kostet Zeit; kein unsicherer Cache wurde eingebaut.

Eigene Container sind beendet. Große eigene Build-/Arbeitskopien werden nach dieser kleinen Lieferung entfernt; der fremde eingefrorene Runtime bleibt unverändert. Referenzzweck: Integration, DPI- und Sicherheitsreview; nächste Prüfung2026-12-05, entbehrliche Daten spätestens30Tage nach Abnahme entfernen. Root allein übernimmt Patch/Version/Commit. Kein Repo-/Git-/Fastrawrite durch diesen Auftrag.

# Native Mint: extrahiertes Paket 0.41.13

Ergebnis: **25 RTFD-CLI-Fälle, ein DOCX/PNG-Fall und ein echter Produktions-GUI-CSV-Lauf bestanden.** Dies ist private Paketextraktion mit Produktlauf, ausdrücklich keine Installation-/Upgrade-/Remove-Abnahme. Weder dpkg --install noch apt/Systeminstallation/Downloads/Overlay ausgeführt.

Geprüftes Paket: poormans-text_0.41.13~linuxpreview1_amd64.deb, SHA256 640be59eeacddca4fdb0626a84de2ccba8012cf49eb0e98627af404d28cf80ff. Runtime aus dpkg-deb -x ausschließlich in eigener /tmp-Wurzel. CLI26470eaf..., GUI851d0a76..., Guardcf677f9b... stimmen mit dem finalen Rootstand überein; vollständige Werte in evidence/evidence.json/runtime-manifest.json. Unverändertes qualifiziertes Pandoc3.1.3 (SHA5a953bcb...) wurde ausschließlich unter /tmp übertragen und bei jeder betreffenden CLI-Konvertierung ausdrücklich per --pandoc angegeben. Kein SwiftSDK auf Mint nötig.

## Tatsächliche native CLI-Belege

25 RTFD-Fälle = zwölf erfolgreiche Pakete und 13 erwartete Ablehnungen. Erfolgreich: Unicode/RTF-Listen und Attachmentpositionen, PNG sowie statisches BMP/JPEG/JPEG-Alias/TIFF/TIF/GIF/WebP/HEIC. Originalassetbytes und normalisierte Endungen stimmen; erwartete TIFF/HEIC-Viewerwarnungen werden geprüft. Mehrframe-GIF/TIFF/APNG/WebP/HEIC und unsichere/defekte Paketfälle veröffentlichen keine Ausgabe. Statisches HEIC funktioniert auf dem vorhandenen nativen libheif; Mehrbild-HEIC wird mit65 abgewiesen. Alle RTFD-Quellbytes blieben hashgleich. Der unveränderte vorhandene Prüfcode erzeugt seine synthetischen Encoderfixtures unabhängig von PMT und vergleicht Texte, Assetpositionen, Bytes und Diagnosen.

Das bestehende synthetische picture.docx konvertiert mit DOCXTOKEN/Größe/PIXELTOKEN. PNG-Bytes aus dem ursprünglichen Word-ZIP und dem Ergebnisasset sind identisch; SourceIdentity und Quellhash stimmen. Kein neuer DOCX-Generator oder Writer.

## Native Produktions-GUI

Der bestehende private Xvfb-/D-Bus-/AT-SPI-Harness wurde einmal gegen die extrahierte endgültige GUI ausgeführt. HOME/XDG/run/tmp waren privat, Net-/PID-Namespace isoliert, Hostdisplay/Sessionbusvariablen entfernt. GTK nutzte Mintbibliotheken ohne Swift-LD; nur der private CLI-Launcher setzt Swift-LD im Kind. Eine echte Accessible-Convert-Aktion erzeugte Markdown mit ARCHGUIMARKER und Grüße, erhielt den Quellhash und erreichte sichtbar/zugänglich Completed. Screenshot wurde visuell geprüft: klare Controls, passiver Markdowntext, Completed und wieder aktiver Convertknopf.

Im privaten Sessionbus wurden Accessibility-/Portal-Helfer aktiviert. Portal/FUSE-/PipeWire-Warnungen betreffen ausschließlich diesen isolierten Namespace; keine FUSE-/Modulinstallation oder Hostdienste gestartet. Es wurde kein Filechooser benutzt. Dies ist kein vollständiger Desktop-/Clipboard-/Dateidialog-Abnahmeclaim; frühere .12-GUI-Belege bleiben historisch getrennt.

## Stabilität und Cleanup

Alle Runtime-Dateihashes blieben vor/nach CLI und GUI gleich. Keine eigenen verbleibenden Prozesse vor Cleanup festgestellt; Xvfb ist über den vorhandenen pidfd-Finalizer beendet, weitere Sessionprozesse über den privaten PID-Namespace. Der gesamte eigene Remote-Arbeitsbaum ist nach Sicherung der kleinen Belege entfernt (cleanup.json). Maximal etwa364MB, unter700MiB. Auch /usr/bin/true und /var/lib/dpkg/status haben weiterhin exakt die vor der vorausgehenden COW-Vorprobe gemessenen Hashes. Rootrepo, Hostinstallation und Benutzerdesktop unverändert.

Die kleinen Laufskripte und JSON-/Log-/Screenshotbelege liegen bei. native_run.py benutzt eine eigene /tmp/pmt-mint-04113.*-Wurzel mit dem übertragenen Paket, Pandoc, vorhandenen HEIC-/DOCX-Fixtures und Prüfskripten. Vollständige Pakete/Runtime/Pandoc oder SDK sind bewusst nicht im Belegarchiv dupliziert.

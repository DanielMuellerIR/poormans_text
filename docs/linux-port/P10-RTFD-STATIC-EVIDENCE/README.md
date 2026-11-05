# Finaler RTFD-Patch einschließlich BMP

Für BMP gab es keinen technischen Ausschlussgrund. Es fehlte lediglich in der zuvor eingegrenzten Typenliste; der vorhandene Rasterdecoder unterstützt BMP bereits. Dieser vollständige Vierdateienpatch ersetzt den vorigen Patch, ohne einen weiteren Decoder oder Produktpfad einzuführen.

`rtfd-static.patch` SHA256: `3412da78decfaefbd2791e05908cbf1b70e5a9d619f6e4bf0903bb23f3ce9aa1`.

Zusätzlich zum vorher geprüften Kandidaten: BMP-Mapping und Fehlertext in LinuxRTFDPreparation, echtes unabhängig erzeugtes BMP im vorhandenen statischen Unit-Fall und echter BMP-Fall in der vorhandenen CLI-Probe. Weiterhin genau vier Dateien; RichTextConverter-Diagnose unverändert. PNG/JPEG/TIFF/GIF/BMP/WebP/HEIC müssen zum tatsächlichen Decoderformat passen und genau einen Frame enthalten. TIFF/HEIC behalten die ehrliche Viewer-Kompatibilitätsdiagnose. Originalbyte-/Endungs- und Positionspfad unverändert; Mac unverändert.

Frisch am 2026-11-05 ausgeführt: Swift6.2.1/Noble-Vollbuild75,58s; neun RTFD-XCTests einschließlich BMP, 0Fehler/1,607s; 23 echte CachyOS-CLI-Fälle, alle Erwartungen erfüllt. Dieser Lauf enthält BMP sowie alle bisherigen nichtoptionalen statischen Raster-/Mehrframe-/RTF-/Paket-/Verweis-/Symlink-/FIFO-/Fehlformatfälle. BMP ist ein byteidentisches Asset an der ursprünglichen BEFORE/Bild/AFTER-Position, Ausgabeendung `.bmp`. Quelle/Asset SHA256 jeweils `cfb3fa514861b924669bb08e35ee7fa61223a13bcc33a5017c447a191a990a87`. Alle Paketquellen unverändert; negative Fälle veröffentlichen nichts.

`evidence.json`, `unit.log` und `build.log.gz` binden diesen finalen BMP-Kandidaten. `evidence-before-bmp.json` und `README-before-bmp.md` bewahren getrennt die bereits gelieferten 48 Host-/Noble-Fälle mit HEIC sowie fehlende-Pillow-/Timeout-/Abbruchkontrollen des vorherigen Kandidaten. Diese wurden nach der reinen BMP-Ergänzung nicht unnötig erneut ausgeführt und werden nicht als Messung des neuen Binaryhashes ausgegeben.

Reproduktion und Grenzen stehen in `README-before-bmp.md`; die im Patch erweiterte CLI-Probe erzeugt jetzt zusätzlich ein echtes BMP. Ohne optionale HEIC-Argumente sind es23 Fälle, mit beiden HEIC-Fixtures25. Keine Root-/Git-Schreibarbeit. Alle vier Ausgangsdateihashes stimmen weiterhin mit Root überein. Root übernimmt und versioniert. Eigene Source-/Cache-/Runtime-/Containerressourcen sind entfernt; kleine Lieferung bleibt erhalten, Cleanup siehe `cleanup.json`.

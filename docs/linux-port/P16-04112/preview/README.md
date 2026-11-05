# Finale 0.41.12: SourcePreview und Bridge

Gegen exakt den finalen Rootrelease ausgeführt, kein früherer 0.41.11-Kandidat:

- CLI SHA256 `2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c`.
- Guard SHA256 `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`.
- 18 SourcePreview-Fälle bestehen im SDK-freien qualifizierten Noble-HEICcontainer: PDF-Seite2/Rotation; PNG-Alpha/ICC/XMP-Entfernung und weißer Hintergrund; JPEG-Orientierung; GIF/TIFF-Frame2; Downscale; HEIC inklusive Rotation/zweitem Bild. Negative Grenzen: ungültige Indizes, defektes PNG/HEIC, Quellen-/Pixelgrößenlimit, verbotene Ausgabeschreiboption. Python/Pillow dekodiert PNG unabhängig; Base64, SHA256, Maße und unerwünschte Metadatenchunks werden geprüft. Alle Quellen bleiben SHA256-gleich.
- Fünf zusätzliche Fälle bestehen: tatsächlicher Timeout124, SIGINT130 und drei Usagefehler64. Auch deren Quelle bleibt SHA256-gleich.
- 16 echte Host-Bridge-Tests aus integriertem Root-Rustsource bestehen, gegen finalen CLI-Launcher und finalen Guard. Die beiden internen Fixture-Einstiege ui_owner_process/pidfd_failure_process werden ausschließlich durch ihre Elterntests aufgerufen und beim äußeren Lauf ausgespart. Keine Voll-GUI-Prüfung oder Wiederholung der bereits belegten elf OCR-Fälle.

CLI-/Guardhashes waren vor und nach dem Lauf identisch. Rootquellen und Cargo.lock bleiben read-only (--locked/--offline). Ausschließlich das ausdrücklich freigegebene generierte Target `.build/linux-root-native` wurde wiederverwendet; alle Fixtures/Ergebnisse liegen außerhalb des Repos. Container --network none/--pull never/--rm, UID1000 und die bestehenden nötigen Namespaceflags. Runtime und Originalfixtures readonly eingeblendet. Ergebnisse waren von Anfang an im eigenen gebundenen Probenverzeichnis gespeichert und überleben das Containerende ohne zusätzliche Kopierlogik.

`manifest.json` enthält die tatsächlichen Fixture-/Werkzeug-/Quellhashes. Die kleinen JSON-Receipts und das Bridge-Log sind der Abschlussbeleg. `reproduce-preview.sh` verlangt explizite Runtime-/Fixturepfade und prüft die finale CLI-SHA. Für eine Wiederholung einen leeren results-Ordner verwenden, weil erfolgreiche Ergebnisfixtures absichtlich nicht überschrieben werden. `reproduce-bridge.sh` verlangt explizites Quellrepo, eigenes generiertes Target, CLI-Launcher und Guard. Kein Download oder Hostwerkzeugwechsel erforderlich.

# Fastra / PMT 0.41.16 – additive RTFD-Identität

2026-11-05, ausschließlich synthetische Quellen im privaten netzlosen Container.

Consumer-Produktionsquellen: Commit `9e5f6c2685e835697feccb2d4e5691f5c415b481`, Produkt 1.165.1; sämtliche Import-/Prozess-Quelldateien wurden vor dem Lauf bytegleich mit dem Commit verglichen. Der zusätzliche Runner `check_rtfd.rs` ist ein eigenständiger Integrationsbeleg; sein Source- und Binaryhash stehen in `result.json`. Die noch laufende Editorportierung ist nicht Teil dieser Paarbehauptung.

Producer: unveränderlicher Handoff 0.41.16 aus `9f8fadd4e1a0c749ac1469c6bfe1c879d5ccd523`, CLI `7df0dff563ac2027d49e116816e61bab586b666695d004e2b49b1ff67daf635f`. Guard und Handoffmanifest sind separat gehasht.

Ausgeführter Aufruf im vorhandenen PMT-Backendprüfimage mit echtem Pandoc:

```text
/check_rtfd /launcher/with-source-map
```

Der geprüfte private Launcher leitet `--formats`/`--help` unverändert weiter und ergänzt ausschließlich beim Konvertierungsaufruf `--source-map`. Er wird nicht Teil des normalen Fastra-Aufrufs. Ohne diese Option ist `sourceIdentity` erwartungsgemäß optional/fehlend; daraus wird kein Fehler des Consumers abgeleitet.

Ergebnis: `passed:true`. `input` bleibt Paketwurzel; `memberPath` ist exakt `TXT.rtf`. SHA256 und Bytezahl entsprechen der ursprünglichen RTF-Datei. Ein geänderter unreferenzierter Anhang verändert den Textfingerprint nicht. Die bewusste Adoption liefert den richtigen Markdown-Einstieg, erhält den Originaltext und verwirft keine Ergebnisdateien. Unbekannte Memberpfade sind im ergänzenden Backendtest reine Metadaten und erhalten keine Dateiautorität.

Grenzen: Diese Delta-Prüfung ist kein neuer nativer GUI-/Hardkillnachweis. Die bereits bestandene .15-Abnahme bleibt der CLI `d354636…85e6` zugeordnet. Ein zuerst gewähltes Image ohne Pandoc meldete kontrolliert Exit69; das war eine fehlende Hostabhängigkeit. Keine Installation auf dem Desktop, kein Netzwerk, keine öffentlichen Artefakte.

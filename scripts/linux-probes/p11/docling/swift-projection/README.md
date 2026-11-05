# Begrenzte Docling-JSON-Projektion

Offline-Probe, keine Produktintegration oder Modellinferenz. Die beiden Swift-
Quellen projizieren gespeicherte Erkennungsdaten in unveränderte Core-Modelle.
Ergebnis und Grenzen: [Bericht](../../../../../docs/linux-port/P11-SWIFT-PROJECTION.md).

```sh
python3 reproduce.py --repo "$PMT_REPO" --work /tmp/pmt-p11-projection-repro-new
```

Ein vorhandenes lokales Buildimage und die vorhandenen Offline-Checkouts unter
`.build/linux/docker/checkouts` sind nötig. Die Probe überschreibt keine
vorhandene Arbeitskopie und lädt keine Modelle, SDKs oder Pakete. Der tatsächliche
Build/Lauf ist belegt; der beigelegte konsolidierte Reproduktionsgenerator wurde
zusätzlich nur mit `--prepare-only` geprüft. Die vollständigen Originalbelege
stehen unter `docs/linux-port/P11-SWIFT-PROJECTION-EVIDENCE`.

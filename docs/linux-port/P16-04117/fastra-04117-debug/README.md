# Finale .17-Launcherprobe gegen Fastras GTK-Consumer

2026-11-05. Der unveränderliche PMT-Produktcommit ist886ef96d87c40af32f253ec2ec88820de69d3afb.
Der Launcher385d2389… und das rohe ELF c334b36c… wurden gegen alle47
Runtime-Dateihashes geprüft. Zwei echte MBOX-Importe im privaten netzlosen
GTK-Testlauf bestehen: Deutsch bei760Pixeln und Englisch bei1100Pixeln,
vollständige Vorschau und bewusste Adoption. Der Test setzte keine PMT-
Bibliothekspfade; der bereitgestellte Launcher richtet sie selbst ein.

Dies ist ausdrücklich ein Debug-Smoke, keine Produktionspaketabnahme von
Fastra. [Consumerbindung](consumer-binding.json): uncommittierter Snapshot
1.167.0/377 auf Basis163c1643…, Binary6fe1d6d2… mit bestehendem
cfg(debug_assertions)-Importselbsttest. Die309-Datei-Quellliste wurde nach dem
Smoke erfasst; der alleinige Consumerwriter bestätigt keine kompilierten
Sourceänderungen seit dem erfolgreichen Build. Die Manifestprüfsumme stimmt.
Die exakte WIP-Diff-Prüfsumme ist gebunden; dessen fremde Produktquellen werden
hier nicht kopiert. [Ergebnisse](results.json), [DE-Log](de-760.log),
[EN-Log](en-1100.log).

Die Produktionspaarung .16/Fastra1.165.1 bleibt separat. Es wird weder deren
Beleg noch ein .15-Hardkillbeleg auf diesen neuen Debugstand umetikettiert.

# Mac-OCR-Testblockade: lokaler Befund und offene native Abnahme

Stand: 2026-11-05. Der [Befund](RESULT.md) trennt die reproduzierte kooperative
Task.sleep-Poolblockade von echter Vision-/Gatearbeit. Die drei lokalen
Ein-CPU-XCTestproben bestehen ohne Skip; die native Mac-Bestätigung und die
vollständige neue Mac-Regression sind noch nicht ausgeführt.

Der Produktalgorithmus bleibt gleich. Der Mock simuliert jetzt einen externen
asynchronen Callback und prüft TaskLocal-Kontext vor/nach dem Await. Ein neuer
24-Caller-Fall prüft tatsächliche Serialisierung durch das originale Gate.
Die Brückenbeschreibung verspricht keinen Fortschritt beliebiger globaler
Timer bei vollständig blockiertem kooperativem Pool.

Reproduktion: `scripts/linux-probes/ocr-bridge/reproduce.sh` auf dem lokalen
explizit gepinnten vorhandenen Swift-Image. Es lädt nichts herunter. Die
Runner-/Payloadskripte daneben bereiten ausschließlich eigene temporäre
native Mac-Prüfverzeichnisse vor; sie erteilen keine Remotezugriffserlaubnis.
Die alten Quellarchivhashes im Befund gehören zum damaligen vorbereiteten
0.41.16-Kandidaten, nicht zu beliebigen späteren Quellständen.

[Zusammenfassung](summary.json), [XCTest](units.log), [Matrix](matrix.log),
[Gate](gate.log). Kein lokaler Lauf wird als vollständige native Produktabnahme
oder Vision-Qualitätsnachweis ausgegeben. Referenzprüfung: 2026-12-05.

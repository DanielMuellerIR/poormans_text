# P06: Linux-CLI und produktive Sicherheitsabnahme

Stand: 2026-11-04. P06 wird nach dem Entwicklungsstand `184f0a5`
formatweise umgesetzt und geprüft. Dieser Zwischenstand ist keine vollständige
P06-Abnahme; die folgenden Belege werden von den P03-Entscheidungsproben getrennt.

## Voller Speicherplatz auf echtem ext4

Der vollständige Konverter 0.41.8 wurde in einer isolierten Umgebung als
UID 65534 auf einem eigenen 64-MiB-ext4-Image ausgeführt. Bei freiem Platz erzeugt
CSV Markdown, Bericht und vier Quellzuordnungen. Quelle und vorhandenes Ziel
bleiben bytegleich. Danach wurde das Image mit echten Kernel-Schreibzugriffen
gefüllt. Ein fehlgeschlagener 1-MiB-Write genügte noch nicht: Eine kleine
CSV-Konvertierung konnte den Restplatz weiterhin nutzen. Erst ergänzende
synchrone 4-KiB-Schreibzugriffe erschöpften den verfügbaren Platz vollständig.

Bei **null verfügbaren Blöcken** scheitert die echte Konvertierung mit Exit 74
und ENOSPC. Sie veröffentlicht kein Ergebnis und hinterlässt kein Staging;
Quelle und bestehendes Ziel bleiben unverändert. Nach Entfernen der Fülldatei
gelingt dieselbe Konvertierung wieder vollständig. Das eigene Loopgerät wurde
ausgehängt und freigegeben, das Image entfernt. Die fehlgeschlagenen Vorversuche
haben ebenfalls keine Images oder Loopzuordnungen hinterlassen.

Reproduktion nach dem Linux-Build und mit vorhandenem lokalen
`pmt-p03-fs-probe`-Image:

```sh
bash scripts/linux-probes/p06/run_product_ext4.sh
```

Das Skript benötigt Docker mit Loop-/Mount-Rechten. Es erzeugt ausschließlich
ein eigenes Image unter einem neuen `/tmp`-Verzeichnis. Es bindet die fertige
CLI und ihre Laufzeit read-only ein; keine Ersatzimplementierung des Kerns.
Kleine Ergebnisse stehen unter [P06-EVIDENCE/product-ext4](P06-EVIDENCE/product-ext4/full.json).
Die temporären Ausgaben der ausgeführten Prüfung wurden nach Sicherung dieser
Belege entfernt.

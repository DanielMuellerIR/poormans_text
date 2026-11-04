# P03: Linux-Dateien und Prozesse

Stand: 2026-11-04. Geprüfter Produktstand: `17328f17d63843025b33b45a87fa3d13db5e11d7`.
Die Proben sind von Produktadaptern getrennt. Dieser Befund dokumentiert den
ersten, damals nicht bestandenen Versuch. Die anschließenden
[P03-Entscheidungsnachweise](P03-FOLLOWUP.md) sind bestanden; die Integration
im Produkt steht weiterhin aus. Die hier belegte Lücke des unveränderten
Produkt-Runners bleibt gültig.

Die vorhandene Ausgabevorbereitung legt ihr privates Staging bereits neben dem
Ziel an (`DocumentConverter.swift`, `temporaryRoot`). Das ist die richtige
Voraussetzung für Veröffentlichung auf demselben Dateisystem. Die Kombination
`validateOutput`/`FileManager.moveItem` bleibt für Linux ausdrücklich unfreigegeben:
Eine Vorprüfung belegt keine atomare No-Replace-Garantie. Für den späteren
Linux-Adapter wurde `renameat2(RENAME_NOREPLACE)` als Kernelprimitive erprobt.
Es gibt keinen Kopier-/Overwrite-Fallback bei `EXDEV`, `ENOSYS` oder `EINVAL`.
Der Produktcode wurde noch nicht umgestellt.

| Reale Probe | Ergebnis | Grenze |
| --- | --- | --- |
| Btrfs und tmpfs, 64 konkurrierende Verzeichnisveröffentlichungen | Genau ein vollständiges Ergebnis; 63 EEXIST | Kernelprimitive, kein DocumentConverter-End-to-End-Test |
| Vorhandenes Ziel einschließlich Symlink | Unverändert, Veröffentlichung abgewiesen | Austausch von Elternverzeichnissen braucht gebundene Verzeichnisdeskriptoren |
| Quelle nach Öffnen ausgetauscht | Gehaltener Deskriptor liest ursprüngliche Bytes | Keine vollständige Snapshot-Garantie bei Änderungen desselben Inodes |
| Symlink als Paketmitglied / FIFO | O_NOFOLLOW weist Symlink ab; O_NONBLOCK und fstat erkennen FIFO ohne Warten | Bewusst gewählte äußere Quellsymlinks sind ein anderer Fall |
| Rechtefehler | EACCES | Ohne root ausgeführt |
| Schreibfehler bei Platzmangel | ENOSPC von /dev/full, Original erhalten | Keine tatsächlich gefüllte Partition; Cleanup im Produkt nicht abgenommen |
| Rename Btrfs → tmpfs | EXDEV, kein Ziel, Staging erhalten | Keine Freigabe für Wechsel-/Netzlaufwerke |
| Eigene Prozessgruppe, TERM ignorierende Enkel | Bei Timeout/Abbruch per TERM/KILL beendet und geerntet | Primitive mit Subreaper; setsid-Flucht nicht abgedeckt |
| Vorhandener Swift-ProcessRunner | Argumenttransport, Timeout, Abbruch, Ausgabegrenze, Capture-Cleanup bestanden | Nur Darwin→Glibc und minimale Modellabhängigkeiten im Harness; kein produktiver Linux-CLI-Runner |
| Harter Verlust des Swift-Runner-Prozesses | Werkzeug läuft weiter; Probe beendet und erntet es anschließend selbst | **Sicherheitslücke: Prozessgruppe allein bindet Kinder nicht an den Besitzer** |

Der tatsächliche `ProcessRunner.swift` wurde unter Swift 6.2.1/Noble sowie nativ
auf CachyOS mit mitgeliefertem Swift-Runtimepaket geprüft. Foundation erzeugt hier
mit dem vorhandenen Startup-Handshake eine eigene Prozessgruppe. Das Verhalten
ist ein Beleg für diesen Stand, keine dauerhafte Foundation-API-Zusage. Die
Produktfälle nutzen Dateien für stdout/stderr statt Pipes; die Ausgabegrenze wird
regelmäßig kontrolliert. Das verhindert Pipe-Deadlocks, setzt aber kein hartes
Dateisystemquota: Zwischen Kontrollen kann mehr geschrieben werden.

Aus diesem ersten Versuch ergaben sich folgende Nachweise und Integrationsaufgaben.
Die isolierten Nachweise wurden im Anschluss erbracht (siehe P03-FOLLOWUP);
die Produktadapter sind weiterhin nicht integriert:

- Explizit kontrollierter Gruppenstart und eine Lebensdauerbindung, die auch
  Besitzerverlust und abgelöste Nachkommen abdeckt, etwa ein begrenzter
  PID-Namespace mit überwachten Besitzerprozessen oder eine kontrollierte cgroup.
  Diese Alternativen sind hier noch nicht abgenommen. `PR_SET_PDEATHSIG` allein
  ist kein Nachweis für alle Enkel.
- Gebundene Zielverzeichnisse und ausschließlich atomare Veröffentlichung ohne
  Ersetzen; bei nicht unterstütztem Dateisystem verständlich geschlossen scheitern.
- Echte ext4-Prüfung, voller Datenträger sowie Produkt-Cleanup nach Schreibfehler,
  Abbruch und Prozessverlust. Beide erreichbaren Zielsysteme verwenden Btrfs;
  tmpfs ist kein ext4-Ersatz.
- Dateien mit ungültigem UTF-8 vor JSON-Pfadtransport ausdrücklich ablehnen;
  eine stille Ersatzzeichenkonvertierung ist unzulässig (siehe P01).

Reproduktion vom Repository-Root, ohne erhöhte Rechte:

```sh
python3 scripts/linux-probes/safety.py --parent /tmp
python3 scripts/linux-probes/safety.py --parent . --other-filesystem-parent /tmp
python3 scripts/linux-probes/foundation.py /tmp/pmt-foundation-probe
# Im Swift-6.2.1-Noble-Container oder mit derselben Toolchain:
# swiftc -swift-version 6 Runner.swift Dependencies.swift main.swift -o runner
# timeout --kill-after=2 15 ./runner <frischer-temporärer-Ordner>
# python3 scripts/linux-probes/parent_loss.py ./runner
```

Die Negativprobe meldet `expectedSafetyGapReproduced: true`, wenn das Werkzeug
nach Besitzerverlust noch lebt. Das ist ein reproduzierter Fehler, kein bestandener
Sicherheitsnachweis. Ihre eigene Bereinigung ist Bestandteil des Versuchs.
Die Codex-Werkzeug-Sandbox verbietet Foundation-Wakeup-Sockets; darin blockierte
eine native Wiederholung. Der eigene Prozess wurde gezielt beendet. Die gültigen
Belege stammen aus dem Container und aus dem nativen Lauf mit verfügbaren Sockets,
jeweils mit äußerem Zeitlimit und frischem Arbeitsordner.

Grundlagen: [Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)
und [posix_spawn(3)](https://man7.org/linux/man-pages/man3/posix_spawn.3.html).
Kleine Ergebnisse stehen in [P03-EVIDENCE.json](P03-EVIDENCE.json); Zwischenbuilds
und kopierte Laufzeitbibliotheken sind keine dauerhaften Testbelege.

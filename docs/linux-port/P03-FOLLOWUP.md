# P03: abgeschlossene Entscheidungsnachweise

Stand: 2026-11-04. Ausgangsstand `5293eb6`; Produktquellen unverändert.
**Die beauftragten P03-Entscheidungsproben sind bestanden. Die Integration und
Abnahme im Produkt stehen aus. P05 wurde nicht begonnen.**

Swift ist als gemeinsamer Konvertierungskern gewählt, siehe
[Architektur](../ARCHITECTURE.md). P03 liefert den Ansatz für dessen spätere
Linux-Plattformadapter.

## Gewählter Ansatz zur Prozessaufsicht

Ein eigener PID-Namespace erhält einen kleinen Guard als PID 1 und eine
Lebensdauer-Pipe zum Runner. Der Prototyp verwendet Bubblewrap zur Einrichtung
des Namespace und einen isolierten C-Prüfhelfer als Guard. Der Runner hält das
einzige Schreibende offen; Wrapper und Werkzeug erben es nicht. Der Guard liest
das andere Ende als stdin, das Werkzeug erhält stattdessen /dev/null.
Pipe-EOF und das Ende des eigentlichen Werkzeugs beenden PID 1. Damit beendet
der Kernel auch Enkel, die sich mit setsid von der Prozessgruppe gelöst haben.
Ein bereits vor dem Werkzeugstart geschlossener Kanal wird vor dem Fork erkannt.
Das Werkzeug startet erst nach einem Startbyte, das der Runner nach seiner
pidfd-Bindung sendet. Der Guard setzt PR_SET_DUMPABLE auf 0; Werkzeug und Enkel
können sein Pipe-Leseende nicht über /proc/1/fd/0 als neues Schreibende öffnen.
Dieser Zugriff wird in den Prozessproben tatsächlich versucht und abgewiesen.

Die Belege verwenden ausdrücklich **kein --die-with-parent**. Der zusätzliche
pidfd bindet den Namespace-Wrapper an seine Kernelidentität. Der erste
Swift-Versuch blockierte beim Wrapperverlust in Foundation.waitUntilExit(),
solange der Guard die Eingabepipe noch hielt. Der geprüfte Swift-Harness wartet
deshalb zuerst auf den pidfd, schließt den Kanal und ruft danach waitUntilExit()
auf. Fehlen Namespaces, Bubblewrap oder pidfd-Unterstützung, muss der spätere
Adapter verständlich scheitern; kein Fallback allein auf Prozessgruppen.

| Ausgeführter Fall | CachyOS / Bubblewrap 0.13.1 | Mint 22.2 / Bubblewrap 0.9.0 |
| --- | --- | --- |
| Swift-Runner mit SIGKILL verloren | Bestanden | Bestanden |
| Abbruch über SIGTERM an den Runner | Bestanden | Bestanden |
| Zeitlimit durch Schließen der Pipe | Bestanden | Bestanden |
| Werkzeug endet, abgelöster Enkel lebt zunächst weiter | Bestanden | Bestanden |
| Namespace-Guard mit SIGKILL verloren | Bestanden | Bestanden |
| Namespace-Wrapper mit SIGKILL verloren | Bestanden | Bestanden |
| Zwölf frühe Runnerverluste kurz nach Wrapperstart | Bestanden | Bestanden |

Das sind **18 Fälle je Zielsystem, insgesamt 36 finale Swift-Fälle**. Eigene
Prozessidentitäten werden über pidfds gebunden; vor Signalen wird zusätzlich
die aktuelle Abstammung geprüft. Alle eigenen Kinder wurden geerntet und die
Heartbeatdateien schrieben danach nicht weiter. Session- und Gruppen-IDs
belegen die Ablösung der Enkel. Die Notbereinigung läuft erst nach den
Erfolgsprüfungen und kann keinen grünen Fall erzeugen.

Der erste Versuch war auf vier Stunden begrenzt. Beginn und Abschluss stehen
in [environment.json](P03-FOLLOWUP-EVIDENCE/environment.json); der belegte Ansatz
wurde innerhalb dieses Budgets erreicht. Ein anfänglicher Bind-Mount-Pfadfehler
wurde korrigiert; die Swift-Blockade führte zur beschriebenen pidfd-Ergänzung.

## Deskriptorbasierte Veröffentlichung

Zielkomponenten werden einzeln mit O_DIRECTORY, O_NOFOLLOW und O_CLOEXEC
geöffnet. Quell- und Zielverzeichnis der Veröffentlichung sind gehaltene
Deskriptoren. renameat2 erhält geprüfte einzelne Namen und RENAME_NOREPLACE;
Existenzcheck plus normales Rename oder ein Kopierfallback sind nicht zulässig.

| Reale Probe | Bestehendes Btrfs-Arbeitsdateisystem | Kernel-ext4 im Testimage |
| --- | --- | --- |
| 64 synchron gestartete Publikationen | Ein Gewinner, 63 EEXIST | Ein Gewinner, 63 EEXIST |
| Vorhandene Datei, Verzeichnis und Symlink | Unverändert | Unverändert |
| Äußere/innere Symlinkkomponente | Abgewiesen | Abgewiesen |
| Elternpfad vor dem Binden ausgetauscht | Symlink nicht verfolgt | Symlink nicht verfolgt |
| Austausch vor dem Vorabcheck | ESTALE, keine Publikation | ESTALE, keine Publikation |
| Austausch zwischen Check und Rename | Fremder Baum unverändert, ESTALE | Fremder Baum unverändert, ESTALE |
| Austausch nach Rename vor Nachkontrolle | Fremder Baum unverändert, ESTALE | Fremder Baum unverändert, ESTALE |

Beim Austausch zwischen Check und Rename schreibt die Operation ausschließlich
in das gehaltene ursprüngliche Verzeichnis. Das vollständige Ergebnis bleibt
dort erhalten; ein Erfolg für den inzwischen anderen Pfad wird nicht gemeldet.
Es wird nicht über den fremden Symlink aufgeräumt.

Die Nachkontrolle garantiert keine dauerhafte Stabilität eines Pfadnamens gegen
gleichberechtigte fremde Umbenennungen nach ihrer Ausführung. Sie wird nicht als
atomare Vergleichsoperation ausgegeben. Die Produktintegration muss Konflikt,
Ergebnisidentität und erhaltene vollständige Ausgaben ausdrücklich behandeln.
Der Prototyp lehnt sämtliche Symlinkkomponenten ab; die Semantik bewusst
gewählter äußerer Zielsymlinks bleibt bei der Integration festzulegen.

## Echtes ext4 und Platzmangel

Ein eigenes 64-MiB-Image wurde mit mkfs.ext4 -m 0 erstellt und mit dem
Kernel-ext4-Treiber im privaten Mount-Namespace eines Containers eingebunden.
findmnt bestätigt ext4, die Superblock-Magic ist ef53. Kein FUSE, /dev/full
oder künstlich zurückgegebenes errno.

Dieselbe Schreib-/Publikationsfunktion kopiert eine begrenzte Quelle,
synchronisiert die Ausgabe und veröffentlicht erst danach über die gebundenen
Deskriptoren:

- Bei freiem Platz veröffentlicht sie die vollständige Ausgabe; der Hash
  stimmt mit der Quelle überein.
- Nach dem tatsächlichen Füllen desselben ext4-Dateisystems liefert der
  Schreibversuch ENOSPC (28), veröffentlicht kein Ergebnis und entfernt
  seinen eigenen Teiloutput.
- Quelle und Altausgabe bleiben SHA-256-identisch.

statfs-full.txt weist noch intern freie Blöcke aus; eine Messung „null freie
Bytes“ wird nicht behauptet. Belegt ist die reale Erschöpfung des für diese
Datenausgabe allokierbaren Platzes: Füllvorgang und anschließender echter
Dateischreibversuch scheitern am ext4-Kernel mit ENOSPC. Der anschließende
fsync wurde versucht und lieferte hier keinen zusätzlichen Fehler.
Eine reine fsync-Fehlerinjektion oder Stromausfalldauerhaftigkeit ist nicht belegt.

Die Umgebung benötigt SYS_ADMIN und Loopgeräte, jedoch kein --privileged,
keine physischen Datenträger und kein Netzwerk während der Probe. Skripte und
Containerroot sind read-only; nur der eigene Ergebnisordner und private
temporäre Mounts sind beschreibbar. Das Dokumentdateisystem bleibt
nodev,nosuid,noexec.

Das im Review entdeckte frühe Cleanup-Fenster wurde geschlossen: LOOP_CONFIGURE
setzt LO_FLAGS_AUTOCLEAR atomar beim Attach; der eigene Loop-FD bleibt bis
nach dem Mount offen. SIGKILL direkt nach Attach und direkt nach Mount wurde
gezielt ausgeführt. Die Bindung verschwindet im ersten Fall durch FD-Schluss,
im zweiten nach Entfernen des privaten Mounts. Unmount, fehlende eigene
Loopzuordnung und Imageentfernung sind anschließend bestätigt.
Es gibt kein globales Detach oder Cleanup fremder Geräte.

## Ausstehende Integration und Empfehlung zu P05

**Empfehlung: P05 auf dieser Grundlage freigeben.** Kernsprache und wesentliche
Linux-Sicherheitsmechanismen sind ausreichend belegt. Der Fastra-Consumerfehler
wird getrennt bearbeitet und wurde hier weder verändert noch neu bewertet.
Die offenen P04-Backends bleiben eigene Arbeitspakete.

P05 muss die Proben in die tatsächlichen Produktgrenzen überführen:

1. Portable Targets und Linux-Plattformadapter herstellen; keine ungeprüfte
   Übernahme der P02-Stubs.
2. Prozessaufsicht integrieren: einziges nicht vererbtes Schreibende,
   pidfd-Beobachtung und bestätigtes Namespace-Ende vor Freigabe des
   Arbeitsbereichs. Ein aufrufender Besitzer darf nach hartem CLI-/Runnerverlust
   nicht allein aus dessen Exit auf abgeschlossenen Werkzeug-Cleanup schließen.
3. Deskriptorbasierte Veröffentlichung integrieren, Elternwechsel als Konflikt
   behandeln und bei nicht belegter Dateisystemfähigkeit geschlossen scheitern.
4. Echte Konvertierungen mit denselben Fehlerfällen auf Linux und gemeinsame
   Mac-Regressionstests ausführen. Native Mac-Prozess- und Ausgabepfade behalten
   ihr Verhalten.

ProcessRunner.swift, DocumentConverter.swift und Package.swift sind unverändert.
Die ursprüngliche Prozessverlust-Negativprobe bleibt für diesen Produktstand
gültig. Die neuen Proben sind keine Installations-, Distributions- oder
vollständige Linux-Produktfreigabe. Ununterbrechbar blockierende Kernel-/Hardware-
I/O wird durch diese Fälle nicht abgedeckt.

## Belege und Reproduktion

[Probeskripte](../../scripts/linux-probes/p03-followup) und
[kleine Ergebnisbelege](P03-FOLLOWUP-EVIDENCE) sind versioniert.
Der ältere [P03-Befund](P03-SAFETY.md) bleibt als Ausgangsdiagnose erhalten.

Vom Repository-Root:

```sh
bash scripts/linux-probes/p03-followup/build_swift_owner.sh /tmp/pmt-owner-neu
LD_LIBRARY_PATH=/tmp/pmt-owner-neu/lib timeout --kill-after=3 60 \
  python3 scripts/linux-probes/p03-followup/supervision.py \
  --swift-owner /tmp/pmt-owner-neu/swift-owner

docker build -t pmt-p03-fs-probe scripts/linux-probes/p03-followup
bash scripts/linux-probes/p03-followup/ext4.sh

# Eigene bestehende Btrfs-Test- und Belegordner verwenden:
PMT_PROBE_OUTPUT=/tmp/pmt-belege \
  python3 scripts/linux-probes/p03-followup/fd_publication.py btrfs /pfad/auf/btrfs
```

Build-/Runtimekopien und Images sind entbehrliche Arbeitsdaten und werden nach
Sicherung der Belege entfernt. Bei P05 dienen dieselben Fälle als Referenz.
Keine privaten Originale werden aufbewahrt.

Grundlagen: [PID-Namespace-Lebensdauer](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html),
[pidfd_open](https://man7.org/linux/man-pages/man2/pidfd_open.2.html),
[renameat2](https://man7.org/linux/man-pages/man2/rename.2.html),
[Loop-API](https://github.com/torvalds/linux/blob/v6.8/include/uapi/linux/loop.h).

# Private DPKG-Root ohne Overlay – lokaler Vorlauf

2026-11-05. Der zweite und letzte lokale Versuch besteht: normales DPKG installiert
0.41.14, aktualisiert auf 0.41.15 und entfernt PMT in einer privaten Root. Beide
installierten CLIs konvertieren eine Unicode-CSV; Profil und Quelle bleiben über
Upgrade und Entfernen erhalten. Das ist ein Ubuntu-Container-Vorlauf, noch kein
nativer Mint-Nachweis. Kein SSH und keine globale Hostinstallation wurden ausgeführt.

Außenprozess UID1000, innen UID0 über Usernamespace-Mapping `0 1000 1`.
Das ist kein Host-root. Kein Overlay, kein Hostroot als Schreibbindung und keine
Hardlinks. Der Ablauf bindet nur die private Root schreibbar als `/`; Host-`/usr`
liegt read-only unter `/host/usr`. Private `/usr/bin`, `/usr/lib`, `/usr/share`
sowie deren Anwendungs-/Dokumentationseltern bestehen aus Verzeichnissen und
Symlinks auf dieses RO-`/host/usr`. Ausgenommen sind genau die PMT-Dateien und
-Verzeichnisse. `/bin`, `/sbin`, `/lib` und `/lib64` sind private Aliasse.

Die Paketdatenbank wird lesend in eine private `/var/lib/dpkg` kopiert.
Nur die drei unlesbaren prozessgebundenen Host-Lockdateien werden nicht kopiert;
leere private Lockdateien werden neu erzeugt. Alle DPKG-Status-, Info- und
Triggerinhalte bleiben erhalten. Normales `dpkg --install` und `dpkg --remove`
prüft Abhängigkeiten; keine `--force-script-chrootless`-, `--nodeps`-,
`--no-triggers`- oder sonstigen Umgehungsflags. Es gibt kein Hosthome und keinen
Hostbus. Private PID-/Net-/IPC-/UTS-Namespaces; Netzwerk nur eigenes Loopback.
`/proc`, `/dev`, `/tmp` und Home sind privat.

Vor dem ersten DPKG-Aufruf wurden fünf Schreibgegenproben ausgeführt:

- `/outside-marker` aus einem Ordner außerhalb der privaten Root: EROFS.
- RO-gebundenes altes DEB: EROFS.
- Neuer Marker unter `/host/usr`: EROFS.
- Echtes `/usr/bin/true` über Host- und Proxy-Pfad: EACCES.

Der selbst besessene Außenmarker belegt die RO-Mountgrenze unabhängig von
Unix-Dateirechten; true ist zusätzlich durch seine Hostdateirechte geschützt.
`boundary.json` dokumentiert die Ergebnisse vor jeder Installation.
`outer-evidence/outer.json` zeigt identische Vorher-/Nachherhashes für Host-true,
Host-DPKG-status, beide DEBs und Außenmarker. Die CSV bleibt ebenfalls bytegleich.
Die private PMT-Dateistruktur ist nach Remove verschwunden; das Profil bleibt.

## Reproduktion zur Rootprüfung

`scaffold.py` und `inside.py` nebeneinander ablegen; Rootziel muss neu sein.
Der äußere Benutzer muss UID1000 sein, da der geprüfte Innerlauf genau dieses
Mapping verlangt. Benötigt werden Python3, Bubblewrap, normale DPKG-Daten und
bereits vorhandene Paketabhängigkeiten. Keine Abhängigkeit wird installiert.

```sh
work=$(mktemp -d /tmp/pmt-private-dpkg.XXXXXX)
cp /pfad/zur/Lieferung/scaffold.py /pfad/zur/Lieferung/inside.py "$work/"
docker run --rm --network none --user 1000:1000 \
 --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
 -v "$PWD:/repo:ro" -v "$work:/work" pmt-linux-gui-test:latest \
 python3 /work/scaffold.py \
 --old /repo/.build/linux-preview-04114/poormans-text_0.41.14~linuxpreview1_amd64.deb \
 --new /repo/.build/linux-preview-04115/poormans-text_0.41.15~linuxpreview1_amd64.deb \
 --root /work/run
```

Das vorhandene Image hat Ubuntu24.04, glibc2.39, GTK4.14.5 und Bubblewrap0.9.0.
Normaler Dependencycheck besteht gegen dessen private kopierte DPKG-Datenbank.
Das alte DEB hat SHA256`c93e87876b3882fe078f93cd27741937d4368c32bfe6cb3924fcb4e212e19cb0`,
das neue`f515ed7df0dcb69060d59f64df534d362580cba5cf8ec3304c604094d9cadfe3`.
Die Skripte sind auf private temporäre Ziele begrenzt und verlangen Außen-UID≠0.
Der Container ist entbehrlich; die DPKG-Installation findet trotzdem ausschließlich
in der weiteren privaten Bubblewrap-Root statt.

## Grenzen und nächster Schritt

Versuch1 scheiterte vor Bubblewrap/DPKG an den drei Host-Lockdateien. Versuch2
besteht. Kein dritter Ansatz wurde gestartet. Das lokale Image besitzt kein
desktop-file-utils; deshalb wurde kein Desktopdatenbank-Trigger ausgeführt oder
als bestanden behauptet. Kein Trigger wurde unterdrückt. Auf Mint müssen dessen
vorhandene echte Trigger normal laufen; fehlschlagende Trigger sind ein Blocker.

Der nächste native Mint-Lauf benötigt weiterhin die von Root einzuholende
Freigabe für Transfer/SSH. Dann gelten dieselben RO-Gegenproben vor DPKG, normale
Abhängigkeiten und unveränderte Hosthashes. Das neue Paket kann über `--new`
später auf 0.41.16 zeigen; dieser Vorlauf behauptet keinen solchen Test.
Native GUI-/Desktopintegration ist ebenfalls nicht geprüft.

Die beiden eigenen Scaffold-Arbeitskopien wurden nach Sicherung dieser kleinen
Belege entfernt. Keine Testcontainer oder Namespaces bleiben aktiv. Die große
P11-Modellruntime und ihr Archiv aus dem anderen Teilauftrag bleiben unangetastet.

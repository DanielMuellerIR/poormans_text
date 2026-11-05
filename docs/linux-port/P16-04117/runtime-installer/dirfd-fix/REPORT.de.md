# Installer: reproduzierbarer veralteter DirectoryFD-Zustand

2026-11-05. Keine Produkt-Repoänderung durch diesen Agenten. Die beiden
ursprünglichen Root-Stages wurden nicht verändert.

## Konkrete Ursache und minimaler Beleg

Auf dem Host-btrfs mit Python3.14.9 genügt ein geöffnetes leeres Verzeichnis und
anschließend6 Unterverzeichnisse plus1 Datei, ausschließlich über dessen dirfd
angelegt. Passive /proc/self/fdinfo-Abfrage zeigt weiterhin Offset0. Trotzdem
liefert das erste os.listdir(alterFD) eine leere Liste, erst das zweite7 Einträge.
Bereits os.lseek(fd,0,SEEK_CUR) vor dem ersten Listing heilt das beobachtete
Fehlverhalten. Die anfänglich grünen Kleintests hatten durch genau diese
Positionsmessung den Fehler verdeckt. Es ist kein fehlender Runtimeinhalt und
kein bloß sichtbarer Endoffset. Der alte offene Enumerationszustand ist relevant;
die genaue interne Kernel-/Pythonursache ist damit noch nicht abschließend erklärt.

Beleg: evidence/passive-result.json und passive-probe.py. Alle eigenen kleinen
btrfs-Testbäume wurden entfernt.

## Kleiner Fix

Alle drei Tree-Listings verwenden directory_names(fd): openat(fd,'.') mit den
bestehenden O_DIRECTORY/O_NOFOLLOW/O_CLOEXEC-Flags erzeugt eine neue Open File
Description. Die Inodeidentität mit dem gebundenen Ursprungs-FD wird geprüft;
Listing und Close betreffen nur den neuen FD. Kein dup, kein lseek und kein
Wiederauföffnen über einen ungebundenen Hostpfad im Produktcode. Sämtliche
vorhandenen Snapshot-, Hash-, Modus- und NoReplace-Prüfungen bleiben erhalten.

Das echte kleine btrfs-Fixfixture liefert über den Helper sofort7 Einträge;
der ursprüngliche FD zeigt danach weiterhin seine fehlerhafte erste leere
Liste, seine fdinfo bleibt unverändert. Beleg: evidence/fixed-result.json.

## Ausgeführte Prüfungen und Grenzen

36/36 Tests auf Host Python3.14.9 und unter Python3.12.3 im vorhandenen
netzlosen, read-only pmt-linux-package-test mit UID1000 und64MiB tmpfs bestanden.
34 vorhandene plus2 neue Regressionen. libc fdopendir(dup(fd))/readdir bis EOF
bewegt den Ursprungs-FD tatsächlich ans Ende; der Helper inventarisiert trotzdem
vollständig und erhält dessen Offset. Ein vollständiger Tiny-Installerlauf mit
solchem Stage-EOF prüft jede Datei und publiziert erst nach vollständiger Prüfung.
Python os.scandir(fd) hatte hier den Originaloffset nicht verändert und wurde
für diese Regression deshalb durch libc-Readdir ersetzt.

Ein ausdrücklich autorisierter instrumentierter Lauf des ursprünglichen
Installers kopierte die vollständige echte Runtime und prüfte30193/30193 Dateien
inklusive Manifest. Held-/sichtbare Inodes waren identisch. Er publizierte nach
allen ursprünglichen Schutzprüfungen in den ausschließlich eigenen Testparent.
Dieser Lauf ist ausdrücklich KEINE Vollintegration des jetzt gelieferten Fixes:
Seine SEEK_CUR-Instrumentierung hatte den konkret belegten Heileffekt. Root
führt den finalen Fix ohne Trace/lseek separat aus.

Die eigene instrumentierte2GB-Kopie wurde anschließend FDgebunden und nach
Abgleich der aufgezeichneten Zielinode entfernt:30193 Dateien,2833 Verzeichnisse
und der eigene Parent. evidence/cleanup.json. Keine weitere Vollkopie ausgeführt.

Quellen und kleiner Patch liegen neben diesem Bericht, finale Testlogs und
unveränderte kleine Diagnosen unter evidence/. SHA256: delivery-manifest.json.

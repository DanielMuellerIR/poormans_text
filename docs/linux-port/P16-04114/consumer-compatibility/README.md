# P13: historischer echter Consumer gegen 0.41.14

2026-11-05: bestanden. Genau der bereits in P13 gegen 0.41.10 benutzte echte
Rust-Consumer ebb3feacdbab5b4ddf221b54b092697eb142d68f18cc6e84d03be29a5df2f061
war als versioniertes Example-Artefakt check_cli-8889c653b1ec4434 am vorhandenen
Fastra-Workspace-Buildpfad noch vorhanden. Der unversionierte check_cli zeigte
inzwischen auf ein anderes Artefakt und wurde ausdrücklich nicht verwendet.
Nur eine eigene Kopie des exakt passenden historischen Artefakts wurde gestartet.
Kein Build, keine Sourceänderung, kein Ersatzconsumer.

Der unveränderte Treiber erhielt genau ein Argument: den originalen PMT-Launcher.
CLI/Guard/Libs waren explizit read-only eingebunden. UID1000, privates HOME/TMP/
XDG-Profil, netzloser eigener Container aus dem vorhandenen qualifizierten
Arch-/Westonimage. Kein GUI-/Desktopstart. Kein Swift-LD-Pfad im Consumer;
der unveränderte PMT-Launcher setzt ihn ausschließlich für seinen CLI-Kindprozess.

replay.json: Exit 0, Katalog 0.41.14 mit 29 Formaten. Echte CSV: 1 Datei/1 Dokument,
table.md. Echte Plaintext-MBOX: 3 Dateien/2 Dokumente, index.md. Originaltreiber
führt prepare und adopt aus, prüft den übernommenen tatsächlichen Einstieg,
nichtleeren Markdowntext und unveränderte Quelldaten. Seine temporäre Wurzel war
nachher leer. Artefakthashes der Kopie und der Originaldatei sowie der CLI sind
vor/nach unverändert. Der Produzent ist das finale 0.41.14-Artefakt
8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb.

Grenze: alter echter Consumer → aktueller Producer, CSV/MBOX. Keine Behauptung
aktueller Fastra-ImportGUI, unabhängiger Consumer-Gitcommitbindung oder neuer
Formatmatrix. Dieser konkrete Treiber erzeugt keine Bildanhänge und keinen
bereits kollidierenden Zielnamen; Bildasset-/Kollisionsfälle wurden daher nicht
behauptet. Die Collection-Prüfung belegt zwei Dokumente, drei Ergebnisdateien
und den richtigen Einstieg, keine zusätzliche semantische ENEX-/RTF-Prüfung.

cleanup.json bindet die unveränderten Originalhashes und das Cleanup. Nach
Consumerende war der Container mit Exit 0 beendet; eigener Container, Consumer-
Kopie und gesamter privater Profil-/Workbereich wurden entfernt. Bestehende
Fastraartefakte und Produktdateien blieben unangetastet. Kleine Belege bleiben.

replay.py dokumentiert die wirkliche begrenzte Probe mit ihrem gegengeprüften
historischen Consumerhash. Wiederholung nur mit exakt ausgewähltem vorhandenem
Consumer und explizit gewählter CLI/Guard/Runtime; keine automatische Beschaffung.

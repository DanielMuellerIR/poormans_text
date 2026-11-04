# Linux-Entwicklungsstand

Die Linux-Portierung verwendet denselben Swift-Konvertierungskern wie macOS.
P05 stellt Build und Plattformgrenzen her; dies ist noch keine vollständige
Linux-App oder Distributionsfreigabe. PDF, OCR, Legacy-DOC und RTFD sind auf
Linux weiterhin nicht verfügbar. Die vorhandene Mac-App bleibt nativ.

## Lokal bauen

Benötigt werden Swift 6.2 oder neuer, Python 3 sowie die Entwicklungsbibliotheken
für zlib und libpng. Alternativ lässt sich ausdrücklich ein vorhandenes lokales
Docker-Buildimage wählen:

```sh
docker build -t pmt-linux-builder -f scripts/LinuxBuild.Dockerfile .
PMT_LINUX_BUILD_IMAGE=pmt-linux-builder ./build.sh debug
```

Ohne `PMT_LINUX_BUILD_IMAGE` verwendet `./build.sh` die native Swift-Installation.
Das Skript lädt kein Dockerimage automatisch herunter. SwiftPM-Abhängigkeiten
werden beim ersten Build aufgelöst; danach kann mit vorhandenem Cache offline
gebaut werden. Die Konvertierung selbst lädt keine Werkzeuge oder Inhalte nach.

Der Build erzeugt nur lokale Artefakte: den Launcher `poormans-text` im Repo-Root
und sein Paket unter `.build/linux-runtime`. Darin liegen die echte CLI und der
Prozessguard nebeneinander. Swift-Laufzeitbibliotheken sowie benötigte XML-/ICU-
und Bildbibliotheken werden für den Start ohne Swift-SDK mitgeliefert.
glibc und der ELF-Loader bleiben Systemabhängigkeiten.
Vorhandene Lizenz-/Hinweisdateien der Systembibliotheken, Swift-Laufzeit und
SwiftPM-Abhängigkeiten liegen unter `licenses`. Die abschließende Prüfung eines
verteilbaren Pakets einschließlich aller Lizenzbeigaben gehört zu P15.

Linux verwendet `Package.linux.resolved` und eine temporäre Quellkopie außerhalb
des Repositories. Der Mac-Lockfile `Package.resolved` wird dadurch nicht verändert.
Native und Docker-Buildcaches bleiben getrennt.

Die gemeinsamen und Linux-spezifischen Unit-Tests lassen sich in einer isolierten
Quellkopie mit `swift test --jobs 6` ausführen. Der echte Produktprüflauf lautet:

```sh
python3 scripts/linux-probes/verify_product.py ./poormans-text --pandoc /pfad/zu/pandoc
```

Der Prüflauf erzeugt seine Dokumente temporär und räumt sie selbst auf.

## Laufzeit und Grenzen

```sh
./poormans-text --formats --json
./poormans-text --json --report --output /neues/ziel -- /pfad/quelle.docx
```

Pandoc und `/usr/bin/bwrap` müssen für externe Konvertierungen lokal vorhanden
sein. Der PMT-Prozessguard gehört zum lokalen Build. Der Formatkatalog meldet
fehlende Werkzeuge und Plattformbackends; ein vorhandenes Werkzeug allein
belegt nicht die vollständige Unterstützung jeder Dokumentvariante.

Linux-Assets werden in diesem Meilenstein nur für statische PNGs tatsächlich
dekodiert und geprüft. Andere Bildformate und APNG sind nicht freigegeben.
Je nach bestehendem Importpfad führen nicht übernehmbare Ressourcen zu einem
Fehler oder einer Verlustdiagnose; daraus folgt keine Formatgleichwertigkeit
mit der Mac-Version.

Die Linux-Prozessaufsicht verwendet einen eigenen PID-/Netz-Namespace, gehaltene
Verzeichnis- und Prozessdeskriptoren und einen Lebensdauerkanal. Fehlende oder
gesperrte Namespaces führen zum Fehler; es gibt keinen unsicheren Fallback.
Ausgaben entstehen in einem privaten Bereich am Ziel und werden erst vollständig
atomar veröffentlicht. Zielkomponenten mit Symlinks werden derzeit abgewiesen.
Bei einem ausgetauschten Elternpfad bleibt ein vollständiges Ergebnis zur
Wiederherstellung erhalten; ein Erfolg für den inzwischen anderen Pfad wird
nicht gemeldet.

Paketinstallation, Desktopintegration, Linux-GUI und vollständige Backendabnahme
folgen in den weiteren Paketen des [Linux-Plans](LINUX-PORT.md). Die älteren
[Entscheidungsproben](linux-port/P03-FOLLOWUP.md) sind von der Produktintegration
und deren Prüfstand zu unterscheiden.

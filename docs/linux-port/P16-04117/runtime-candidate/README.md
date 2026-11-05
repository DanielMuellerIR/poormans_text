# Relocatable Docling CPU Runtime – begrenzter Integrationsnachweis

Prüfdatum 2026-11-05. Ergebnis: Eine eigene relocierbare CPython 3.12-Runtime mit den
bereits freigegebenen72 Wheelpins und fünf Modelldateien funktioniert offline,
unprivilegiert und read-only auf Ubuntu24.04/glibc2.39 sowie Arch/glibc2.44.
Ubuntu24.04 prüft die glibc-Basis von Mint22, keine native Mintinstallation.
Keine HostPython-ABI wird verwendet; Arch hat Python 3.14.9, der Worker nutzt
stets das mitgelieferte CPython 3.12.16. Keine globale Installation, kein SSH.

## Übergabe

- `candidate/`: gefrorene Runtime, alle Verzeichnisse555, Dateien444/555,
  keine Symlinks. Nur `bin/python3.12` ist der unterstützte Interpretervertrag.
  Von pip erzeugte Konsolenskripte enthalten Installationspfade und werden vom
  Adapter nicht verwendet. Für Pythonmodule ausschließlich diesen Interpreter
  mit `-I` verwenden.
- `candidate/runtime-manifest.json`: schemaVersion1, backend`docling`,
  qualifiedAdapterVersion1, Dateien als `files[relativePath]={sha256,byteCount}`.
  SHA256`cd4673de443d7e2570d6c4c4666cecb4924e2ceaf22703cba2a273a544eface6`.
  Das Manifest ist5.778.325 Bytes groß, bindet30.192 Dateien mit2.158.493.598 Bytes
  und enthält sich selbst nicht.
- `runtime-candidate.tar.zst`: reproduzierbar sortierte Pfade/Nullzeitstempel,
  813.143.585 Bytes, SHA256
  `45985c32d175440a3f6ade6e3a3e62daab2b173482c80dbb076fdb30984f2d70`.
  Vollständige Zstd-Integritätsprüfung bestanden. Entpacken erzeugt `candidate/`;
  dessen Verzeichnisname darf der aufrufende Adapter ändern.
- `tests-summary.json`, `post-run-integrity.json`: tatsächlich ausgeführte
  Prüfungen und unveränderte Inhaltsbestände nach dem Lauf.

Dies ist keine Distributionsfreigabe. Der Parent qualifiziert den Manifestdigest
zusätzlich über den echten ProcessRunner und dessen Sicherheits-/Fehlerpfade.
Ein lokal vorhandenes Manifest allein aktiviert kein Backend. Produktquellen
wurden durch diesen Teilauftrag nicht verändert.

## Bewusste Downloads und Reproduktion

`download-ledger.json` hält Quellen, Größen und SHA256 aller gespeicherten
Artefakte und Primärmetadaten fest:938.146.975 Bytes. Einschließlich10 MiB Reserve
für nicht gespeicherte Metadaten/HTTP-Fehlertexte liegt die Obergrenze bei
948.632.735 Bytes und damit unter1.073.741.824 Bytes. Netzwerk wurde nur zum Setup
verwendet; kein Inferenzlauf hatte Netzwerk.

CPython kommt aus dem offiziellen Astral-PBS-Release20261026:
`cpython-3.12.16+20261026-x86_64-unknown-linux-gnu-install_only.tar.gz`,
67.921.566 Bytes, SHA256
`6a79e922e50006b601f29e688407659da1c2b86ebcd4e9c7254cf234be8b89de`.
Das passende vollständige PGO/LTO-Archiv wurde ausschließlich für exakte
Buildmetadaten und C-Bibliotheklizenztexte zusätzlich geladen. Sein Interpreter
ist bytegleich zum install_only-Interpreter (`python-full-correspondence.json`).
Die kleinere install_only_stripped-Variante wurde nicht verwendet.

Wheel-/Modellpins bleiben unverändert unter
`REPO/scripts/linux-probes/p11/docling/{wheels.json,models.json,requirements-resolved.txt}`.
`setup_runtime.py --pins PINVERZEICHNIS --root NEUES_ARBEITSVERZEICHNIS` lädt nur
feste URLs mit Größen-/Hashprüfung und extrahiert Python/Modelle. Zuvor den
mitgelieferten `python-pin.json` ins neue Arbeitsverzeichnis kopieren. Anschließend
mit dem eigenen Interpreter offline installieren:

```sh
docker run --rm --network none --user "$(id -u):$(id -g)" \
 -v "$work:/work" -v "$pins:/pins:ro" \
 -e PYTHONDONTWRITEBYTECODE=1 -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
 pmt-linux-gui-test:latest /work/candidate/bin/python3.12 -I -m pip install \
 --no-index --find-links /work/downloads --require-hashes \
 -r /pins/requirements-resolved.txt
```

`extra_sources.py` archiviert das passende PBS-Fullarchiv und gepinnte
Modellkarten. `license_inventory.py` liest alle tatsächlichen Wheelmetadaten und
Lizenzdateien. `primary-license-evidence/` enthält zwei ergänzte Lizenztexte aus
exakten offiziellen Versionscommits sowie die CDLA-Lizenz aus festem Commit.
`libcrypt-downloads.json` bindet das kleine Noblepaket
`libcrypt1_4.4.36-4build1_amd64.deb` und seine passenden Sourcearchive. Nur dessen
`usr/lib/x86_64-linux-gnu/libcrypt.so.1.1.0` wird als `candidate/lib/libcrypt.so.1`
kopiert; Copyright und Sourcearchive stehen unter `candidate/notices/`.
Die Sourcearchive werden gegen die SHA256 aus der festen DSC-Datei geprüft;
eine zusätzliche OpenPGP-Signaturprüfung der DSC wird nicht behauptet.

Vor der finalen Manifestierung werden sämtliche tatsächlichen Lizenzdateien aus
`license-evidence/`, `primary-license-evidence/` und dem PBS-Fullarchiv unter
`candidate/notices/` übernommen. `finalize_runtime.py --pins PINVERZEICHNIS`
entfernt erzeugte Bytecodecaches, dereferenziert ausschließlich interne Dateilinks,
bindet alle Dateien per Hash und entzieht Schreibrechte. Es ist kein Installer.
Nach dem Freeze darf keine Datei ohne neues Manifest und neue Qualifikation
verändert werden. Die Reprohilfen sind auf diesen bewussten Probeaufbau begrenzt;
sie ersetzen keine spätere vertrauenswürdige Paketierung.

## Echte Runtimeprüfungen

Die vorhandenen Images `pmt-linux-gui-test:latest` und
`pmt-linux-arch-test:20261105` wurden ohne SDK-/HostPython-Nutzung gestartet.
Alle Inferenzläufe: `--network none --read-only --cpus 2 --memory 4g
--memory-swap 4g --pids-limit 256 --user 1000:1000`, eigenes512 MiB-`/tmp`-tmpfs,
Runtime read-only, ausschließlich eigenes Ergebnisverzeichnis beschreibbar.
Der Interpreter wird direkt unter seinem neuen Runtimepfad aufgerufen; kein
kopierter Interpreter und kein Python-ABI der Distribution.

`infer.py` weist JSON-Modellinferenz auf demselben unveränderten synthetischen
1800×1600 PNG nach. Noble: 5,82s, Arch: 5,91s; je eine Tabelle, unveränderte Quelle,
~0,83/0,92GB cgroup-Memorypeak. Das ist eine kleine Einzelmessung.

Zusätzlich lief der tatsächliche neue Produktworker `product-worker.py`:

```sh
runtime/bin/python3.12 -I product-worker.py runtime \
 verified.png '["eng"]' /own-work/document.json
```

Die endgültig gefrorene Runtime besteht den Worker auf Noble; die Runtime vor
reiner Manifestierung/Dereferenzierung besteht ihn auf Arch. Der Worker gibt nur
kleines Bindungs-JSON aus und schreibt das rohe Docling-Dokumentmodell. Es wird
kein Markdown als Konvertierungskern verwendet. Der Quellhash, die Bildmaße und
der geschriebene Dokumenthash sind nachgewiesen. Der natürliche vorhandene
Seite 132-PNG besteht denselben endgültigen Workerpfad mit9/9 Zelltexten und
korrekter Kopfzelle über zwei Spalten.

Qualitätsgrenzen bleiben sichtbar: synthetische Tabelle Noble 5/8 und Arch 4/8
exakte Zelltexte; A1/B1/C1 werden Al/Bl/Cl, auf Arch zusätzlich C2→Cc2. Kein
Solltext wird zur Korrektur eingesetzt. Geometrie-/Runtimefunktion und vollständige
OCR-Textqualität sind unterschiedliche Prüfergebnisse. Kein pauschales P11-Grün.

`elf-inventory.json`:397 ELF-Dateien, höchster referenzierter GLIBC-Stand 2.38.
Die eigentliche PBS-/Wheelbasis benötigt höchstens2.28; die ergänzte libcrypt
benötigt2.38 und bleibt damit unter Mint22/glibc2.39. Die Python-RPATH findet
`lib/` relativ zum Interpreter. Die optionale CPython-_crypt-Lücke auf Arch ist
mit dieser Bibliothek geschlossen. Breite Imports von _crypt, SSL, SQLite,
bz2, lzma, ctypes, Torch und Torchvision bestehen dort ebenfalls. Der erste
breite Importversuch ohne beschreibbares Tempverzeichnis scheiterte an Torch-
TemporaryDirectory; der getrennte Wiederholungslauf mit eigenem tmpfs besteht.
Der Fehlerbeleg wird nicht als ABI-Problem oder als bestandener Lauf ausgegeben.
Tesseract und trainierte Sprachdaten bleiben ausdrücklich externe Systemtools.

Die vollständige Manifestprüfung nach Inferenz bestätigt30.192unveränderte
Dateien und unveränderte synthetische Quelle. Keine eigenen Testcontainer bleiben
am Ende aktiv. Der Parent prüft zusätzliche Namespace-/Timeout-/Abbruch- und
Negativfälle über den tatsächlichen Produktadapter.

## Lizenzen

`licenses.json` enthält pro Wheel tatsächliche METADATA, deklarierte Lizenzfelder,
Klassifikatoren, Lizenzdateipfade/Bytes/Hashes und Projektquellen.70/72 Wheels
liefern selbst Lizenztexte. Tokenizers0.23.3 und latex2mathml3.81.1 bekommen ihre
fehlenden Texte aus offiziellen, über Versionstags bestimmten festen Commits.
Damit ist für72/72 Wheelpakete Textbeleg vorhanden. Die44 alten Indexeinträge ohne
Lizenzmetadaten sind in `licenses-closure.json` einzeln aufgeklärt:43 besitzen
Originaltexte im Wheel, Tokenizers erhält den ergänzten offiziellen Text.
Die meisten Indexlücken waren nicht ausgelesene `License-Expression`-Felder;
fehlende alte Indexfelder sind kein Beweis lizenzloser Pakete.

PBS-Fullarchiv: exakte PYTHON.json und21 gebündelte C-Lizenztexte bleiben erhalten.
Docling-Modelle: feste Modellkarten nennen CDLA-Permissive2.0, Heron Apache2.0;
kanonische Texte sind beigelegt. Die festen Modellrevisionen enthalten keine
separate LICENSE-Datei; entsprechende404-Versuche sind dokumentiert.

Offen bleibt die vollständige Prüfung von Weitergabe-, Copyright-, Notice- und
Source-Angebotspflichten aller eingebetteten Unterkomponenten. Das betrifft
insbesondere die mitgelieferten Bibliotheksammlungen in Torch, NumPy/SciPy,
OpenCV, PDFium, PBS und libcrypt. Originalnotices werden erhalten; Dateinamen-
oder Textmustererkennung wird nicht als juristische Freigabe dargestellt.
Keine Veröffentlichung oder Distributionsfreigabe wurde vorgenommen.

## Aufbewahrung

Die große Runtime und ihr Archiv bleiben bis zur Parententscheidung bewusst nur
in diesem temporären Bereich. Downloads sind Setupcache, keine dauerhafte zweite
Runtime. Kleine Manifeste, Skripte, Original-Lizenztexte und JSON-/Logbelege sind
zur Übernahme bestimmt. Nächster Prüfzeitpunkt: Qualifikation des tatsächlichen
Produktadapters; danach entbehrliche Setup-/Testkopien entfernen.

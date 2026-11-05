# Produktabschluss 0.41.17 und Freigabegrenzen

Stand: 2026-11-05. Swift bleibt der gemeinsame Konvertierungskern. Die optionale
strukturierte Linux-OCR ist jetzt im echten Bild-/PDF-Produktpfad integriert.
Die technische Entwicklungsabnahme besteht; die allgemeine Inhaltsqualität
bleibt ausdrücklich FAIL. Es wurde nichts öffentlich veröffentlicht.

## Ausgeführte Produktprüfungen

| Bereich | Ergebnis und Beleg | Grenze |
| --- | --- | --- |
| Linux / gemeinsamer Kern | [385 registrierte Fälle](backend-units-04117-final.log.gz), zwölf bestehende Skips, keine Fehler; echte Backends im SDK-freien Image | Keine vollständige Zielsystem-/Desktopmatrix |
| Native Mac-Regression | [1.085 registrierte Fälle](mac-native/source-binding.json), neun externe Corpus-Skips, 1.076 tatsächlich bestanden; beide Bundles nativ arm64, kein Skipfilter | Externe Referenzdaten bleiben offen |
| Quellbindung Mac | Alle [335 aktuellen Source-/Testdateien](mac-native/current-source-binding.json) samt vollständiger Dateimenge stimmen mit dem geprüften 602-Datei-Snapshot überein; [Originalmanifest](mac-native/source-manifest.json) | Spätere Dokumentations-/Prüfwerkzeugänderungen sind keine erneut getesteten Produktänderungen |
| GTK / Bridge | 40 und drei Unit-Tests bestanden, 18 bestehende externe Hostfälle ignoriert; [Clippy](clippy-04117.log.gz) ohne Warnungen | Kein Ersatz für native Desktopbedienung |
| GUI-Produkt | [Echter Modelllauf](gui/evidence.json), gespeicherte Auswahl nach Neustart, sichtbarer Approximationshinweis, Originalbild bytegleich; beide normalen Abschlüsse 0 | Privates Xvfb; Diagnoseklartext sichtbar, Code nicht separat aus dieser GUI erfasst |
| Lokale Pakete | [Drei finale Formate](packages-final.json): relocierte Unicode-CSV, Rechte, Hashes, Kollision und Symlinkelternschutz | Keine systemweite Hostinstallation oder öffentliche Distribution |
| Native Mint-Pakete | [Normales DPKG](mint-native/lifecycle.json) im privaten Root: .14 installieren, .17 aktualisieren, entfernen; CSV und Profil erhalten | Hostpakete/-datenbank bleiben unverändert, kein Desktopzugriff; [finales Paketdelta nur Changelog](mint-native/final-package-delta.json) |
| Native Mint-Runtime | [Vollinstallation und echte Inferenz](mint-native/summary.json), CPython aus eigener Runtime, native glibc 2.39/Btrfs; [Swift-Projektion des unveränderten JSON](mint-native/swift-projection.json) besteht | Modellkomponente mit temporären Noble-Tesseract-Abhängigkeiten; keine Behauptung installierter Hostbackends |
| Finale PDF-Integration | [Zwei echte erzeugte PDF-Fixtures](pdf-product/summary.json): Scan strukturiert erkannt, gemischte Seite mit explizitem konservativem Fallback; digitaler Originaltext exakt einmal, Quellen und Manifeste unverändert | Technische Übertragung, keine vollständige semantische Rekonstruktion |
| Modellabbruch | [Exit 130](model-cancellation.json), echter Modellworker und Tesseract-Nachkomme beobachtet; alle 21 beobachteten eigenen pidfds beendet, unabhängiger Prozess bleibt; kein Ergebnis/Staging | Gezielt der neue Modellpfad; frühere allgemeine Runnerverlustmatrix bleibt ihrem Artefakt zugeordnet |

## Laufzeit, Dateien und Ressourcen

Der feste Corepin bindet Manifest `cd4673de…`: 30.192 Inhaltsdateien,
2.158.493.598 Bytes, zuzüglich Manifest. Der Kern prüft reguläre Dateien ohne
Links/Hardlinks, vollständige Hashes und den exakten abgeleiteten Ordnerbestand
über gehaltene Deskriptoren. Unbekannte Dateien, leere Zusatzordner, Sonderdateien,
Traversierung und übergroße Pfade werden abgewiesen. Kein editierbares
Selbstfreigabefeld und kein Environmentoverride. Die Runtime bleibt bewusst
vertrauenswürdiger lokaler Programmcode; nachträgliche Schreibrechte desselben
Hostbenutzers sind keine zugesagte Angriffsgrenze.

Der [lokale Installer](../../../scripts/install_linux_ocr_runtime.py) lädt nichts
herunter, extrahiert nichts und installiert keine Hostpakete. Er kopiert nur
extern geprüfte lokale Quellen, prüft den vollständigen Stage erneut, setzt
sichere Modi und veröffentlicht mit `renameat2(RENAME_NOREPLACE)` im gehaltenen
Parent. Bestehende Ziele bleiben erhalten. [36 Regressionen und der echte
unveränderte Vollauf](runtime-installer/full-final.json) bestehen.

Zwei erste Vollkopien wurden vor Publikation sicher abgewiesen: Ein vor dem
Befüllen geöffneter DirectoryFD lieferte auf Btrfs zunächst eine leere Liste.
Der [minimale passive Repro und Fix](runtime-installer/dirfd-fix/REPORT.de.md)
belegen den Fehler; selbst SEEK_CUR-Messung verdeckte ihn. Jede Enumeration
öffnet jetzt dieselbe gehaltene Directoryidentität über `openat(fd, ".")` neu.
Die ursprünglichen fehlgeschlagenen Proben bleiben als solche dokumentiert.

Der Modellprozess erhält vor Imports AS 4 GiB, CPU 120 Sekunden, Dateigröße
8 MiB, zwei Rechenthreads und feste Offline-Einstellungen. **AS ist ein
Adressraumlimit je Prozess, kein aggregiertes RAMlimit des gesamten Jobs.**
Die zusätzlichen Docker-RAMgrenzen der Tests werden nicht als Produktlimit
behauptet. Der bestehende private PID-/Netz-Namespace und seine Lebensdauer-
barriere bleiben zuständig. Es gibt keine neue Prozessarchitektur.

Die vollständige Prüfung des Modells kostet zusätzliche Zeit. Nur ausdrücklich
gewählte strukturierte OCR nutzt diese Runtime. Standard bleibt `standard`.
Fehlende/veränderte Runtime ergibt 69 ohne Ergebnis; die native Mint-Gegenprobe
ist [gespeichert](mint-native/native-missing-backend.stdout). Originale DPI
werden ausschließlich im strukturierten Pfad erhalten; keine kanonische Dichte,
kein ROI und keine Solltextkorrektur werden erfunden. PDF verwendet die echte
Pixel-/Punktmatrix. Standard-/Preview-Raster bleiben bytegleich zur Vorprobe.

Basispakete schließen `structured-ocr` und behaltene alte GUI-Buildkopien aus.
Das ist keine öffentliche Modell-/Lizenzverteilungsfreigabe. Lokale Bereitstellung
und Grenzen: [Linux-Build](../../LINUX-BUILD.md). Die vollständige Quellen-/
Angebotspflichtprüfung für eine spätere öffentliche Modelldistribution bleibt offen.

## Automatische Inhaltsqualität

Die [zehn Formatfamilien](quality/families/families.json), 15 Raster-/OCR- und
13 PDF-Szenarien bestehen einschließlich kontrollierter Ablehnungen. RTFD prüft
zusätzlich den Hash der ursprünglichen TXT.rtf und unveränderte Originalassets.
Die [Gesamtauswertung](quality/summary.json) bleibt wegen natürlicher Text-/
Diagrammverluste und Modellfehlern FAIL.

Das neu versionierte synthetische Raster hat eine unabhängig aus Zeichenbefehlen
festgelegte Referenz. Der [echte finale Markdownvergleich](quality/structured-final/summary.json)
findet fünf von acht Zelltexten exakt; Al/Bl/Cl statt A1/B1/C1 bleiben Fehler.
Rasterform, abgedeckter Spanslot, Reihenfolge, Textkörper, Fingerprint und
Originalasset bestehen. Daraus wird keine vollständige Spangeometrie abgeleitet.
Die erste Auswertung verwechselte die leere Tabellenkopfzeile mit einer
Trennlinie; nur dieser Prüfer wurde korrigiert und die echte Inferenz gezielt
wiederholt. Originalfehler und Wiederholung bleiben getrennt erhalten.

Die [28 typisierten Vergleiche mit Tesseract-Bestmodellen](tesseract-best/REPORT.md)
rechtfertigen keinen Wechsel: gleicher synthetischer Fehler, kleiner Gewinn auf
Naturseite 132, insgesamt schlechteres Diagramm 134. Kein Schwellenwert wurde
abgeschwächt, kein Referenzzeichen ersetzt und kein Defaultmodell gewechselt.

## Fastra und Abschlussentscheidung

Der zusätzliche [finale .17-Launcher-Smoke](fastra-04117-debug/README.md)
besteht zwei echte GTK-MBOX-Importe ohne vom Test gesetzte Bibliothekspfade.
Er bindet einen ausdrücklich uncommittierten Debug-Consumersnapshot und ist
keine neue Consumer-Produktionspaketabnahme.

Der [echte .16-/Fastra-1.165.1-Lauf](fastra-04116/REPORT.md) bestätigt den additiven
RTFD-Vertrag samt optionaler TXT.rtf-Identität und Adoption. Der bestehende
Importweg ist verwendbar; strukturierte OCR ist keine Voraussetzung. .17 ändert
weder Protokollversion noch normalen Consumeraufruf. Die endgültige unveränderliche
Übergabe bindet den gesicherten Produktcommit und alle aktiven Runtimebytes;
ältere .15-/ .16-Belege werden nicht auf .17 umetikettiert.

Die bekannte Mac-Testblockade ist lokalisiert: Der Mock verwendete einen globalen
Task.sleep-Wakejob bei vollständig blockiertem kooperativem Pool. Ein echter
externer Callback und das originale Gate bestehen; der Test prüft Kontext vor
und nach Await sowie 24 serialisierte Caller. Der Produktalgorithmus blieb
unverändert. [Befund und Grenze](../OCR-BRIDGE-REGRESSION/README.md).
Ein Hostneustart zerstörte den ersten nativen Vollbeleg; seine genaue frühe
Abbruchursache wird nicht erfunden. Der zweite unveränderte Lauf besteht mit
stabiler Bootidentität und fortlaufend lokal gesicherten Logs.

Empfehlung: als lokal geprüfte Linux-Entwicklungsvorschau und Fastra-Producer
weiterverwenden. Eine uneingeschränkte Linux-Freigabe bleibt wegen offener
natürlicher Qualitätsdaten, belegter Erkennungsverluste, echter Desktop-/Portal-
und vollständiger Systemabnahme gesperrt. Der Anwender prüft anschließend die
zusammenhängende GUI-Bedienung; er ersetzt damit keine automatischen Qualitätstests.

Alle vier [Nacht-Review-Funde](../REVIEW-2026-11-05.md) sind individuell geprüft
und im zuständigen Reviewstatus erledigt. Es gibt keinen GitHub-Push.

## Aufräumen und Reproduktion

[Mint-Cleanup](mint-native/controller-cleanup.json) und native Mac-Cleanups
([Work](mac-native/cleanup-work.json), [Proof](mac-native/cleanup-proof.json))
bestätigen die Entfernung ausschließlich eigener Testwurzeln, Belegarchive und
Prozesse nach lokaler Hashsicherung. Keine Hostinstallation, kein Desktopzugriff.
Screenshots und vollständige private Hostdiagnosen bleiben außerhalb des Repos;
kleine Rohbelege, feste Fixtures und reproduzierbare Prüfskripte bleiben erhalten.
Der [lokale Cleanup](local-cleanup.json) entfernt die bekannten entbehrlichen
Arbeitskopien nach Belegsicherung, darunter beide verworfenen2GB-Stages.
Nächste Referenzprüfung: 2026-12-05; aktuelle Entwicklungslaufzeit, Pakete und die qualifizierte
Offlinequelle bleiben bewusst als nutzbarer Entwicklungsstand erhalten.

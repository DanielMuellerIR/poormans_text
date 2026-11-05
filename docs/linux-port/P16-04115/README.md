# Produkt- und Schnittstellenabschluss 0.41.15

Stand: 2026-11-05. Swift bleibt der gemeinsame Konvertierungskern. Dieser
Entwicklungsstand priorisiert den benutzbaren bestehenden Fastra-Importvertrag,
sichere Linux-ENEX-PDF-Anhänge und die verifizierte Abarbeitung des Nacht-Reviews.
Kein neuer Protokollindikator, kein zweiter Konverter und keine Veröffentlichung.

## Tatsächlich geprüfte Änderungen

- Linux validiert ENEX-PDF-Anhänge in einem eigenen gebundenen Arbeitsbereich
  über den bestehenden lokalen Poppler-Prozess. Normale und verschlüsselte
  Anhänge bleiben unverändert als PDF erhalten. Nur Popplers typisierter
  Verschlüsselungsfehler gilt als verschlüsselt; beschädigte/falsche Typen
  scheitern vor Publikation. Vier echte Fälle bestehen: [Ergebnisse](enex-pdf-positive.json).
- Fehlende PDF-Fähigkeit passiert die ENEX-Fehlergrenze unverändert mit 69,
  ohne Ergebnisordner. [Produktprobe](enex-pdf-missing.json); dieselbe neue
  Prüfung scheitert am unveränderten alten .14 mit 65: [Gegenprobe](enex-pdf-old-negative.json).
- Der ungenutzte Guard-Override ist entfernt. Aktive read-only Eingabebindungen
  und der verpflichtende Guard bleiben erhalten. Alle [17 Runnerverlustfälle](runner-loss-04115.json)
  bestehen einschließlich abgetrennter Kinder und verlorener Besitzer.
- Gemeinsame/Linux-Regression mit realen Backends: 353 Fälle, 12 ausdrücklich
  übersprungen, 0 Fehler. [Unverändertes Protokoll](backend-units-final.log.gz).
  Der geprüfte Logikstand wurde vor dem abschließenden reinen Versionswechsel
  gebaut; Version/Bundlezählung sind zusätzlich konsistent auf .15/100 geprüft.
  Kein vollständiger neuer Mac-Regressionslauf wird behauptet.
- [Drei Pakete](packages.json): echte relocierte Unicode-CSV, Rechte, Hashes,
  Kollision 73 und Symlinkelternschutz bestanden. Paketprüfung auf dem nativen
  Linux-Host; dies ist keine neue Mint-Installation oder Desktopabnahme.

Die [vier Nachtfunde](../REVIEW-2026-11-05.md) sind individuell geprüft:
ENEX-Fehler und redundanter Pfad korrigiert, ungenutzter Override entfernt,
CF-Speicherleckbehauptung durch Compiler/SIL widerlegt. Kein manuelles CFRelease.

## Fastra kann den Vertrag verwenden

Die [echte aktuelle Vollmatrix](../P13-CURRENT-EVIDENCE/REPORT.md) gehört
PMT .14/Fastra 1.164.0/372. [Der gezielte .15-Dialoglauf](fastra/REPORT.md)
bestätigt unveränderten DOCX-/Bild-/Tabellenimport sowie gesperrte Adoption
beider ENEX-PDF-Quellen bei tatsächlich fehlendem Backend. Positive ENEX-PDF-
GUI-Importe sind in dieser WebKit-Testumgebung nicht ausgeführt; die getrennten
positiven Produkt-CLI-Läufe oben gelten dafür nicht als Ersatz.

[Artefakte und SHA256](artifacts.json) binden CLI, Guard, GTK und drei Pakete.
Die Consumer-Quellen bleiben unverändert; dessen übrige Portierung bleibt
Fastras eigener Auftrag. Optionale strukturierte OCR blockiert diesen Vertrag nicht.

## Inhaltsqualität bleibt eine eigene automatische Freigabe

Der [automatische Qualitätslauf](../../CONVERSION-QUALITY.md) besteht zehn
synthetische Formatfamilien, 15 Raster-/OCR- und 13 PDF-Szenarien einschließlich
kontrollierter Ablehnungen. Der [tatsächliche Gesamtbericht](quality/summary.json)
ist wegen der natürlichen Text-/Tabellenverluste ausdrücklich FAIL. Alle sechs
natürlichen Konvertierungen bestehen die Byte-/Ausgabemanifestintegrität; dies
wird nicht als Inhaltsvollständigkeit ausgegeben. Die ausführliche unabhängige
[Verlustanalyse](../QUALITY-EVIDENCE-04114/README.md) und der DPI-Gegenversuch
bleiben erhalten. Kein Schwellenwert wurde zum Grünmachen abgeschwächt.

Vollständige Linux-Freigabe bleibt gesperrt: strukturierte OCR-Produktintegration,
breiterer Qualitätskorpus, echte Desktop-/Portalbedienung, Mint-Paketinstallation
und bekannte Mac-OCR-Testblockade sind getrennte Restarbeit. Die bestandenen
Komponentenproben ersetzen keine Produkt- oder Desktopintegration.

## Reproduktion und Aufbewahrung

`scripts/linux-probes/p13/verify_enex_pdf.py` erzeugt seine ENEX-Quellen aus dem
versionierten unabhängigen PDF-Fixture; im Backend-Testimage ist qpdf nötig.
Mit `--missing-backend` erwartet derselbe Prüfer 69 in der gezielt fehlenden
GI-Umgebung. Keine Downloads. Kleine Rohreports, Quellen und Logs bleiben für
Regressionen erhalten; GUI-Screenshots liegen privat außerhalb des Repositories.
Nächste Referenzprüfung: 2026-12-05. Entbehrliche Laufkopien werden nach Sicherung
entfernt; aktuelle Entwicklungspakete bleiben bewusst erhalten.

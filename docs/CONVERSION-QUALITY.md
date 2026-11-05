# Automatische Umwandlungsqualität

Die Linux-Abnahme trennt Quell-/Dateiintegrität, Formatkorrektheit, inhaltliche
Qualität und echte Desktopbedienung. Ein Exit 0 oder ein passender Ausgabeshash
beweist allein keine vollständigen Texte oder Tabellen. Die GUI-Abnahme des
Anwenders ersetzt die automatischen Inhaltsprüfungen nicht.

## Wiederholbarer Produktlauf

Bei bewusst bereitgestellter lokaler Laufzeit, Werkzeugen und Sprachdaten:

```sh
python3 scripts/linux-probes/quality/run_quality.py \
  --repo "$PWD" --cli "$PWD/.build/linux-runtime/bin/poormans-text" \
  --expected-cli-sha256 "$REVIEWED_CLI_SHA256" --root /tmp/pmt-quality-new
```

`REVIEWED_CLI_SHA256` aus dem zum Produkt gehörenden Artefaktbericht übernehmen.
Der Ergebnisordner muss neu sein. Keine Modelle, Werkzeuge oder Dateien werden
heruntergeladen. Für die vorhandene SDK-freie Testumgebung und konkrete
Artefakthashes siehe [0.41.15](linux-port/P16-04115/README.md).

Der Lauf verwendet temporär erzeugte DOCX-, ODT-, EPUB-, CSV-, XLSX-, RTF-,
RTFD-, MBOX-, ENEX- und PPTX-Dokumente. Solltexte, Reihenfolgen und Tabellenzellen
entstehen unabhängig vom Konverter. Originalbilder, Quelldateien und sämtliche
Ausgabemanifeste werden verglichen; eine Gegenprobe mit absichtlich entferntem
Solltext muss scheitern. Dazu kommen die bestehenden Raster-/OCR- und PDF-Proben,
einschließlich erwarteter Ablehnungen, sowie der fixierte lizenzierte natürliche
[Referenzkorpus](linux-port/P11-NATURAL-EVIDENCE/CORPUS.md).

Die Swift-Tests ergänzen diese End-to-End-Proben um zahlreiche komplexere
Formatvarianten, Unicode, Metadaten, Auswahl, Links, Mailanhänge und Sicherheits-
grenzen. Externe private Mail-/MSG-Korpora sind optional und werden bei Fehlen
übersprungen. Ein fehlender unabhängiger Leser wird nicht durch einen Vergleich
des Konverters mit sich selbst ersetzt.

## Ergebnisauswertung

Exit 0 bedeutet, dass alle angeforderten Prüfgruppen bestanden wurden. Exit 1
meldet mindestens einen Fehler; Exit 2 eine unvollständige Abnahme mit Skips.
`summary.json` nennt jede Gruppe und deren Status. Natürliche Text-/Zellbestände
und Reihenfolge werden getrennt von Byteintegrität bewertet. Erwartete Verluste
werden sichtbar dokumentiert, jedoch nicht durch gelockerte Sollwerte als
inhaltlich vollständig umgewertet.

Der aktuelle natürliche Korpus ist **nicht vollständig grün**. Bildbeschriftungen
und Diagrammwerte fehlen teilweise als durchsuchbarer Text; die Bildassets sind
erhalten. Zelltexte der Referenztabelle sind vorhanden, ihre Tabellen-/Spanstruktur
fehlt im Standard-PDF-Weg. Die [Analyse samt DPI-Gegenversuch](linux-port/QUALITY-EVIDENCE-04114/README.md)
zeigt auch, weshalb pauschal höhere OCR-Auflösung keine belastbare Reparatur ist:
Sie verbessert einen Fall und erzeugt in einem anderen zusätzliche Erkennungsfehler.
Strukturierte OCR bleibt bis zur gesonderten Produkt-/Qualitätsfreigabe deaktiviert.

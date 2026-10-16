# Quelle und Ergebnis prüfen

**Vergleichen** öffnet nach einer Konvertierung die gerenderte Ergebnisvorschau
und ihre Diagnosen. Für PDF und Rasterbilder steht die ausgewählte Quellseite
beziehungsweise der Bildframe daneben. Vor/zurück und Einpassen/Zoom verändern
nur die Ansicht. Quelllinks sind inaktiv; die App rastert die geprüften Bytes,
statt interaktive PDF-Aktionen auszuführen. Die Quelle bleibt unverändert.

Die App zeichnet für neue Konvertierungen Quellzuordnungen und Ausgabehashes auf;
sie schreibt dabei keinen zusätzlichen Bericht. CLI und Library behalten ihre
bisherigen opt-in-Optionen aus [CONVERSION-REPORT.md](CONVERSION-REPORT.md).

## Fundstellen und Diagnosen

Diagnosen lassen sich nach Information, Näherung oder bekanntem Inhaltsverlust
und nach dem angezeigten Fundstellentext filtern. Eine ausgewählte Diagnose zeigt
ihren vollständigen Text und stabilen Code. Bekannte PDF-Seiten, Bildframes,
Tabellenzellen und Folien steuern die aufgezeichneten Ergebnisbereiche an.
Unbekannte Fundstellen bleiben ausdrücklich unbekannt.

Für andere Formate ersetzt die App keine Office-Seitenansicht. Der
Abschnittswähler führt zu bekannten Blättern oder Folien; bei einem gewählten
Tabellenblatt lässt sich zusätzlich eine Zelle wie `B4` ansteuern. Gibt es nur
eine Abschnittszuordnung, meldet die App diesen gröberen Bezug. Mehrdeutige
Zellbezüge ohne Blatt werden nicht einem beliebigen Blatt zugeordnet.

Die Abschnittsliste zeigt höchstens 2.048 Einträge. Grenzen der aufgezeichneten
Zuordnungen bleiben als Diagnosen sichtbar. Positionen außerhalb des
[256-KiB-Vorschauausschnitts](MARKDOWN-PREVIEW.md) werden nicht vorgetäuscht;
die vollständige Ergebnisdatei bleibt verfügbar.

## Geprüfte Dateistände

Die Quellenprüfung hasht einen vollständigen sicheren Lesevorgang. Der
PDF-/Bildrenderer erhält genau dessen unveränderliche Bytes. Die Ergebnisanker
verwenden ebenfalls die beim Lesen gegen das Ausgabemanifest geprüften Bytes.
Eine Hashübereinstimmung belegt die Byteidentität, keine Inhaltsvollständigkeit.

Ändert sich die Quelle oder ihr Verzeichnis während des Vergleichs, entfernt die
App das Quellbild und sperrt die Zuordnung bis **Erneut prüfen**. Die
Verzeichnisüberwachung reagiert vorsichtshalber auch auf andere unmittelbar
daneben angelegte oder ersetzte Dateien. Fehlende, veränderte, nicht sicher
lesbare und unbelegte Quellen erhalten unterschiedliche Meldungen. Ein
Ergebnis ohne passenden Ausgabehash erlaubt weiterhin das Lesen und Suchen,
aber keine Positionssprünge.

## Grenzen

- Quellen werden bis 1 GiB vollständig geprüft; für die Quellansicht werden
  höchstens 128 MiB Dateibytes gehalten.
- PDF-Seiten und Rasterframes erscheinen als begrenzte Vorschaubilder mit
  höchstens 2.048 Punkten beziehungsweise Pixeln pro Kante. Zoom ergänzt keine
  Details, die im Vorschaubild fehlen.
- Rasterbilder erlauben höchstens 1.000 Frames und 64 Millionen Quellpixel je
  dargestelltem Frame. Es werden nur die unterstützten lokalen Rasterformate
  dekodiert; SVG und fremde Ressourcen werden nicht geladen.
- Die Quellenansicht ist kein Editor und rekonstruiert keine Word-/Excel-Layouts.
  Papierseiten, Bildframes und Ergebnisabschnitte behalten die Nummern und Namen
  ihrer Quelle.
- Nicht jeder Import besitzt Textzuordnungen, etwa Bilder mit deaktivierter OCR
  und derzeitige Pandoc-Importe. Die Quelle kann trotzdem bytegenau geprüft sein;
  fehlende Ergebnispositionen werden als Information gemeldet.

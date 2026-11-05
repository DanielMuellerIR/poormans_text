# P07/P08: vorhandene Formate und Sammlungen auf Linux

Stand: 2026-11-05, Produktstand 0.41.9. Tabellen, Präsentationen, Notebooks,
Mail, ENEX und ODM benutzen dieselben vorhandenen Swift-Adapter wie macOS.
Es gibt keine zweite Parserimplementierung. Die Linux-SwiftPM-Konfiguration
führt ausgewählte Originaltests direkt aus ihrem bisherigen Verzeichnis aus;
Swift-Markdown dient nur dem unabhängigen AST-Vergleich in Tests.

## Produktkorrekturen

FoundationXML auf Linux kann trotz falsch verschachteltem XML Erfolg melden und
interne Entity-Deklarationen nicht an die Delegates weiterreichen. Der gemeinsame
Importpfad prüft deshalb unter Linux zusätzlich den Parserfehler und lehnt interne
DOCTYPE-Subsets vor der Interpretation ab. UTF-7-Shiftsequenzen und IBM037 konnten
diese Vorprüfung umgehen; jetzt gilt eine ausdrücklich geprüfte Encodingmenge:
UTF-8, UTF-16/LE/BE, UTF-32BE, US-ASCII, ISO-8859-1 und Windows-1252.
UTF-32LE und der generische UTF-32-Deklarationsname bleiben wegen tatsächlich
beobachteter FoundationXML-Grenzen ausdrücklich unverfügbar. RTF-/MIME-Codepages
werden dadurch nicht eingeschränkt; der Mac-XML-Parser bleibt unverändert.

Ein spät fehlerhaftes ENML-Dokument darf keine teilweise erfolgreiche Sammlung
publizieren. Sieben dauerhafte XML-Regressionen prüfen dies sowie positive
Unicode-/Legacytexte, Kommentare, CDATA und die tatsächlich gefundenen Encodingumgehungen.

Linux-Dateipfade werden außerdem bytegetreu unterschieden. Damit entfallen weder
NFC-/NFD-Quellen im Stapel noch unterschiedliche lokale Assets durch Swift-Stringgleichheit.
Notebook-JSON mit kanonisch kollidierenden Objektschlüsseln wird vor Foundation
explizit abgewiesen, weil Foundation diese bereits beim Decodieren zusammenfasst.
Beide Unicode-Schreibweisen sind einzeln erlaubt; es gibt keine pauschale NFD-Sperre.

## Ausgeführte Abnahme und offene Grenzen

Der eigenständige P07/P08-Lauf umfasste 250 vorhandene Fachtests und sieben neue
XML-Regressionen: 249 bestanden, acht mit ausdrücklich benannten fehlenden externen
Referenzen bzw. fehlendem Pandoc-XLSX-Reader übersprungen, null Fehler.
Die abschließende integrierte Suite wird im [P06-Bericht](P06-INTEGRATION.md) geführt;
die Zahlen werden nicht als zusätzliche unabhängige Abdeckung addiert.

28 echte CLI-Fälle prüfen CSV/TSV, Office-Tabellen und Varianten, Blatt-/Zellbereiche,
Präsentationen und Folien/Notizen, Notebook-Outputs ohne Ausführung, EML/EMLX, MSG,
MBOX als Datei/Paket, ENEX und ODM. Inhalte, Reihenfolge, ausgewählte Quellpositionen,
Assets und Quell-/Ausgabehashes sind unabhängig geprüft. ODM enthält zwei geordnete
lokale Teilkapitel mit zwei bytegleichen Bildern; fremde Pfade werden nicht geladen.
Kleine Belege stehen unter [P07-P08-EVIDENCE](P07-P08-EVIDENCE/final-evidence.json).

Die übersprungenen privaten Mail-/MSG-Korpora und der unabhängige XLSX-Pandocvergleich
sind keine bestandenen Prüfungen. Native Mac-Regression und vollständige Zielsystem-
Abnahme dieses neuen gemeinsamen Stands bleiben offen. Die Fastra-Verbraucherprüfung
und die spätere GUI-Integration sind eigenständige Abnahmen.

# Präsentationen importieren

PPTX, PPTM, POTX und ODP werden nativ ohne Pandoc gelesen. Der Konverter lädt
keine entfernten Ressourcen und führt keine Makros oder eingebetteten Programme
aus. Jede Folie bekommt einen Abschnitt `## Slide N`; ihre Reihenfolge stammt
bei OOXML aus `presentation.xml` und dessen Beziehungen, bei ODP aus der
Elementreihenfolge in `content.xml`, nicht aus Dateinamen oder Foliennamen.

## Übernommene Inhalte

Textabsätze und explizite Listenebenen, Tabellen, Notizen und unterstützte Bilder
wandern über dasselbe Folienmodell in Markdown. Listen erhalten ihre Hierarchie;
explizite OOXML-Nummerierungen sowie ODP-Listenstile aus `styles.xml` und den
automatischen Stilen werden zu nummerierten Listen. Notizen erscheinen unter
`### Notes` als Blockzitat und können ebenfalls Tabellen und Bilder enthalten.
Bilder werden anhand ihrer Bytes erkannt, mit SHA-256 dedupliziert und unter
`images/` gespeichert. Mehrere Verweise auf dasselbe Bild bleiben erhalten.
Frontmatter verwendet die vorhandenen Leser für `docProps/core.xml` und
OpenDocument `meta.xml`.

Die Ausgabe erhält Text in der Dokumentreihenfolge. Position, Theme, Animation,
Übergänge und genaue Schriftgestaltung werden nicht nachgebildet. Vererbte
OOXML-Listenformatierung aus Layouts/Mastern wird bei betroffenen Absätzen
explizit diagnostiziert; Text bleibt erhalten. Benutzerdefinierte Nummerierung
und Startwerte werden nicht exakt reproduziert. Hyperlinks aus Text, Tabellen
und Notizen behalten ihre getrennten Textbereiche und sicheren Ziele.
Tabellenverbünde werden abgeflacht; verschachtelte
ODP-Tabellen landen einmal im Text der äußeren Zelle und erhalten eine Diagnose.
Diagramme, SmartArt-Beziehungen, Video, Audio und OLE-Objekte werden diagnostiziert,
aber nicht rekonstruiert. Makros werden nie ausgeführt oder kopiert.

## Hyperlinks und Folienziele

Jede ausgegebene Folie besitzt einen stabilen Anker `<a id="pmt-slide-N"></a>`
mit ihrer ursprünglichen Nummer. Interne OOXML-Slide-Beziehungen sowie eindeutige
ODP-Seitennamen/-IDs führen dorthin. ODP-Fragmente werden einmal percent-dekodiert;
auch die Typkennung `|page` wird unterstützt. Mehrdeutige, fehlende oder durch
`--slides` ausgeschlossene Ziele bleiben als sichtbarer Text mit Diagnose stehen.
Die Zuordnung folgt der Dokumentreihenfolge, nicht der Zahl im XML-Dateinamen.

Mehrere Links pro Absatz oder Zelle bleiben getrennte Textbereiche. Explizite
OOXML-Run-Links haben Vorrang vor Absatz-/Shape-Defaults; ODP-Textlinks vor einem
umgebenden Shape-Link. Benachbarte Bereiche mit identischem Ziel dürfen zusammen
erscheinen. Mehrzeilige Links behalten ihre Zeilen; Tabellen nutzen `<br>`.
Linktexte und URI-Sonderzeichen werden maskiert, einschließlich `&`, Klammern,
Pipes und Unicode. Die externe Auswahl erlaubt HTTP, HTTPS und Mailto ohne
Steuerzeichen; Webziele mit eingebetteten Zugangsdaten, Dateiziele und nicht
aufgelöste relative Ziele bleiben mit Verlustdiagnose nicht klickbar.

Statische PowerPoint-Sprünge zur ersten/letzten/nächsten/vorherigen Folie erhalten
einen passenden internen Link. Verlaufssprünge, benutzerdefinierte Shows,
Programme, Makros und sonstige Aktionen werden nicht ausgeführt oder als normale
Weblinks ausgegeben. Mouse-over-Ziele werden nicht zu Klickaktionen umgedeutet.
Bildlinks haben keinen unterstützten Textbereich und werden mit Diagnose
abgeflacht; die vorhandenen Bildbytes bleiben erhalten. Linkziele lösen niemals
Ressourcenladen aus. Die App-Vorschau zeigt die Links und ihre Ziele, lässt sie
aber wie bisher inaktiv; nur exakt leere generierte Folienanker werden umgesetzt.

## Sicherheits- und Ressourcengrenzen

Die Erkennung liest einen nicht gemappten ZIP-Snapshot. Vor der Konvertierung
legt der Paketleser selbst eine private Arbeitskopie an und prüft alle Einträge
vollständig, einschließlich CRC, Größen, Symlinks und Pfadgrenzen. Relative
Beziehungen dürfen innerhalb des Archivs auf übergeordnete Verzeichnisse zeigen;
absolute Pfade, Archivflucht und externe Ressourcen werden nicht geladen.

Die bestehenden ZIP-Grenzen gelten: 1 GiB Quelle/entpackte Gesamtdaten und
10.000 Einträge. Ein XML-/Medieneintrag darf höchstens 16 MiB haben. Größere oder
nicht unterstützte Bilder werden ausdrücklich als `presentation.imageUnavailable`
gemeldet; es gibt keine stille Auslassung. Die Medienausgabe ist auf 1.024 Bilder
und 128 MiB begrenzt. XML wird ohne Entitätsdeklarationen mit höchstens 200.000
Knoten, 128 Ebenen und 16 MiB Text pro Teil gelesen. Ein Dokument hat höchstens
1.000 Folien. PPTX-Slide-XML wird folienweise freigegeben; ODP enthält alle Folien
in einem begrenzten `content.xml`.

ODP-Tabellen haben höchstens 256 Spalten und 1.000 Zeilen. Vor Wiederholungen
prüft der Parser einen konservativen UTF-8-Ausgabebedarf einschließlich
Markdown-Maskierung. Expandierte Absätze dürfen höchstens 16 MiB, ihr gesamter
Text höchstens 128 MiB belegen. Zusätzlich gelten höchstens 8.192 gelesene Quell-Linkdefinitionen und
8.192 UTF-8-Bytes pro externem Ziel; Linkexpansion wird vor Materialisierung und
Tabellenwiederholung gegen das Ausgabebudget geprüft. Der Renderer prüft jede Vergrößerung des Markdown
gegen das verbleibende Dokumentbudget von 128 MiB. Nach 256 einzelnen Diagnosen
folgt die Zahl der weiteren ausgelassenen Diagnosen.

Fortschritt nennt die Folie. Abbruch wird vor/nach Parsern, in XML-Ereignissen,
bei Folien und im Renderer geprüft. Fertige andere Batch-Ergebnisse bleiben
bestehen; das laufende Dokument wird nicht teilweise veröffentlicht.

## Nachweis

`PresentationNotebookTests` erzeugt echte ZIP-Pakete mit absichtlich von den
Dateinamen abweichender Folienreihenfolge, verschachtelten Listen, Tabellen,
Notizen und identischen Bildverweisen. Tests zählen jeden Textmarker, vergleichen
Bild- und Quellenbytes und prüfen mit lokal vorhandenem Pandoc die GFM-Struktur
von Tabellen und nummerierten Listen. Weitere Fixtures prüfen CRC-Fehler in
ungenutzten Medien, Bilder über 16 MiB, wiederholte ODP-Zellen/Leerzeichen,
Entitätsdeklarationen, fehlenden Inhalt und Abbruch vor Veröffentlichung.


`PresentationLinkTests` erzeugt echte PPTX/PPTM/POTX/ODP mit jeweils sieben
Hyperlinks, mehreren Links pro Zelle, internen Zielen und Notizlinks. Ein
unabhängiger Markdown-Parser prüft die tatsächlichen Ziele, Textmarker und
Bytevergleiche die Quellen/Assets. Weitere Fälle prüfen Auswahl, Textbundle,
Defekt-/Aktionsdiagnosen, Defaults, Unicode, Mehrzeilen und atomare Budgets.
`PreviewWebTests` prüft echte WebKit-Ausgaben in Hell/Dunkel und verhindert aktive
Navigation oder nachgeladene Ressourcen.

Primärquellen: [OOXML-Klickaktionen](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oe376/7ff3db24-b7b9-4ffe-aa78-3ec47cab2489),
[OpenDocument-1.3-Schema](https://docs.oasis-open.org/office/OpenDocument/v1.3/OpenDocument-v1.3-part3-schema.html).

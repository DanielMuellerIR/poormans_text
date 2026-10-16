# EPUB-Kapitel auswählen

```sh
poormans-text --list-chapters --json book.epub
poormans-text --epub-chapters 1,3-5 --report book.epub
```

Ohne Auswahl bleibt der bisherige zusammengeführte EPUB-Import bestehen.
`--epub-chapters` verwendet einsbasierte geschlossene Intervalle und
Einzelnummern. Doppelte Nummern werden dedupliziert, ungültige oder außerhalb
des Buchs liegende Bereiche abgewiesen. Die Ausgabe folgt dem OPF-Spine,
unabhängig von Dateinamen und ZIP-Reihenfolge. Es entsteht weiterhin genau
eine Markdown-Datei.

## Kapitel und Navigation

Ein auswählbares Kapitel entspricht einem Spine-Eintrag mit einer vorhandenen
lokalen XHTML-Datei. Die ursprünglichen Indizes beziehen auch ergänzende
Einträge (`linear="no"`) ein. Eine ausdrückliche Auswahl darf diese übernehmen;
der Import ohne Auswahl behält Pandocs bisherige primäre Lesereihenfolge.

Navigationsabschnitte und Fragmente sind Übersichtsdaten. Mehrere Abschnitte
derselben XHTML-Datei bilden keine zusätzlichen auswählbaren Kapitel;
die Datei wird vollständig übernommen. Wiederholte Spine-Verweise und mehrere
Spine-Einträge auf dieselbe Datei werden bei Übersicht/Auswahl kontrolliert
abgewiesen, damit Inhalte und Fragmentziele nicht mehrdeutig werden.

Gewählte interne Kapitel-/Abschnittslinks werden auf generierte lokale Anker
umgebunden. Die Anker bestehen ausschließlich aus vom Konverter erzeugten
Kennungen; fremdes HTML bleibt im bestehenden sicheren Konvertierungsweg.
Ein Link auf ein ausgeschlossenes Kapitel wird als sichtbarer Text mit einem
Informationshinweis erhalten. Fehlende Fragmente und unsichere oder außerhalb
des Pakets liegende Ziele bleiben als Text mit Inhaltsverlustdiagnose erhalten.
Codebeispiele werden nicht als Links umgeschrieben.

Bilder aus gewählten Inhalten bleiben erhalten, gemeinsame Ressourcen werden
weiterverwendet. Ein außerhalb der ausgewählten Kapitel deklarierter Buchumschlag
wird nicht automatisch vorangestellt. Ein in einem gewählten Kapitel tatsächlich
verwendetes Umschlagbild bleibt erhalten. Defekte Navigation führt zu einem
Hinweis und Rückfall auf den Spine; sie entfernt keine gewählten Kapiteltexte.

## Übersicht und Library

`--list-chapters` verlangt ein EPUB ohne Konvertierungsoptionen, erzeugt keinen
Ausgabeordner und benötigt keinen Pandoc-Lauf. JSON liefert Quellenidentität,
Gesamtzahl, ursprüngliche Indizes, relative Paketpfade, begrenzte Titel,
primäre/ergänzende Einträge, vorhandene lokale XHTML-Dateien und Navigation.
Die CLI zeigt höchstens 200 Kapitel, die Library 1 bis 500. Titel sind auf
256 UTF-8-Bytes begrenzt. Navigationsübersichten enthalten höchstens 4096
Einträge; überlange Fragmente werden mit Hinweis ausgelassen. Navigation ist
keine Garantie, dass jedes angegebene Fragment im Ziel existiert.

`DocumentConverter.inspectEPUBContents` liefert `EPUBContentSummary`.
`ConversionOptions.epubChapters` übernimmt `IndexSelection`; `nil` erhält den
bisherigen Import. Quellenzuordnungen und Diagnosen verwenden
`ConversionLocation.chapter`. Berichte behalten ursprüngliche Quellenhashes
und Kapitelindizes, auch nach Frontmatter und Textbundle-Umschreibung.

## Sicherheits- und Ressourcengrenzen

Die vollständige ZIP-Prüfung bleibt vor und nach der Änderung der privaten
Auswahlkopie aktiv, einschließlich ausgeschlossener Einträge. Quelle und
vorhandene Ausgaben bleiben geschützt. Es werden keine entfernten Ressourcen,
externen DTDs oder XML-Entities geladen. Die Auswahl benötigt wohlgeformtes
XHTML ohne externe DTDs oder Entity-Deklarationen; andere Spine-Medientypen
werden kontrolliert abgewiesen. Der bisherige Import ohne Auswahl bleibt davon
unberührt.

Es gelten zusätzlich höchstens 1000 Spine-Einträge, 128 MiB gewähltes Kapitel-XML,
128 MiB Markdown, 8192 generierte Kapitel-/Fragmentanker und 100000 interne
Links. Gewählte Paketpfade sind auf 1024 UTF-8-Bytes begrenzt und müssen als
lokale Dateipfade darstellbar sein. Die vorhandenen Paket-/XML-Budgets gelten
weiterhin. Der Fortschritt zählt gewählte Kapitel; Abbruch veröffentlicht kein
Teilergebnis. App-Auswahl und Kurzbefehle werden separat integriert.

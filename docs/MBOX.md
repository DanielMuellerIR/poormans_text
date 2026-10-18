# Reguläre MBOX-Dateien

Der Kern liest reguläre MBOX-Dateien als eine geordnete Sammlung. `index.md`
beziehungsweise `text.md` ist die Übersicht; jede Nachricht besitzt einen
nummerierten Unterordner mit Markdown, Bildern und Anhängen. Gleiche Betreffzeilen,
Message-IDs und Anhangsnamen bleiben getrennt. Der [Sammlungsvertrag](COLLECTIONS.md)
beschreibt Ergebnisfelder, Textbundle, Bericht und die Grenze für stdout.

```sh
poormans-text --json --report archive.mbox
poormans-text --textbundle archive.mbox
```

Alle von der bestehenden Mail-Engine lesbaren Kopfzeilen und MIME-Inhalte werden
übernommen. Die Archiv-Umschlagzeile steht zusätzlich als `mbox-envelope` in der
Kopfzeilentabelle. Metadaten stammen aus den Nachrichtenheadern; die Quellposition
`message` bezeichnet die laufende Nachrichtennummer ab 1, auch bei fehlenden oder
doppelten Message-IDs. Der Quellhash bezieht sich auf die vollständigen, unveränderten
Archivbytes. Anhänge werden gespeichert, nicht als weitere Dokumente konvertiert.
Entfernte Bilder werden weiterhin nicht geladen.

## Belegte Varianten und eindeutige Grenzen

Grundlage sind [RFC 4155, Anhang A](https://www.rfc-editor.org/rfc/rfc4155.html#appendix-A)
und der reale mboxo-Erzeuger [Python mailbox](https://docs.python.org/3/library/mailbox.html#mbox).
Unterstützt werden LF und CRLF. Eine Umschlagzeile besteht aus `From `, einem
druckbaren Absender ohne Leerraum und einem gültigen Datum im traditionellen
ctime-Aufbau. Ein optionaler Zeitzonenwert vor dem Jahr und `remote from HOST`
werden erhalten. Zwischen Nachrichten muss eine leere Archiv-Trennzeile stehen.
Nur diese eine Trennzeile wird entfernt; zusätzliche Leerzeilen im Körper bleiben
erhalten. Ein letzter Körper ohne abschließenden Zeilenumbruch wird gelesen.

Gewöhnliche Körperzeilen wie `From ordinary prose` bleiben Text. Vollständige
Umschlagzeilen an einer unzulässigen Stelle oder ohne folgende Mailheader sind
Fehler. Auch eine unbekannte `From `-Zeile nach einer Leerzeile mit anschließendem
erkennbarem Mailheaderblock wird als mehrdeutig abgewiesen. Ein Körper, der eine vollständige Umschlagzeile, Leerzeilengrenze und
gültige Mailheader nachbildet, ist ohne externe Varianteninformation grundsätzlich
nicht von einer weiteren Nachricht unterscheidbar. Solche Inhalte müssen beim
Export quotiert oder transferkodiert sein. Der Leser repariert keine beschädigten
oder unbekannten Umschlagformate.

mboxo und mboxrd können vorhandenes `>From ` unterschiedlich deuten. Ohne eine
verlässliche Variantenangabe nimmt der Leser deshalb kein `>` weg, sondern erhält
die gespeicherte Quotierung und meldet `mbox.fromQuotingRetained` für die Nachricht.
Das folgt dem lesenden Verhalten von Python mailbox für mboxo; eine automatische
Wiederherstellung des ursprünglichen unquotierten Körpers wird nicht versprochen.
`Content-Length`-Varianten (mboxcl/mboxcl2), reine CR-Zeilenenden, vorangestellte
Fremddaten und Apple-Mail-Verzeichnispakete werden ausdrücklich abgewiesen.
Ein `.mbox`-Verzeichnis bleibt dabei eine Einheit; die Ordnersuche importiert
seine enthaltenen Dateien nicht versehentlich als unabhängige Dokumente.

Eine leere reguläre `.mbox`-Datei ergibt eine vollständige leere Sammlung.
Eine erkannte Umschlagzeile ohne vollständige Header ist ein Fehler.

## Ressourcen und atomare Ausgabe

Das Archiv wird in 64-KiB-Blöcken gelesen; im Speicher liegt jeweils eine
Nachricht und ihre begrenzte MIME-Verarbeitung, nicht das gesamte Archiv.
Die Grenzen betragen 512 MiB Archiv, 64 MiB pro Nachricht, 1 MiB pro physischer
Zeile und 256 KiB Header. Die vorhandenen MIME-Grenzen für Teile, Tiefe und
dekodierte Daten sowie die gemeinsamen Sammlungsgrenzen gelten zusätzlich;
höchstens 10.000 Nachrichten werden verarbeitet. Fortschritt wird pro Nachricht
gemeldet, die Gesamtzahl erst am Ende des einmaligen Lesedurchlaufs.

Ein Fehler, Abbruch oder überschrittenes Budget in irgendeiner Nachricht verwirft
die gesamte temporäre Ausgabe. Vorhandene Ziele werden nie überschrieben.
Apple-Mail-Exportpakete und eigene Bedienelemente für einzelne Sammlungsdokumente
sind noch offen; die bisherigen App-Aktionen beziehen sich auf die Übersicht.

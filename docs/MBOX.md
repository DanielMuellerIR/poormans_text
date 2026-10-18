# MBOX-Dateien und Apple-Mail-Exporte

Der Kern liest reguläre MBOX-Dateien und exportierte Apple-Mail-`.mbox`-Pakete als eine geordnete Sammlung. `index.md`
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
Archivbytes. Bei einem Apple-Mail-Paket benennt `sourceIdentity.memberPath` beziehungsweise
`source.memberPath` im Bericht ausdrücklich `mbox`: Nur dieser Postfachdatenstrom
wird gehasht, nicht das gesamte Verzeichnis. Anhänge werden gespeichert, nicht als weitere Dokumente konvertiert.
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
Fremddaten werden ausdrücklich abgewiesen.
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

## Apple-Mail-Pakete und Bedienung

Apple Mail erzeugt über „Postfach → Postfach exportieren“ `.mbox`-Pakete
([Apple-Handbuch](https://support.apple.com/guide/mail/mlhlp1030/mac)). Unterstützt
wird das direkte reguläre Mitglied `mbox`. Weitere Dateien wie `table_of_contents`,
Unterordner und enthaltene EML/EMLX werden nicht gelesen oder rekursiv importiert.
Fehlende, verschachtelte, symbolisch oder hart verlinkte Postfachdaten sowie
Sonderdateien werden abgewiesen. Eine laufende Mail-Datenbank, IMAP-/Exchange-Cache,
PST und eine Mailkontenanmeldung gehören nicht zu diesem Importweg.

App, CLI, Finder-Dienst und beide Kurzbefehle-Aktionen übernehmen das Paket als
Einheit. Kurzbefehle benötigen einen lokalen Datei-/Paketpfad; ein als Byteblock
übergebenes Dokument kann kein Verzeichnispaket darstellen. Der Formatkatalog
behält `container: "file"` bei und ergänzt `containers: ["file", "package"]`.

Die App zeigt die Anzahl und eine durchsuchbare nummerierte Nachrichtenliste.
Gleiche Betreffzeilen bleiben über die Nummer unterscheidbar. „Übersicht“ wählt
den Archiveinstieg; Öffnen, Fastra, Kopieren und Vorschau verwenden die aktuelle
Wahl. Relative Bild-/Anhangslinks einer einzelnen Nachricht beziehen sich auf
deren Unterordner. Kopieren übernimmt nur Markdown; für gültige relative Links
wird der gespeicherte Ergebnisordner benötigt. „Bericht öffnen“ öffnet den
vollständigen Bericht, wenn er vor der Konvertierung aktiviert wurde.
Die gerenderte Vorschau lädt nur registrierte lokale Rasterbilder und lässt
Links inaktiv. Die Übersicht auf der Platte verlinkt alle Nachrichtendokumente.
Anhänge bleiben Originaldateien und werden nicht automatisch konvertiert.

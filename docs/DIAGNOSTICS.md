# Diagnosen und Fundstellen

`ConversionWarning` bleibt der öffentliche Typ für Konvertierungsdiagnosen.
Sein stabiler `code` bezeichnet den Sachverhalt; `message` erklärt ihn.
`kind` beschreibt seine Bedeutung und ist keine Fehler- oder Vertrauensstufe:

| Wert | Bedeutung | Beispiele |
| --- | --- | --- |
| `information` | Eine Verarbeitung oder ein Zustand wird mitgeteilt. | Lokale OCR angewendet, Bilder als entfernte Links erhalten, kein Frontmatter verfügbar. |
| `approximation` | Eine Annäherung, ein möglicher Verlust oder eine Unsicherheit braucht Prüfung. | PDF-Lesereihenfolge, angenommene Textkodierung, unbekanntes Zahlenformat. |
| `contentLoss` | Bekannte Inhalte oder Funktionen fehlen im Ergebnis. | Ausgelassene Kommentare, fehlendes Formelergebnis, verworfene Linkziele, nicht übernommene Anhänge. |

Eine leere OCR-Ausgabe beweist keine ausgelassenen Quelltexte. Bei Bildern ist
sie eine Information; bei PDFs bleibt sie ein zu prüfender Zustand. Ein OCR-
Fehler mit erhaltenem Original oder Rückfalltext ist eine Unsicherheit.
Unbekannte Codes erhalten standardmäßig `approximation`; Library-Aufrufer
können eine ausdrücklich bekannte Bedeutung beim Erzeugen angeben.

## Fundstellen

`location` ist optional. Fehlende Felder bedeuten unbekannt. Nummern sind
einsbasiert und beziehen sich auf die Quelle:

- `page`: PDF-Seite; bei Präsentationen auch der bisherige kompatible Seitenbezug.
- `slide`: Folie in der Quellreihenfolge.
- `frame`: Frame des Quellbildes, auch bei TIFF/GIF.
- `sheet` und `cell`: Blattname und Zelladresse beziehungsweise Notebook-Zelle.
- `paragraph`: tatsächliches XML-Absatzelement in Quellreihenfolge innerhalb der
  aktuellen Folie bzw. des Notizteils; bei ODP werden `text:p` und `text:h` gezählt.
  Es ist kein Absatzindex des erzeugten Markdown und keine Zeichennummer.
- `message`: tatsächlich vorhandene Message-ID einer E-Mail; ohne ID bleibt das
  Feld leer.
- `note`: Paketpfad eines PowerPoint-Notizteils bzw. einsbasierte Kennung des
  ODP-Notizcontainers innerhalb seiner Folie; bei ENEX die Notiznummer ab 1.
- `chapter`: ursprünglicher EPUB-Spine-Index ab 1.

Globale DOCX-Kommentarwarnungen erhalten keine behauptete Absatznummer.
Ein Objekt, das mehrere Absätze umfasst, wird nur so genau verortet, wie es
der Leser belegen kann. Wiederholte ODS-Zeilen beziehen strukturelle Meldungen
auf das erste deklarierte Element; daraus folgt keine Aufzählung aller Kopien.

## Gruppen und Grenzen

`ConversionResult.diagnosticGroups` fasst gleiche Codes und Bedeutungen in
Reihenfolge ihres ersten Auftretens zusammen. `count` zählt ausgegebene
Diagnosen, nicht betroffene Seiten und keine Qualitätsprozente. Unterschiedliche
Meldungstexte und bekannte Fundstellen bleiben in ihrer ersten Reihenfolge
erhalten; gleiche Einträge werden innerhalb einer Gruppe nur einmal aufgelistet.

Paket-, Präsentations-, Notebook-, PDF- und Bildleser sammeln höchstens 256
Detaildiagnosen je Verarbeitung. Ein weiterer Eintrag mit `diagnostics.limited`
nennt die tatsächlich ausgelassene Zahl in `omittedCount`. Tabellen behalten
zusätzlich ihre bisherigen globalen Zusammenfassungen und bis zu 256 Fundstellen
fehlender Formelergebnisse. `diagnostics.locationsLimited` nennt die Zahl der
weiteren Paket- und Formelfundstellen getrennt und ihre Summe maschinenlesbar.
Genau 256 Meldungen ohne weitere Fundstelle erzeugen keinen falschen Limit-Hinweis.
Diese Grenzen beschneiden die Diagnoseaufzählung, nicht die Dokumentinhalte.

## Kompatibilität und CLI

Alte Diagnose-JSONs mit `code`, `message` und optional `location` bleiben lesbar.
Die Bedeutung wird anhand des bekannten Codes ergänzt. Ein unbekannter
zukünftiger `kind`-Wert verwendet dieselbe Rückfallregel. Neue JSONs schreiben
`kind` und bei Begrenzungen `omittedCount` zusätzlich; alte Felder bleiben erhalten.

Bei vorhandenen Meldungen enthalten erfolgreiche CLI-Antworten `diagnostics`
und `diagnosticGroups`, auch wenn keine Fundstelle bekannt ist. Die bisherigen
`warnings` bleiben als Textsicht vorhanden. Antworten ohne Meldungen behalten
ihre bisherige Form. Alle Klassen sind erfolgreiche Konvertierungsdiagnosen:
`ok` und Exit-Code richten sich weiterhin allein nach Erfolg oder Fehler der
Konvertierung. Information oder Inhaltsverlust allein setzt keinen Fehlercode.

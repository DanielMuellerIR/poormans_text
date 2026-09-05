# Jupyter-Notebooks importieren

IPYNB wird als JSON-Dokument der Version 4 gelesen. Der Import startet keinen
Kernel, führt keinen Code aus und fragt keine Paketverwaltung oder entfernte
Ressourcen ab. Die Zellreihenfolge bleibt erhalten.

Markdown-Zellen werden als Markdown übernommen. Code-Zellen bekommen einen
sprachmarkierten Codeblock; die Sprache stammt aus `language_info.name` oder
`kernelspec.language`, sonst wird `text` verwendet. Nur sichere Sprachkürzel
werden in die Fence-Zeile geschrieben. Der Begrenzungsmarker enthält mehr
Backticks als jeder Run im Inhalt, sodass auch wörtliche ```-Zeilen im Code oder
in Ausgaben den Codeblock nicht schließen können.

Stream- und `text/plain`-Ausgaben sowie Fehlertext bleiben als Textblöcke erhalten.
PNG/JPEG und weitere lokal von ImageIO lesbare Base64-Bilder aus MIME-Ausgaben
oder Markdown-Attachments werden unter `images/` gespeichert und anhand ihres
SHA-256 dedupliziert. Unterschiedliche MIME-Repräsentationen desselben Outputs
werden nicht als mehrere Bilder ausgegeben. Raw- und unbekannte Zelltypen bleiben
mit Diagnose als Text erhalten. HTML-, Plotly-, Widget- und andere nicht
abbildbare Ausgaberepräsentationen erhalten eine Diagnose; ein vorhandener
`text/plain`-Fallback bleibt sichtbar.

## Markdown-Verweise

Attachment-Verweise werden mit dem bestehenden Markdown-Link-Rewriter umgesetzt.
Er lässt Inline-Code, Fences und HTML-Blöcke unangetastet. Kandidaten aus Link-
oder Referenzsyntax werden nur dann behandelt, wenn ein Proberewrite einen echten
Markdown-Verweis bestätigt. Fehlende Attachments, nicht mitgelieferte lokale
Dateien und unsichere URI-Schemata werden diagnostiziert und auf einen lokalen
Platzhalteranker gesetzt. Der Import liest keine Dateien neben dem Notebook.
HTTP(S)- und Mail-Verweise bleiben mit Diagnose stehen und werden nie geladen.
Raw-HTML in Markdown wird erhalten, nicht ausgeführt; es kann zusätzliche
Ressourcen enthalten und wird bei einschlägigen Elementen diagnostiziert.
Die erzeugte Markdown-Datei kann später in anderen Programmen dargestellt werden;
deren Umgang mit externen Verweisen bestimmt das jeweilige Programm.

## Grenzen und Nachweis

Der Import liest eine private, aus einem geprüften regulären Dateideskriptor
kopierte Quelle bis 64 MiB. Er akzeptiert höchstens 10.000 Zellen, 10.000 Outputs
pro Zelle und 100.000 Outputs insgesamt. Ein Text-/Base64-Wert hat höchstens
24 MiB. Bilder haben höchstens 16 MiB, alle Bild-Assets zusammen höchstens
128 MiB und 1.024 Einträge. Markdown ist auf 128 MiB begrenzt; eine Markdown-Zelle
hat höchstens 4.096 verschiedene erkannte Ressourcenziele. Nach 256 Diagnosen
folgt ein Hinweis mit der Zahl der ausgelassenen Meldungen. Notebook-Metadaten
werden zur Sprachwahl genutzt; dokumentbezogenes Frontmatter wird nicht abgeleitet.

Fortschritt und Abbruch nennen die Zelle. Tests erzeugen echte Notebooks mit
Markdown-Attachment, Unicode, Backtick-Zeilen, Python-Code mit einem absichtlich
schreibenden Befehl, Stream-/Bild-/HTML-Ausgaben und Raw-Zellen. Sie prüfen, dass
die Zieldatei des Python-Befehls nie entsteht, der Code unverändert im Fence
steht, alle Textmarker erhalten bleiben und Bild- sowie Quellenbytes unverändert
sind. Notebook-Code gehört ausschließlich in die Ausgabe, nie in einen Prozess.

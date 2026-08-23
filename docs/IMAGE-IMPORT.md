# Bildimport

Der Bildadapter akzeptiert PNG, JPEG, HEIC und TIFF anhand der von ImageIO
erkannten Daten, nicht allein anhand der Endung. Eine Datei ohne passende Endung
wird deshalb trotzdem erkannt; eine Textdatei namens `.png` wird abgewiesen.
Nur reguläre Dateien bis 1 GiB und höchstens 1.000 TIFF-Frames sind zulässig.

## Ausgabe

Jeder erfolgreiche Import schreibt die Quelle unverändert als ein Asset in den
neuen Ergebnisordner und verlinkt sie relativ:

```text
Scan-markdown/
├── Scan.md
└── images/
    └── image01.png
```

Die Asset-Bytes stammen aus der verifizierten Staging-Kopie und sind mit der
Quelle identisch. Der generierte Name verhindert, dass ein Dateiname aus der
Quelle einen Zielpfad oder einen Markdown-Link bestimmen kann.

## OCR

Standardmäßig ergänzt der Adapter unter dem Bild einen Abschnitt `OCR text`.
Er übergibt die lokalen Bildpixel an Vision mit genauer Erkennung,
Sprachkorrektur, automatischer Spracherkennung und einer Sortierung von oben nach
unten und innerhalb einer Zeile von links nach rechts. EXIF-Orientierung wird an
Vision weitergegeben. Mehrseitige TIFF-Dateien behalten ein Asset und erhalten
für jeden Frame einen eigenen OCR-Abschnitt.

`poormans-text --image-ocr off Foto.jpg` übernimmt dagegen nur das Bild. Die
Option eignet sich für Handschrift, Diagramme und andere Inhalte, für die kein
zusätzlicher durchsuchbarer Text erwünscht ist. Die macOS-App verwendet den
Standard mit OCR und bietet vor der Umwandlung dieselbe Auswahl.

Pro Frame sind höchstens 16 Millionen Pixel und über alle OCR-Frames zusammen
64 Millionen Pixel zulässig. Die Prüfung erfolgt vor dem Dekodieren der Pixel.
Eine unlesbare Frame-Pixelquelle erzeugt eine Warnung, lässt das Originalasset
aber bestehen. Leere Erkennung und niedrige Sicherheit werden sichtbar markiert;
aus dem OCR-Text kann keine neue Markdown-Struktur entstehen.

## Diagnosen

- `image.ocrApplied`: lokaler OCR-Text wurde hinzugefügt.
- `image.ocrFailed`: Vision konnte mindestens einen Frame nicht lesen.
- `image.textUnavailable`: mindestens ein Frame lieferte keinen Text.

Diagnosen beschreiben den Zusatztext. Das Bildasset bleibt immer maßgeblich und
wird bei deaktiviertem OCR ohne Diagnosen ausgegeben.

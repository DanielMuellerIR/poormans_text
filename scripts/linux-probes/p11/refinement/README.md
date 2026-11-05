# Begrenzte lokale Wortverfeinerung

`verify_product.py` konvertiert sechs vorher festgelegte Kontrollbilder mit der
wirklichen Produkt-CLI. `fixtures/reference.json` bindet Quellen, Schriftdateien,
Winkel, Unschärfe und unabhängige Solltexte. Die Bilder enthalten Namen, ähnlich
aussehende Buchstaben/Ziffern, Unicode, Fließtext und Tabellen. Sie wurden vor
der Auswertung des konservativen Verfahrens festgelegt.

`baseline.json` enthält den unveränderten Tesseract-/Docling-Komponentenstand,
projiziert durch den echten Swift-Renderer. Beide Seiten verwenden dieselbe
Sprachreihenfolge `eng,deu`. Der Prüfer zählt richtige Wörter und prüft zusätzlich,
ob zuvor richtige Wortpositionen oder Tabellenzellen verloren gehen. Er prüft
auch Quelle, Originalidentität und sämtliche gemeldeten Ausgabefingerprints.
`regressionStatus` und `qualityStatus` sind getrennte Ergebnisse: Ein bestandener
Vergleich behauptet keine vollständige Zeichenerkennung. Fehlende Runtime ist
ein Fehler dieses ausdrücklich angeforderten Modelltests, kein stiller Skip.

```sh
python3 scripts/linux-probes/p11/refinement/verify_product.py \
  --cli /absoluter/pfad/poormans-text --results /neuer/pruefordner
```

Der zweite Leser verwendet ausschließlich lokale RapidOCR-3.9.1-Modelle und
ONNXRuntime1.23.2. `downloads.json` bindet alle zusätzlichen Quellarchive an
Version, Bytezahl, SHA256 und offizielle PyPI-URLs. Der ursprüngliche Docling-
Stand bleibt separat erhalten. Der neue Runtimepin und die Produktnachweise
stehen im [Abnahmebericht](../../../../docs/linux-port/P16-04119/README.md).
Der normale Installer lädt nichts herunter; dieses Verzeichnis führt ebenfalls
keinen automatischen Download oder Hostinstallation aus.

Die tatsächlich qualifizierte Runtime enthält zwölf zusätzliche Pakete. Das
bereits geprüfte `opencv-python-headless` stellt `cv2` bereit; es wird kein
zusätzliches GUI-OpenCV installiert. Das ist eine ausdrücklich geprüfte
Abweichung vom generischen RapidOCR-Metadatum `opencv_python`. Der Runtimebestand
enthält die offiziellen Paketmetadaten, Lizenzen und den zusätzlichen Apache-
Lizenztext. Die Prüfung vollständiger gebündelter Komponenten und erforderlicher
Quellen/Angebote bleibt vor öffentlicher Modelldistribution offen.

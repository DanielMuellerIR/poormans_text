# Mint 0.41.13: nativer PDF-Produktlauf mit isolierter Typelib

**12/12 repräsentative Produktfälle bestanden**, ohne SDK, Hostinstallation, Overlay oder GUI. Dies ist keine Aussage über den PDF-Backendumfang einer unveränderten Standard-Mintinstallation: Dort fehlte die Typelib. Vorhanden waren die echte native libpoppler-glib.so.8.26.0 (Paket24.02.0-1ubuntu9.11), gi3.48.2 und cairo1.18.0.

Als einzige zusätzliche Netzabhängigkeit wurden exakt26266Bytes gir1.2-poppler-0.18_24.02.0-1ubuntu9.11_amd64.deb per apt-get download in der eigenen /tmp-Wurzel bezogen. SHA2568231c377b2c736c2c80699b935350441e6b18839610037e816cf8cf9281dc229 sowie Version/amd64 geprüft; ausschließlich dpkg-deb-x privat, kein apt-update, keine Autodeps, kein Signatur-/Abhängigkeitsoverride. Die passende Poppler-0.18.typelib ergänzte eine eigene6,9MB-Kopie des vorhandenen Standard-Girepository. Diese Kopie war im vollständig privaten User/PID/Net/Mountnamespace readonly über den vorhandenen Standardordner gebunden. Hostroot readonly, Home/root/run/tmp/dev/proc privat, einziger schreibbarer Hostbereich die eigene /tmp-Wurzel. Kein GI_TYPELIB_PATH oder anderer Produkt-Backendsonderpfad.

Der erste kleine GI-Import war erfolgreich: Poppler24.02.0, cairo1.18.0, gi3.48.2, UID1000, Typelibmount tatsächlich ro. Die Namespace-Inodes unterscheiden sich nachweislich vom Host (import-proof.json).

Danach lief das ausschließlich privat extrahierte endgültige PMT-Paket0.41.13. CLI-SHA25626470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460, Guardcf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520. ProduktpaketSHA640be59eeacddca4fdb0626a84de2ccba8012cf49eb0e98627af404d28cf80ff. Kein Pandoc oder Tesseract bereitgestellt.

## Tatsächliche Fälle

Sieben erfolgreiche Konvertierungen ausdrücklich mit --pdf-ocr off: Datumsmetadaten1969/2020 und Frontmatter; structured-off ohne falsches OCR-Applied; digitale Wortabstände/Spalten; exklusive Seite2; wiederholte Header/Footer; Dehyphenation; Legacy-Lesereihenfolge. Der digitale Fall erhält ALPHA/BETA/GAMMA/DELTA, echten lokalen2×2-Bildinhalt, externe Linkadresse und Annotationstext/Autor. Wortzählung und Bildpixel werden unabhängig gegen den synthetischen PDF-Generator geprüft. Die Linkadresse wurde im netzisolierten Lauf nicht geladen.

Drei negative Eingaben (defekt, verschlüsselt, Seite außerhalb der Auswahl) liefern65 ohne öffentliche Ausgabe. Die gesonderte ausdrückliche OCR-Anforderung trifft tatsächlich fehlendes Tesseract und liefert69 ohne Veröffentlichung. **Keine native Standard-OCR-Qualität behauptet.**

Die zwölfte Prüfung ist --preview-page2: korrektes kanonisches Base64, Bytezahl/SHA256, SourceIdentity, genau768×1024Pixel und unabhängige Pillowdekodierung. Visuelle Prüfung zeigt DELTA page two. Ein zusätzlicher Pixelvergleich bestätigt ausschließlich Graustufen/Schwarztext (1604 Nichtweißpixel), während Seite1 das farbige Bild besitzt. Keine erfundenen Quellrechtecke.

Alle Quellen blieben hashgleich. Für alle positiven Ausgabe-Manifeste werden Dateigröße/SHA256 und UTF8-Grenzen der Source-Mappings geprüft. Output-Bildpixel und PNGhashes sind unabhängig bestätigt. Die vorhandenen P09-Generatoren lieferten die digitalen Fixtures; das vorhandene verschlüsselte synthetische Fixture wurde wiederverwendet. Kein neuer PDF-/Rasterkonverter.

## Hostschutz, Cleanup und Reproduktion

Vollständiger vorhandener Girepository-Dateibestand inklusive Hash/Modus/Links, native DSO, /usr/bin/true und Host-Paketdatenbank sind vor/nach gleich. Keine eigenen verbleibenden Prozesse, kein Hostdisplay. Gesamte eigene Remote-Wurzel inklusive Produktpaketextrakt/Typelib/Kopien ist entfernt (cleanup.json). Arbeitsumfang232667808Bytes (<400MiB); zusätzliche Netzdownloads26266Bytes (<1MiB).

Das kleine Archiv enthält Laufskripte, synthetische PDFs, JSON-/Log-/PNG-Belege. Keine Produkt-/System-DSO- oder Runtimekopie. setup_remote.executed.py ist die historische tatsächlich ausgeführte Setupquelle; setup_remote.py ist inhaltsgleich mit Rootpfadargument statt festem Prüfpfad. reproduce_remote.sh erwartet eine neue eigene /tmp/pmt-mint-pdf13.*-Wurzel, passende übertragene Produktpaketstruktur und Fixtures. Es lädt nur die gepinnte26KB-Typelib, validiert sie erneut und führt dieselben isolierten Schritte aus. Cleanup immer erst nach Zurückholen der kleinen Belege; die historische Cleanupquelle zeigt die tatsächlich erfolgte eigene Entfernung. Keine Installations-/Upgrade-/Remove-Abnahme.

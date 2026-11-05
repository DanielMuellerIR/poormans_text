# P10: Legacy-DOC-Kandidat und offene Sicherheitsabnahme

Stand: 2026-11-05. Der LibreOffice-basierte DOC-Kandidat funktioniert in
isolierten Prüfungen, bleibt im Produktkatalog jedoch deaktiviert. Die
Makroereignisprobe besitzt weiterhin keine funktionierende positive Kontrolle;
auch ein alternativ untersuchter enger makrofreier Teilumfang ist nicht positiv
qualifiziert. Funktionale Erfolge ersetzen diese Sicherheitsabnahme nicht.

## Implementierter Kandidat

Die Entwicklungsdateien liegen unter `scripts/linux-probes/p10-doc/` und werden
weder vom Produkt gebaut noch als Backend registriert. Sie enthalten den
Swift-Adapter, einen kleinen lokalen Python-/LibreOffice-Helfer, gezielte Tests
und einen CLI-Prüflauf für einen ausdrücklich isoliert eingebundenen Kandidaten.

Der Adapter erkennt OLE/WordDocument mit dem bestehenden Compound-Reader,
erstellt einen verifizierten Snapshot und exportiert daraus HTML und TXT.
Der Snapshot liegt außerhalb des schreibbaren LibreOffice-Bereichs und wird
read-only gebunden. Beide Exporte verwenden dieselben Bytes. Der vorhandene
HTML-Konverter übernimmt Text, Listen, Tabellen und lokale Assets; die
unabhängige Textreferenz begrenzt unbemerkten Verlust. Der PID-/Netz-Namespace,
Lebensdauerkanal und Zeitlimit stammen aus der Produktprozessaufsicht.
LibreOffice erhält ein eigenes Profil mit hoher Makrosicherheitsstufe,
`DisableMacrosExecution=true`, deaktiviertem Linkupdate und dem kopflosen
`svp`-Plugin. Das belegt die verwendete Konfiguration, keine allgemeine
Makrosicherheitsgarantie.

## Ausgeführte Prüfungen

Mit LibreOffice 26.8.1.1 bestehen drei Unit-Tests sowie sechs echte CLI-Fälle
mit 63 Prüfungen: die vorhandenen `libreoffice.doc`- und `textutil.doc`-Fixtures,
Textbundle, Timeout, SIGTERM und ungültige Quelle. Textmarker, Tabellen-/Listen-
inhalte, ein PNG-Asset, Quell-/Output-Hashes und Cleanup wurden geprüft.
Die Fehlerfälle liefern Exit 124, 130 beziehungsweise 65. Kleine Ergebnisse
stehen in [candidate.json](P10-DOC-EVIDENCE/candidate.json).

## Warum DOC noch gesperrt bleibt

Eine synthetisch erzeugte ODT-Datei enthält eine gespeicherte OnLoad-Registrierung.
Die manuelle Ausführung derselben Basic-Routine schreibt den vorgesehenen
Sentinel. Beim Export als OLE/DOC gehen Eventdescriptor und Modulcode verloren;
der spätere manuelle Aufruf findet das Skript nicht. Hiddenload löst auch beim
ODT keine positive automatische Kontrolle aus. Ein erfolgreich ausbleibender
Sentinel wäre unter diesen Voraussetzungen kein Nachweis der Sperre.

Die öffentliche benigne Apache-POI-Datei `SimpleMacro.doc` wurde ausschließlich
statisch untersucht. Ihr Quelltext enthält `TestMacro`, kein AutoOpen-Ereignis.
Der OLE-Reader findet den `Macros`-Rootstorage und kann ihn vor einem Konverter
abweisen. Ein experimenteller strenger FIB-/Storage-Filter hatte jedoch keinen
qualifizierten positiven DOC-Fall: Die beiden Bestandsfixtures weichen bei
FIB-Layoutwerten ab, ein weiterer POI-Fall enthält einen Unterstorage. Diese
Filteridee ist deshalb kein aktivierter sicherer Teilumfang.

Primärbelege sind die [MS-DOC-Makrostruktur](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/a93e185e-73b6-4db8-865e-7746766d5c6f),
die [benignen POI-Testdaten](https://github.com/apache/poi/tree/trunk/test-data/document)
und der [LibreOffice-26.8-Konvertierungsdispatcher](https://github.com/LibreOffice/core/blob/libreoffice-26-8/desktop/source/app/dispatchwatcher.cxx).
Der Dispatcher setzt im Konvertierungszweig ReadOnly/OpenNewView/Hidden/Silent;
eine explizite Zuweisung von `MacroExecutionMode=NEVER_EXECUTE` wurde dort nicht
gefunden. Die [SDK-Konstante](https://api.libreoffice.org/docs/idl/ref/namespacecom_1_1sun_1_1star_1_1document_1_1MacroExecMode.html)
allein belegt keinen Loader-Default und ersetzt die Ereignisprobe nicht.

## Nächster Freigabeschritt

Erforderlich ist eine echte DOC-Ereignisprobe mit funktionierender positiver
Kontrolle oder ein vollständig begründeter, positiv getesteter sicherer
Teilumfang. Bis dahin bleibt DOC ausdrücklich unavailable. Weder weitere
Paketinstallation noch ein vorhandenes LibreOffice schalten diesen Pfad frei.

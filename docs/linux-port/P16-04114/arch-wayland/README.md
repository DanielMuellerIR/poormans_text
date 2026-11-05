# Finale 0.41.14: reguläres Paketupgrade und Produktions-Wayland-GUI

2026-11-05: begrenzte Abnahme bestanden. Regulär 0.41.13 installieren,
auf 0.41.14 upgraden und entfernen, eigene neue netzlose Containerinstanz aus
vorhandenem qualifiziertem Arch/Westonimage. Keine Downloads, Paket-/Runtimekopien,
Hostinstallation oder Abhängigkeits-/SignaturOverrides. Default-LocalFileSigLevel
Optional/TrustedOnly unverändert; Previewpakete gegen ihre .sha256 geprüft,
keine Behauptung einer PMT-Paketsignatur. CLI/GUI/Guard stimmen exakt mit dem
freigegebenen finalen Produkt überein (lifecycle.json/artifacts.json).

CLI 8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb
GUI 85e70bf0654f4b308a5db2d483eaf258dd376f83773703febe23fa91d05ddcf2
Paket db51fee5caf090593d29c26512d607474aaf7633ac93642ae32ae0bb1921a0bf

UID1000, kein Swift-SDK, privates HOME/TMP/XDG. Echte Unicode-CSV vor/nach Upgrade
mit unveränderter Quelle und geprüften Ausgabehashes. Ein vor Installation
angelegter privater Profilmarker sowie bereits erzeugte Benutzerdateien wurden
vor Upgrade gehasht: alle 4 Dateien danach unverändert. Nach GUI-Lauf wurde der
vollständige Benutzer-/Profilbestand erneut gehasht und über die Paketentfernung
unverändert bestätigt. Der letzte abgeschlossene Lauf bindet diese stärkere
Profilprüfung zusätzlich; ein vorheriger vollständiger CSV-Lauf war schon grün.

Produktion-GUI unter eigenem nativem Weston/Pixman per tatsächlichem AT-SPI-
Convert bis Completed; WAYLANDCSVMARKER und Grüße im unabhängigen Markdown
bestätigt, Quelle unverändert. Kein DISPLAY, GDK_BACKEND=wayland, echter
Waylandprotokollnachweis, kein Swift-LD im GUI. wayland.png ist eine native
Westonaufnahme und wurde visuell geprüft. Kein Testfeature oder Flagwrapper.

## PNG-/Zoomgrenze dieses Laufs

Nicht bestanden/belegt: PNG-Konvertierung mit per GUI ausgeschalteter OCR,
Compare Source, 100%/Fit oder Scroll unter Wayland. Die beauftragte synthetische
1024×768-Quelle wurde nur im begrenzten Bedienversuch gewählt. Der Notebooktab
hat keine AT-SPI-Action, ließ sich aber über die vorhandene Selection wählen.
Die ComboBox hat ebenfalls keine Action; der vorhandene untergeordnete Toggle-
Button war ansprechbar, lieferte im privaten Headlessaufbau jedoch keine sichtbare
Off-Option im Accessibilitybaum. Danach wurde der Weg beendet und wie vereinbart
auf den bewährten CSV-/Haupt-GUI-Harness begrenzt. Keine künstliche OCR-Flagsetzung,
keine neue Waylandinput-Infrastruktur, keine Sourceänderung, kein Zoom-Scheinerfolg.

zoom-limit.json hält diese konkreten aufeinander folgenden Erkenntnisse fest;
verify_wayland_zoom.py ist ausschließlich der nicht bestandene Versuchsprüfer.
Vorherige separate Zoom-Kandidatenprüfungen werden dadurch weder neu bestanden
noch widerlegt. Aus dieser Headless-Bediengrenze wird ohne echte Desktopsitzung
kein Produktfehler abgeleitet. Desktop-/Portal-/Clipboard-/Drop-/Skalierungs-
Gesamtabnahme bleibt offen.

## Cleanup und Wiederholung

cleanup.json: Paketdateien entfernt, keine lebenden UID1000-Prozesse, nur Loopback.
GUI und Weston beendet/abgewartet. Sämtliche eigenen Versuchs-/Finalcontainer
entfernt; Harness-Temporärverzeichnisse samt Profilen/Quellen/Ausgaben entfernt.
Bestehende Rootpakete, Runtime und Quellen wurden nur lesend verwendet.

Vorhandenes qualifiziertes Image mit --init --network none und erlaubten inneren
Namespaces verwenden, nur eigenen Proofordner unter /proof und ausdrücklich
gewählte .13/.14-Paketordner read-only mounten. verify_lifecycle.py mit --package,
--previous-package, --evidence und formalem --heic-fixtures-Argument aufrufen
(letzteres im begrenzten Delta nicht benutzt). Er startet ausschließlich die
bestandene verify_wayland.py und die CSV-CLI-Proben als UID1000. Kein Hostdisplay-
oder Sessionbusmount. Die bekannten CLI-/GUIhashes sind absichtlich gepinnt.
Keine weiteren Backend-, Fastra- oder Zoomserien in diesem Teilnachweis.

## Begrenzter Default-On-Nachversuch

Auf nachträgliche ausdrückliche Freigabe wurde das Dropdown vollständig
übersprungen und PNG mit unverändertem Standard-OCR-On konvertiert. Die
Assertions für vorhandenes OCR-Kapitel, bytegleiches Original-PNG-Asset und
unveränderte Quelle bestanden vor dem nächsten Bedienpunkt. Keine Aussage zur
OCR-Qualität. Der Compare-Aufruf scheiterte am mehrfach benannten AT-SPI-
Layout-/Controlpfad; ein vereinfachter Auswahlversuch blieb dort ebenfalls
hängen. Danach kein weiterer Harnessausbau. Compare,100%/Fit und sichtbare
Quellraster sind weiterhin NICHT belegt. zoom-limit.json trennt das ausdrücklich
vom bestandenen CSV-/Haupt-GUI-Lauf.

Die Dateien zoom-default-client.log und zoom-default-weston.log stammen vom
letzten nicht bestandenen PNG-Bedienversuch, nicht von der CSV-Aufnahme. Die
vorherigen generischen Lognamen waren im gemeinsamen Proofordner überschrieben;
der bestandene CSV-Lauf bleibt durch lifecycle.json/wayland.json, gehashte
Dateiergebnisse und visuell geprüftes wayland.png belegt. zoom-cleanup.json
belegt auch den Nachversuch: keine lebenden UID1000-Prozesse, nur Loopback,
Paket regulär entfernt und eigener Container danach gelöscht.

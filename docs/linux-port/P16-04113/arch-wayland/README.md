# P15-Deltaabnahme 0.41.13

2026-11-05: bestanden. Neue eigene netzlose Containerinstanz des vorhandenen
qualifizierten Arch-/Westonimages, kein neuer Distroabruf/Download. Reguläre
pacman-U-Installation 0.41.12, tatsächliches Upgrade 0.41.13, pacman-R-Entfernung;
keine Abhängigkeits-/Signaturoverrides. Default-LocalFileSigLevel bleibt
Optional/TrustedOnly; die lokalen Previewpakete wurden separat per SHA256
geprüft, keine Behauptung einer PMT-Paketsignatur.

`lifecycle.json`: SDKfrei, UID1000, eigenes HOME/TMP/XDG, Unicode-CSV vor/nach
Upgrade, Ausgabe-/Quellhashes und Benutzerdateien über Paketentfernung erhalten.
CLI 26470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460
GUI 851d0a76e4214bbd5f599c995a1b78ff40792524a7b1383e6afbda165c43cfa6
Guard cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520
Paket 37431afee9f407ab81934da9b038f36b91d693b11c8b8ac1235a8b278eb7a951

Der Root-Prüfer verify_rtfd.py wurde während der Ausführung read-only eingebunden;
`artifacts.json` bindet die tatsächlich verwendeten Bytes und die kleine
beiliegende Kopie. Echtes Pandoc 3.1.3 ebenfalls read-only. Alle 25 echten RTFD-
Fälle bestanden: 12 Erfolge / 13 erwartete 65-Fehler ohne Veröffentlichung.

Positiv: CP1252-/Unicode-/Listeninhalt, Fortsetzungszeilen, kodierter Assetname,
PNG und statisches JPEG/TIFF/GIF/BMP/WebP/HEIC, erhaltene Originalassetbytes,
Bildposition zwischen BEFORE/AFTER und passende ViewerCompatibility-Diagnose.
Unbenutzter Anhang meldet den erwarteten Verlust. Negativ: Remote/absolute/..
Verweise, fehlende/defekte Assets, Symlink/FIFO, falscher Signatur-/Endungstyp
und mehrframiges GIF/TIFF/APNG/WebP/HEIC. Der Prüfer vergleicht sämtliche regulären
Fixturequellen vor/nach per SHA256. `rtfd.json` bewahrt tatsächliche Ergebnisse,
Markdown und Assethashes. Keine Vollparität für RTFD oder Bildviewer abgeleitet.

Produktions-GUI nach Upgrade per echtem AT-SPI-Convert bedient. Privater nativer
Weston 15/Pixman, GDK_BACKEND=wayland, kein DISPLAY und kein Swift-LD-Pfad im GUI.
`wayland.png` zeigt Completed sowie WAYLANDCSVMARKER/Grüße und wurde visuell
geprüft. `wayland.json` bindet Quell-/Output-/Screenshot-SHA256, reales
Waylandprotokoll und die Ergebnisempfangsbarriere. Keine echte Desktop-, Portal-,
Clipboard-, Drop-, Skalierungs- oder Fastraabnahme daraus abgeleitet.

`cleanup.json`: Paket entfernt, keine lebenden UID1000-Prozesse, nur Loopback.
GUI/Weston beendet und abgewartet, eigener Container entfernt. Der Harness hat
seinen gesamten privaten Fixture-/Profil-/Outputbereich nach dem Hashvergleich
entfernt. Es entstanden keine Paket-/Runtimekopien oder Hostinstallationen.
Bestehende Images und ursprüngliche Fixtures/Runtime blieben unangetastet.
PDF-/Rastermatrizen wurden in diesem begrenzten Deltaauftrag nicht wiederholt.

## Wiederholung

Vorhandenes qualifiziertes Image und ausdrücklich gewählte .12/.13-Pakete samt
.sha256 read-only binden. `verify_lifecycle.py` läuft als Containerroot und startet
alle Produktkonvertierungen mit setpriv als UID1000. Mounts: eigener Proofordner
unter /proof, zwei Paketordner frei per Argument wählbar, Root-RTFD-Prüfer unter
/rtfd/verify_rtfd.py, qualifiziertes Pandoc unter /tools/pandoc, Single-/Multi-
HEIC-Fixtures unter einem eigens gewählten Fixtureordner. Mit --package,
--previous-package, --heic-fixtures und --evidence aufrufen. Der Prüfer bindet
absichtlich die eingefrorenen CLI-/GUIhashes. Keine Hostdisplay-/DBus-Sockets;
--init --network none und erlaubte verschachtelte User/PID-Namespaces wie im
vorherigen qualifizierten P15-Aufbau. Der Runner startet Weston/Sessionbus selbst.
Keine automatische Installation/Downloads durch das Produkt.

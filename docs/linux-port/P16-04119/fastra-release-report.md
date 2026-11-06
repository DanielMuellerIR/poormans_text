# Release-Abnahme: Fastra 1.185 und PMT 0.41.19

Die echte Releasepaarung besteht die drei geprüften Flüsse: RTF-Dateiimport, MBOX-Dateiimport und RTF aus der Zwischenablage in die Rich-Ansicht. Fastra und PMT wurden weder neu gebaut noch verändert. Es wurden keine Debug- oder Selbsttestflags verwendet.

Fastra läuft als optimiertes Paket 1.185.0, Build 395, mit Source-ID `49f244eb9c562e89613b182061caf87d357e7661b854696c3b0c659fbe09be34`. Der Consumer-ELF hat SHA256 `e045449cd2fd44479b6106d4167427c03bce359caba7f99a34cb5bc94d8ace1e`. PMT stammt aus dem unveränderten Handoff 0.41.19, Commit `e2f0b8866aa3acc9b9dd8bf474ffd11d031f4adb`. Seine Launcher- und ELF-Hashes stehen vollständig in RESULT.json. Der bestehende Release-Controlvertrag bestätigt zur Laufzeit Version 1.185.0.

## Tatsächlich geprüft

- **RTF-Dateiimport:** Das normale Dateiöffnen über den Release-Launcher erreicht den sichtbaren RTF-Dialog. „Import as Markdown“, „Prepare preview“ und später „Adopt“ wurden jeweils mit der Maus angeklickt. Der gesamte sichtbare Vorschautext wurde mit normalem Ctrl+A/Ctrl+C gelesen. Er enthält alle 29 Markdownbytes sowie die beiden erklärten Farb- und Highlight-Approximationen. Vor der Adoption existierte kein Zielbaum. Danach sind der geöffnete Buffer, die adoptierte Source.md und eine separat erzeugte PMT-CLI-Ausgabe bytegleich: `Plain **Bold** ==Marked== Ä` plus LF.
- **MBOX-Dateiimport:** Der normale Dateiaufruf erreicht die sichtbare MBOX-Route. Die vollständige UI-Vorschau enthält exakt beide erzeugten Markdowndateien, einschließlich Headern, Unicodebody `café🙂` und relativer Verknüpfung. Erst nach dieser Prüfung und bei noch fehlendem Zielbaum wurde „Adopt“ angeklickt. Der gesamte adoptierte Baum entspricht bytegleich der regulären PMT-CLI-Ausgabe: index.md mit 69 Bytes und assets/documents/000001/Source.md mit 373 Bytes. Der tatsächlich geöffnete Entrybuffer ist ebenfalls bytegleich.
- **RTF-Zwischenablage und Rich-Paste:** Original.txt wurde über die sichtbare Checkbox in der Rich-Ansicht geöffnet. Eine kleine erlaubte C/GDK-Clipboardfixture bot die exakten Original-RTFbytes als `text/rtf` an. Ein tatsächliches Ctrl+V öffnet den Produktdialog mit sichtbarer Warnung vor Format- und Highlightverlust. Die materialisierte Clipboard.rtf entspricht dem Originalhash und bleibt bis nach der Adoption unverändert. Nach vollständiger Vorschau und ausdrücklichem Adopt-Klick entsprechen Clipboard.md und sein geöffneter Buffer denselben 29 Producerbytes. Die reguläre Rich-Ansicht zeigt „Bold“ fett und „Marked“ gelb markiert. Anschließend blieb der ursprüngliche Buffer auch nach regulärer Rich→Source-Synchronisierung bytegleich.

Der Text des Originalbuffers wurde nach jedem der drei Flüsse per normaler Source-Copy geprüft. Die Originaldatei blieb ebenfalls unverändert. Der vorhandene rein lesende Controlvertrag belegt dieselbe Originaldokument-ID über die Flüsse. Er diente nur zum Lesen von objects und capabilities, nicht für UI-Aktionen oder Adoption. Caret und Auswahl wurden für die Copyprüfungen bewegt; deren unveränderter Zustand wird nicht behauptet.

## Erhaltung und Testumgebung

Vor und nach allen Flüssen sowie erneut nach regulärem Quit mit Exit 0 sind sämtliche 396 Paketdateien, alle 51 PMT-Handoffdateien und die drei Originaldateien hashgleich. Alle 48 Runtimefiles entsprechen zusätzlich exakt dem originalen PMT-Manifest. RESULT.json und before.json/after.json enthalten die Identitäten und Inventare.

Der Test lief offline in `fastra-pmt-native-04119:local`, mit eigener Xvfb-Anzeige, D-Bus-Sitzung, XDG-Profilen und Btrfs-Fixtures. Fastra verwendete ICU aus seinem Paket. Paket und Producer waren readonly eingebunden. Vom Repo war ausschließlich die erlaubte einzelne D-Bus-Konfiguration readonly gemountet; kein Repoverzeichnis oder Buildpfad stand als Laufzeitfallback bereit. Die Rich-Ansicht wurde tatsächlich aus diesem Aufbau geladen. Die Appumgebung enthielt als einziges FASTRA-Flag den normalen PMT-Programmpfad.

Es gab keinen Hostdesktop-, Mac- oder Netzwerkzugriff. Nur die kleine C-Clipboardfixture wurde separat als Testhilfe kompiliert. AT-SPI, GDB, JavaScript- oder Speicherinjektion wurden nicht verwendet. Die App wurde regulär beendet; der eigene Container und alle Hilfsprozesse sind entfernt.

Zwei synthetische Texteingaben im GTK-Dateidialog erzeugten durch dessen Vervollständigung falsche Suffixe. Danach wurde auf den normalen CLI-Dateiöffnungsweg gewechselt; daraus wird kein Produktfehler abgeleitet. EGL- und fehlende a11y-Bus-Warnungen sind ungekürzt im app.log erhalten. Eine anfängliche Verwechslung der Preview-Checkbox wurde vor der RTF-Paste korrigiert, ohne Sourceänderung.

## Grenzen

Geprüft wurden EN und je eine einfache RTF-/MBOX-Fixture sowie der RTF-MIME-Clipboardweg. Nicht behauptet werden eine vollständige Format-, Attachment-, Mehrnachrichten- oder DE-Matrix, Copy aus einem externen Officeprogramm oder eine Mac-Abnahme. In diesem konkreten Umfang ist die bislang nur als WIP-Debug geprüfte Paarung jetzt als tatsächliche Releasepaarung bestätigt. Es gab keine Veröffentlichung.

ACTIONS.md und die Testhilfen beschreiben die Schritte. Vollständige Vorschau-, Output- und Bufferbytes sowie echte Screenshots sind enthalten. Paket und Producer bleiben an ihren ursprünglichen Orten; hier werden keine Produktbinaries veröffentlicht oder ersetzt. Entbehrliche Fixtures spätestens am 2026-12-06 prüfen; das kleine Handoff bis zur Abnahme erhalten.

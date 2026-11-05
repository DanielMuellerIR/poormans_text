# GTK-Quellraster: Zoom-Kandidat

Geprüfter isolierter Kandidat auf Produktstand0.41.13, ohne Repo-/Git-Write und ohne Versionsbump. Patch `source-raster-zoom.patch` SHA256 `d0fb6964fe3d713cf47cc678c66f959c1e387d2b8595d53f48ff2dc284ada484`. Vollständiger eigener Rust-Quellstand:20Dateien, SourceTreeSHA256 `91dd94465468707bff690c01da81a364387fb83641cebd64aceea757e5ec4727`, Einzelhashes in `source-manifest.json`.

Drei betroffene Dateien: neue kleine `source_canvas.rs`, bestehende `source_raster.rs` und Modulregistrierung/minimale vorhandene Selftesthooks in `main.rs`. Keine Cargo-/Dependency-/Core-/Bridgeänderung. Beide vorhandenen Ausgangsdateien stimmen weiterhin mit dem Repository überein.

## Verhalten

Anpassen/Fit,100%,Verkleinern/Vergrößern in einem scrollbaren Viewport. Manuelle Skalierung25–400% der bereits geprüften PNG-Pixel;100% heißt exakt ein PNG-Pixel je logischem GTK-Pixel, auch bei GDK_SCALE2. Ganze angezeigte Prozentwerte entsprechen der tatsächlichen Skalierung. Fit passt proportional und zentriert ein und darf für schmale/kurze Viewports unter25% liegen. Zoom-out vergrößert dann nicht versehentlich auf25%. Neue Seite/neuerFrame startet wieder mit Fit; Zoomänderungen setzen Scrollpositionen zurück. Beim Resize bleibt fester Prozentzoom fest, Fit passt sich an.

Das eigene Widget meldet nur für Prozentzoom die tatsächlichen skalierten Mindestmaße an GtkViewport und zeichnet die vorhandene Textur mit Snapshot.append_texture. So erzwingt GtkPicture keine andere intrinsische Größe. Keine weitere PNG-Decodierung, neue CLI-Anfrage, Netzverbindung oder neue Rasterdatei beim Zoom. Keine Originalrechteck-Overlays oder Koordinatenvertragserweiterung. Der Hinweis benennt ausdrücklich ein PNG-Vorschauraster mit höchstens1024Pixeln je Kante; Vergrößerung lädt keine höhere Originalauflösung.

Bestehender220px-Panemindestplatz,8pxVertikalabstand und6pxControlabstände bleiben. Fit/100% und−/+ bilden zusammenhängende Gruppen, die bei700pxFensterbreite als2×2Controls umbrechen. Native Buttons bleiben keyboardfähig; verständliche AccessibleLabels, Canvas mit AccessibleRole::Img und Quellseiten-/Framebeschriftung, kein Canvas-Fokusfang.

## Ausgeführt

Alle finalen GUI-Fälle liefen im bestehenden lokalen Testimage unter eigenem Xvfb mit atomarem displayfd und eigenem Dbus/HOME/XDG. Container netzlos/read-only, nur eigener Ausgabeordner schreibbar; Root-Core bin/lib nur lesend eingebunden. Hostdesktop und reserviertes Hostdisplay wurden nicht benutzt. GTK erhielt kein Swift-LD-Override, ausschließlich der CLI-Kindwrapper. GSK_RENDERER=cairo war der GTK-Testrenderer; kein neuer Cairo-Quelldecoder wurde implementiert.

1. Finaler1×-Lauf: Fit/100%/400%, beide Scrollenden, Resize auf700×700 bei400%,25%, Fit und Resize auf1200×900; tatsächliche Widget-/Scrollgeometrie und Bildschirmansicht geprüft. Bei100%1024×768logical,400%4096×3072. Kleine Fitvorschau lässt sich durch− nicht vergrößern.
2. Gleicher finaler Lauf mit GDK_SCALE2, tatsächlicher GTKscale_factor2 und3000×2200XvfbFramebuffer.100% bleibt1024×768logical (=2048×1536device), Resize/Scroll/Close ebenfalls erfüllt.
3. Bestehender BoundRelease-Fall: Clear+Close bei weiter sichtbarer Hauptapp, Quell-FD1→0 und WeakWindow/WeakCanvas/WeakTexture wirklich freigegeben.
4. Abweisung nach Canvasaufbau: vorhandener Selftest mit syntaktisch gültigem falschem Ausgabefingerprint. Vergleich bleibt gesperrt, keine Textur erzeugt; nach Clear+Close Quell-FD0 sowie WeakWindow/WeakCanvas frei. Die Testwartezeit vor Hauptappende wurde dafür ausschließlich unter ui-self-test verlängert.
5. Bestehende frühe Descriptorabweisung: Quell-FD0 nach Clear+Close. Hier wird konstruktionsbedingt noch kein Canvas erzeugt; kein erfundener WeakCanvas-Beleg.

Die Zoomläufe prüfen dieselbe Texturobjektidentität und unveränderte Jobgeneration ohne aktive/neue Rasterjobs. Alle fünf Fälle:Exit0, synthetische Quellbytes unverändert, Source-/Originalasset-/Markdownhashes unabhängig gegen das echte CLI-Manifest geprüft. Quelle `source.png`:44957Byte, SHA256 `1f0264ed5b41673264a39c61a4d8c08250e128d6bb848dab060e81c7ef89e6fc`. Nur synthetisches Koordinatengitter.

35 bestehende GTK-App-Unit-Tests bestanden,0Fehler, einschließlich PNG-Payload-/Hash-/SourceIdentity-/UTF8-/Manifest-/Snapshotprüfungen. Der gesamte vorhandene `payload`-Validator ist bytegleich geblieben. Kein normaler Produktionsbuild ohne Selftestflag in dieser Kopie: Der reguläre Build erfolgt vereinbarungsgemäß separat nach Review/Integration, nachdem gemeinsamer/tmp-Speicher knapp wurde. Dies bleibt eine klar benannte Abnahmegrenze. Separater AT-SPI-/Screenreaderlauf und andere GSK-Renderer wurden nicht behauptet.

## Identität und Reproduktion

Ausgeführte Buildflags: `cargo build --locked --offline --release --jobs 4 -p poormans-text-gtk --features ui-self-test`; Tests entsprechend `cargo test`, jeweils `RUSTFLAGS=-C target-cpu=x86-64`. Exakter Selftest-Binaryhash und alle Quellen in `evidence.json`; Imageidentitäten in `images.txt`. Core war das echte Release0.41.13 CLI SHA26470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460, Guardcf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520.

`private_gui.py` ist der ausgeführte kleine Harness für den vorhandenen privaten Testcontainer: eigener Ordner nach `/work`, Kandidat nach `/app`, Core bin/lib nach `/runtime/bin` und `/runtime/lib`, Harness nach `/probe.py`, alles außer `/work`read-only. Namespacefähige bestehende Testumgebung verwenden, Netzwerk sperren und privates/tmp anlegen. Aufruf `/usr/bin/python3 /probe.py`. `GDK_SCALE=1|2`, `PMT_ZOOM_MODE=zoom|release|verify-error|error` wählen. Nur vorhandene Xvfb/Dbus/Pillow-Werkzeuge, kein Download. Die normalisierte Anzeige-/Arbeitsverzeichnisstruktur ist bewusst Containerlokal; keine privaten Hostpfade in der Lieferung.

`evidence.json` enthält Geometrie, Freigabemarker und verifizierte Source-/Outputhashes. `screenshots/` enthält originale final getestete1×-/2×-Ansichten. Die betroffenen Zustände wurden visuell geprüft, einschließlich700pxFit,400%-Resize/Scroll,25%und2×100%. Logs sind komprimiert. Die ersten Entwicklungsversuche und ein überstrenger früher Testmarker zählen nicht als erfolgreiche Abnahmefälle.

Eigene große Target-/Cargo-Kopien bereits entfernt; restliche eigene Quell-/Fixture-/Outputkopien und alle eigenen Container anschließend bereinigt. Vorhandene gemeinsame Images und Repositoryquellen bleiben unverändert. Kleine Lieferung bleibt zur Übernahme erhalten; Cleanup siehe `cleanup.json`.

Bei der Repoübernahme bleiben Patch und Unitlog bytegetreu als `.gz` erhalten;
angegebene Herkunftshashes beziehen sich auf die entpackten Dateien.

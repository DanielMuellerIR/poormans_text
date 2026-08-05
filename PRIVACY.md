# Privacy / Datenschutz

## English

Poor Man's Text processes the documents selected by the user entirely on the
local Mac. The app has no account system, telemetry, analytics, advertising, or
crash-reporting service and does not transmit documents or usage data to the
project owner.

Conversion invokes the local macOS text system and a locally installed Pandoc
executable. Pandoc is not bundled. The decision not to show the optional CLI
installation offer again is stored only as a local app preference.

The app does make one kind of network request: it looks for updates through
Sparkle. It fetches a signed feed from
`https://danielmuellerir.github.io/poormans_text/appcast.xml` and, only after
the user agrees, downloads the disk image from `github.com`. GitHub as the host
of both receives the data an HTTP request carries anyway, in particular the IP
address. No profile of the Mac is transmitted: Sparkle's optional hardware and
system profiling is switched off. Automatic checks can be turned off in Terminal
with `defaults write org.poormanstext.PoorMansText SUEnableAutomaticChecks -bool NO`;
the "Check for Updates …" menu item then still works on demand.

Installing or downloading the app, Pandoc, or source code may be subject to the
separate privacy practices of the chosen distribution platform or package
manager.

## Deutsch

Poor Man's Text verarbeitet die vom Nutzer ausgewählten Dokumente vollständig
auf dem lokalen Mac. Die App enthält weder Benutzerkonten noch Telemetrie,
Analyse, Werbung oder einen Crash-Reporting-Dienst und überträgt weder Dokumente
noch Nutzungsdaten an den Projektinhaber.

Die Konvertierung ruft das lokale macOS-Textsystem und eine lokal installierte
Pandoc-Datei auf. Pandoc wird nicht mitgeliefert. Die Entscheidung, das optionale
CLI-Installationsangebot nicht erneut anzuzeigen, wird nur als lokale
App-Einstellung gespeichert.

Eine Art von Netzwerkzugriff gibt es: Die App sucht über Sparkle nach Updates.
Sie lädt dazu einen signierten Feed von
`https://danielmuellerir.github.io/poormans_text/appcast.xml` und — erst nach
Zustimmung — das Image von `github.com`. GitHub als Betreiber beider Adressen
erhält dabei die Daten, die eine HTTP-Anfrage ohnehin mitbringt, insbesondere
die IP-Adresse. Ein Profil des Macs wird nicht übertragen: Sparkles optionale
Hardware- und Systemprofilierung ist abgeschaltet. Die selbsttätige Suche lässt
sich im Terminal mit
`defaults write org.poormanstext.PoorMansText SUEnableAutomaticChecks -bool NO`
abschalten; der Menüpunkt „Check for Updates …" funktioniert dann weiterhin auf
Wunsch.

Für Installation oder Download der App, von Pandoc oder des Quellcodes können
die getrennten Datenschutzbedingungen der gewählten Plattform oder
Paketverwaltung gelten.

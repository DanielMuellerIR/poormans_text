# AGENTS.md — Poor Man's Text

## Quellen der Wahrheit

- `README.md` und `README.de.md`: öffentliche Nutzung und Produktverhalten.
- `ROADMAP.md`: ausschließlich offene Produktarbeit und bewusste Grenzen.
- `CHANGELOG.md`: erledigte Arbeit und historische Release-Entscheidungen.
- `docs/ARCHITECTURE.md`: Modulgrenzen und Fastra-Integrationsziel.
- `docs/BUILD-AND-TEST.md`: Build-, Signatur-, Installations- und Testablauf.
- `docs/SPARKLE-RELEASE.md`: Update-Feed, Sparkle-Schlüssel und Appcast-Workflow.

Status und erledigte Etappen gehören nicht in diese Datei. Abgeschlossene
Roadmap-Punkte beim Release ins Changelog überführen und aus der Roadmap entfernen.

## Invarianten

- Quelldokumente nie verändern und vorhandene Ausgabeordner nie überschreiben.
- Konvertierungen vollständig in einem temporären Bereich abschließen und erst
  danach atomar ans Ziel verschieben.
- Entfernte Ressourcen nicht laden; unsichere oder fehlende Verweise als Fehler
  oder verständliche Warnung zurückgeben.
- GUI und CLI bleiben dünne Adapter. Konvertierungslogik, Erkennung, Assets und
  Diagnosen gehören in wiederverwendbare Library-Targets ohne SwiftUI-Abhängigkeit.
- Rückfragen und Bestätigungen sind Aufgabe der aufrufenden App, nie des Kerns.
- Ein Markdown-Rewriter darf Codezustände nicht an bloßen Backtick-Markern bis zum
  Dateiende fortschreiben: Inline-Code nur öffnen, wenn eine gleich lange
  Abschlussfolge existiert, sonst den Run als Literal behandeln; Fences an ihren
  Listen- oder Blockquote-Container binden, damit spätere echte Links weiter
  verarbeitet werden (Lern-Inbox 2026-08-09, Anschluss an den Review-Fix vom
  gleichen Tag).
- Identifier Englisch, nicht offensichtliche Kommentare Deutsch.

## Verifikation und Distribution

- Änderungen am Konverter brauchen Unit-Tests und mindestens ein echtes,
  temporär erzeugtes Dokumentfixture. Inhaltsverlust durch Zählungen oder
  unabhängige Output-Vergleiche ausschließen.
- Drei Einstiegspunkte, klar getrennt: `./build.sh` erzeugt nur lokale Artefakte
  im Repo-Root, `./install.sh` baut, notarisiert und installiert (kein DMG),
  `./release.sh` baut, notarisiert und packt das DMG (installiert nie). Beide
  notarisierten Wege laufen über `scripts/install.sh`, das sie per `--no-dmg`
  bzw. `--no-install` ansteuern.
- Ein vollständiges Release ist genau ein Lauf: `./install.sh --with-dmg`. Nur so
  stammen Repo-App, installierte App und die App im DMG aus demselben signierten
  Bundle, und nur so kann `scripts/verify_release.sh` ihre CodeDirectory-Hashes
  vergleichen. Zwei getrennte Läufe bauen und signieren zweimal.
- Ausschließlich `./install.sh` ohne `--no-notarize` darf nach `/Applications`
  oder in einen globalen CLI-Pfad schreiben. Vorher sind Developer-ID-Signatur,
  Hardened Runtime, Notary-Ticket, Stapler und Gatekeeper verbindlich.
- Notary-Profile, Zertifikatsdetails und Credentials nie einchecken oder ausgeben.
  Das gilt ebenso für den privaten Sparkle-Schlüssel: nur sein öffentlicher
  Gegenpart steht als `SUPublicEDKey` in `App/Info.plist`.
- Der Updater ist zusätzlich zur Apple-Kette abgesichert: Feed und Update-Archiv
  brauchen eine gültige Ed25519-Signatur, und Sparkles Helfer werden mit
  derselben Developer ID von innen nach außen signiert. Sparkle bleibt exakt
  gepinnt; ein Versionssprung wird bewusst geprüft.
- Versionen konsistent in `ProductInfo.swift`, `App/Info.plist`, README und
  Changelog pflegen; `CFBundleVersion` muss monoton steigen, weil Sparkle
  Versionen darüber vergleicht. Öffentliche Remotes nur auf ausdrücklichen
  Auftrag ändern.

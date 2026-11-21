# Gemeinsamer Swift-Kern und GTK unter Linux

Swift bleibt die Implementierung des Konvertierungskerns. Dadurch verwenden
beide Desktop-Plattformen dieselbe Formaterkennung, dieselben Parserregeln,
Diagnosen, Konvertierungsprofile und Ergebnisse. Plattformabhängige
Funktionen werden an den Stellen gebunden, an denen sie benötigt werden,
etwa PDFKit unter macOS und Poppler unter Linux.

Die GTK-Oberfläche ist in Rust umgesetzt und startet die lokale CLI über
eine typisierte Bridge. Die Prozessgrenze erlaubt ihr, Werkzeuglaufzeit,
Lebensdauer, Eingabedeskriptoren und Cleanup zu kontrollieren. Fastra kann
denselben CLI-Vertrag als separater Consumer verwenden.

Die Portierungsproben haben den Swift-Kern und die ausgelieferte Laufzeit auf
Mint und CachyOS geprüft. Sie begründen die gemeinsame Implementierung.
Eigene Abnahmen gelten für die Plattform-Backends, Installer und
Bedienoberflächen. Die aktive Architektur, unterstützte Backends und
Prüfwege stehen in den fachlichen Anleitungen.

[Architektur](ARCHITECTURE.md) · [Linux-Build](LINUX-BUILD.md) · [Fastra-Vertrag](FASTRA-CONTRACT.md)

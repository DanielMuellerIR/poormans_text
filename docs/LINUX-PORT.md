# Poor Man’s Text unter Linux

Die Linux-Version verwendet den gemeinsamen Swift-Kern. Die GTK-App
übernimmt Dateiauswahl, Einstellungen, Profile, Vorschau und Belegeditor
und startet die lokale Swift-CLI. Linux-Ausgaben enthalten die benötigte
Swift-Laufzeit. Die Pakete richten sich an x86-64-Systeme mit kompatibler
glibc und lokal installierten Formatwerkzeugen.

- [Installation, Build, Paketierung und Abhängigkeiten](LINUX-BUILD.md)
- [Plattformgrenzen und Prozessaufsicht](ARCHITECTURE.md)
- [CLI-Vertrag für aufrufende Apps](FASTRA-CONTRACT.md)
- [Konvertierungsqualität und Referenzkorpus](CONVERSION-QUALITY.md)
- [Desktop- und Paketprüfung zu 0.41.24](releases/0.41.24-verification.md)

Änderungen gegenüber früheren Versionen stehen im [Changelog](../CHANGELOG.md).
Die Prüfungen mit realen Dokumenten unterscheiden Inhaltsqualität,
Dateiintegrität und Bedienung. Für PDF, Bildformate, OCR und Belegextraktion
ist die tatsächliche Verfügbarkeit lokaler Backends maßgeblich.
`poormans-text --formats` zeigt den lokalen Formatkatalog.

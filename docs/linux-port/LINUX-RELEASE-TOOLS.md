# Linux-Releasewerkzeuge: Prüfstand 2026-11-05

Die Linux-Einstiege für Build, Paketierung, optionale OpenPGP-Signaturen,
Signaturprüfung und native Installation sind implementiert. Nutzung:
[LINUX-BUILD.md](../LINUX-BUILD.md#build--paket--und-signaturskripte).

## Bestandene Proben

- `python3 scripts/test_linux_release.py`: zehn Tests, kein Fehler. Echte
  temporäre Ed25519-Signaturen; falscher Fingerprint und veränderte Paketbytes
  werden abgewiesen. Bestehende Signaturen bleiben erhalten; Symlinks und FIFOs
  werden abgewiesen. Wrapper wählen GUI beziehungsweise ausdrücklich CLI-only.
- Native Installer mit echten kleinen synthetischen DEB-/Arch-Paketen und
  ersetzten Paketmanagerprozessen: geprüfte temporäre Paketkopie, erhaltene
  Arch-Signatur, korrekte apt-/pacman-Argumente, Cleanup und Dry-run bestätigt.
  Fremde Paketidentitäten und falsche Signaturen verhindern den Manageraufruf.
- Vier echte GUI-Paketformate aus der bereits qualifizierten Laufzeit 0.41.17
  mit `release-linux.sh --no-build --sign-key …` erzeugt: DEB, Arch, Tar-Zstandard,
  ZIP. Bau unter `umask 077`; alle vier Signaturen separat mit exportiertem
  öffentlichen Testschlüssel und erwartetem Fingerprint erfolgreich geprüft.
- `scripts/linux-probes/p15/verify_packages.py`: alle vier Formate entpackt,
  öffentliche Datei-/Verzeichnisrechte und ausführbare Launcher geprüft. Nach
  Verschieben an einen Unicode-Pfad tatsächlich CSV konvertiert; Inhalt,
  unveränderte Quelle und Hashes aller gemeldeten Ausgaben stimmen.
  Optionale Modelle und alte GUI-Buildkopien sind nicht enthalten. Erneute
  Paketierung endet bei Kollision mit 73 und verändert keine Ausgaben;
  ein Symlink im Ausgabeelternpfad wird ohne Veröffentlichung abgewiesen.
- Bash-Syntax, Python-Kompilierung und `git diff --check` bestanden.

## Grenzen und Cleanup

Die Prüfungen haben keine Systeminstallation ausgeführt. apt-/pacman-Integration
am realen Host, dessen konkrete Vertrauensrichtlinie und die abschließende
Desktop-Abnahme bleiben separat zu prüfen. Die Wrapper verwenden die vorhandenen
Buildabläufe; für diese Werkzeugänderung wurde der unveränderte Swift-/GTK-Code
nicht erneut kompiliert. Es wurde kein eigener produktiver Signierschlüssel
konfiguriert und nichts veröffentlicht. Ein Testschlüssel belegt den Mechanismus,
keine Herkunft eines offiziellen Releases.

Temporäre Schlüssel, Agenten, entpackte Laufzeiten und die mit Wegwerfschlüsseln
signierten Testpakete werden nach Abschluss entfernt. Die qualifizierte lokale
Produktlaufzeit und bestehende Handoff-Artefakte bleiben erhalten.

Die Skripte sind in die Produktwerkzeuge integriert. Die bestandenen Proben
heben bekannte OCR-Qualitätsgrenzen oder die ausstehende Desktop-Abnahme nicht auf.

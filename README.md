# VencordAutoInstaller

Dieses Projekt enthält ein Windows-Batch-Script, das Vencord automatisch verwaltet.

Datei: `VencordAutoInstaller.bat`

## Funktionen

- lädt den **offiziellen Vencord CLI Installer** von GitHub herunter
- richtet einen **Autostart-Eintrag** ein
- startet beim Windows-Start **unsichtbar im Hintergrund** (über VBS-Launcher)
- prüft bei jedem Start, ob Vencord in Discord noch injiziert ist
- installiert Vencord automatisch neu, falls es nicht mehr vorhanden ist
- schreibt Logs nach:
  - `%LOCALAPPDATA%\VencordAutoInstaller\vencord_installer.log`

## Offizielle Download-Quelle

Das Script verwendet die offizielle Release-URL:

`https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe`

## Installation / Erststart

1. `VencordAutoInstaller.bat` einmal manuell starten.
2. Das Script erstellt:
   - `%LOCALAPPDATA%\VencordAutoInstaller\VencordInstallerCli.exe`
   - `%LOCALAPPDATA%\VencordAutoInstaller\VencordSilentLauncher.vbs`
3. Das Script setzt den Autostart unter:
   - `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
4. Beim nächsten Windows-Start läuft die Prüfung automatisch im Hintergrund.

## Wie die Prüfung funktioniert

Das Script prüft Discord (Stable/PTB/Canary) im jeweiligen `app-*` Verzeichnis auf Vencord-Indikatoren:

- `resources\_app.asar` (Backup der Originaldatei)
- `resources\app\patcher.js`
- optionaler Größenindikator bei `resources\app.asar`

Wenn kein Indikator gefunden wird, wird automatisch `install` über den Vencord CLI Installer ausgeführt.

## Sicherheit

- Es sind **keine sensiblen Daten** (Tokens, API-Keys, Passwörter) im Script hinterlegt.
- Es werden nur Benutzerpfade (`%LOCALAPPDATA%`) und ein Benutzer-Registryzweig (`HKCU`) verwendet.
- Es wird ausschließlich von der offiziellen Vencord-Quelle heruntergeladen.

## Hinweise

- Discord wird während einer Neuinstallation ggf. automatisch beendet.
- Falls der Download fehlschlägt, Internetverbindung prüfen und Script erneut starten.
- Für Diagnose die Logdatei prüfen:
  - `%LOCALAPPDATA%\VencordAutoInstaller\vencord_installer.log`

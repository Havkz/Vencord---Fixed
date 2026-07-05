die n# VencordRepair v2.0

Überwacht und repariert Vencord automatisch nach Discord-Updates.

## Technische Ursache: Warum verschwindet Vencord?

Discord verwendet **Squirrel** für automatische Updates. Bei jedem Update:

1. Squirrel erstellt ein **neues** `app-X.Y.Z` Verzeichnis
2. Das **alte** Verzeichnis (mit Vencord-Patch) wird **gelöscht**
3. Die neue `app.asar` ist die **ungepatchte** Original-Datei
4. Vencord ist weg

Einstellungen und Dist-Dateien bleiben erhalten, nur der Patch in `app.asar` fehlt.

## Dateien

| Datei | Beschreibung |
| --- | --- |
| `VencordRepair.ps1` | Haupt-Script mit allen Funktionen |
| `VencordRepair.bat` | Wrapper für Doppelklick-Start |

## Befehle

### Autostart einrichten und Überwachung starten

```powershell
.\VencordRepair.ps1 -Action Install
```

Erstellt einen Autostart-Eintrag und startet die Überwachung. Nach dem nächsten
Windows-Login prüft das Script alle 15 Minuten im Hintergrund.

### Einmalige Reparatur

```powershell
.\VencordRepair.ps1 -Action Repair
```

### Nur prüfen (keine Änderungen)

```powershell
.\VencordRepair.ps1 -Action Check
```

### Systemstatus anzeigen

```powershell
.\VencordRepair.ps1 -Action Status
```

Zeigt Discord-Version, Vencord-Patch-Status, Autostart, laufende Watch-Instanz,
Backups, letzter Log-Eintrag und Prüfintervall.

### Autostart und Überwachung entfernen

```powershell
.\VencordRepair.ps1 -Action Uninstall
```

Entfernt nur den Autostart-Eintrag. Vencord bleibt installiert.

### Einstellungs-Backup wiederherstellen

```powershell
.\VencordRepair.ps1 -Action Restore
```

Stellt das letzte Backup der Vencord-Einstellungen wieder her.

### Endlosschleife für Autostart

```powershell
.\VencordRepair.ps1 -Action Watch
```

Wird automatisch vom Autostart verwendet. Prüft alle 15 Minuten. Verhindert
parallele Instanzen über einen globalen Mutex.

## Autostart-Details

- **Methode:** Windows Aufgabenplanung (Scheduled Task)
- **Taskname:** `VencordRepair Watch`
- **Trigger:** Bei Benutzer-Login
- **Aktion:** `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<Pfad>" -Action Watch`
- **Prüfintervall:** 15 Minuten
- **Instanzschutz:** `MultipleInstances = IgnoreNew` + globaler Mutex
- **Fehlerverhalten:** `RestartCount = 0`, kein endloses Neustarten
- **Fenster:** Vollständig unsichtbar, kein CMD/PowerShell-Fenster
- **Update-Schutz:** Wartet, falls Discord `Update.exe` gerade läuft
- **Alle Meldungen:** Nur in Logdatei, nicht in Konsole

## Was das Script macht (Repair)

1. **Wartet** falls Discord gerade ein Update durchführt
2. **Prüft** alle Discord-Varianten (Stable, PTB, Canary)
3. **Sichert** Vencord-Einstellungen (bis zu 10 Backups)
4. **Lädt** den offiziellen VencordInstallerCli.exe herunter
5. **Schließt** Discord falls nötig
6. **Installiert** Vencord via CLI Installer
7. **Verifiziert** den Patch
8. **Startet** Discord neu falls es vorher lief

## Was das Script NICHT macht

- Keine Deaktivierung von Windows Defender oder SmartScreen
- Keine VBS-Launcher oder getarnte Prozesse
- Keine Änderungen außerhalb der Discord/Vencord-Verzeichnisse
- Keine unbekannten Binärdateien

## Dateien und Pfade

### Durch VencordRepair erstellt

| Pfad | Beschreibung |
| --- | --- |
| `%LOCALAPPDATA%\VencordRepair\repair.log` | Log-Datei mit Zeitstempel |
| `%LOCALAPPDATA%\VencordRepair\backups\` | Einstellungs-Backups, max. 10 |
| `%TEMP%\VencordInstallerCli.exe` | Installer-Cache, max. 7 Tage |

### Vencord-Einstellungen (bleiben bei Updates erhalten)

| Pfad | Beschreibung |
| --- | --- |
| `%APPDATA%\Vencord\settings\settings.json` | Plugin-Einstellungen |
| `%APPDATA%\Vencord\settings\quickCss.css` | Benutzerdefiniertes CSS |
| `%APPDATA%\Vencord\dist\` | Dist-Dateien (patcher.js etc.) |

## Deaktivierung und Entfernung

Überwachung entfernen:

```powershell
.\VencordRepair.ps1 -Action Uninstall
```

Entfernt den Scheduled Task `VencordRepair Watch` und eventuelle alte
Registry-Autostart-Einträge. Vencord selbst bleibt installiert.

Oder manuell: Aufgabenplanung öffnen, Task `VencordRepair Watch` löschen.

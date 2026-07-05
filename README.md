# VencordRepair

Repariert Vencord automatisch nach Discord-Updates.

## Technische Ursache: Warum verschwindet Vencord?

Discord verwendet **Squirrel** (`Update.exe`) für automatische Updates. Der Update-Ablauf:

1. Discord lädt ein neues Update-Paket herunter (`.nupkg`)
2. Squirrel erstellt ein **neues** `app-X.Y.Z` Verzeichnis unter `%LOCALAPPDATA%\Discord\`
3. Das **alte** Verzeichnis (das den Vencord-Patch enthielt) wird **gelöscht**
4. Die neue `app.asar` im neuen Ordner ist die **originale, ungepatchte** Discord-Datei
5. → Vencord ist weg

**Was NICHT verloren geht:**
- Vencord-Einstellungen (`%APPDATA%\Vencord\settings\settings.json`)
- Vencord-Dist-Dateien (`%APPDATA%\Vencord\dist\`)
- Nur der Patch in `resources\app.asar` wird ersetzt

**Windows Defender** ist **nicht** die Ursache — es wurden keine Vencord-bezogenen Threats gefunden.

## Dateien

| Datei | Beschreibung |
|---|---|
| `VencordRepair.ps1` | Haupt-Script (PowerShell) mit allen Funktionen |
| `VencordRepair.bat` | Wrapper für Doppelklick-Start |

## Verwendung

### Reparatur (Standard)
Doppelklick auf `VencordRepair.bat` oder:
```powershell
.\VencordRepair.ps1
.\VencordRepair.ps1 -Action Repair
```

### Nur Status prüfen (keine Änderungen)
```powershell
.\VencordRepair.ps1 -Action Check
```

### Detaillierten Systemstatus anzeigen
```powershell
.\VencordRepair.ps1 -Action Status
```

### Vencord deinstallieren
```powershell
.\VencordRepair.ps1 -Action Uninstall
```

## Was das Script macht (Repair)

1. **Prüft** alle Discord-Varianten (Stable, PTB, Canary) auf Vencord-Patch
2. **Sichert** vorhandene Vencord-Einstellungen (bis zu 10 Backups)
3. **Lädt** den offiziellen VencordInstallerCli.exe herunter (von GitHub)
4. **Schließt** Discord (alle Varianten) falls nötig
5. **Installiert** Vencord via CLI Installer für jede betroffene Variante
6. **Verifiziert** die Installation
7. **Startet** Discord neu falls es vorher lief

## Was das Script NICHT macht

- Keine dauerhafte Deaktivierung von Windows Defender oder SmartScreen
- Keine versteckten Hintergrundprozesse oder Autostart-Einträge
- Keine Änderungen außerhalb der Discord/Vencord-Verzeichnisse
- Keine unbekannten Binärdateien — nur der offizielle Vencord CLI Installer

## Geänderte Dateien und Pfade

### Durch Vencord (beim Patch)
| Pfad | Änderung |
|---|---|
| `%LOCALAPPDATA%\Discord\app-X.Y.Z\resources\app.asar` | Ersetzt durch kleine Patcher-Datei (~218 Bytes) |
| `%LOCALAPPDATA%\Discord\app-X.Y.Z\resources\_app.asar` | Original-Backup der app.asar (~3.6 MB) |

### Durch VencordRepair
| Pfad | Beschreibung |
|---|---|
| `%LOCALAPPDATA%\VencordRepair\repair.log` | Log-Datei |
| `%LOCALAPPDATA%\VencordRepair\backups\` | Einstellungs-Backups (max. 10) |
| `%TEMP%\VencordInstallerCli.exe` | Temporärer Installer (max. 7 Tage gecacht) |

### Vencord-Einstellungen (bleiben bei Updates erhalten)
| Pfad | Beschreibung |
|---|---|
| `%APPDATA%\Vencord\settings\settings.json` | Alle Plugin-Einstellungen |
| `%APPDATA%\Vencord\settings\quickCss.css` | Benutzerdefiniertes CSS |
| `%APPDATA%\Vencord\dist\` | Vencord-Dist-Dateien (patcher.js, renderer.js etc.) |

## Rückgängig machen

```powershell
.\VencordRepair.ps1 -Action Uninstall
```

Stellt die originale `app.asar` aus dem Backup `_app.asar` wieder her.
Einstellungen bleiben unter `%APPDATA%\Vencord\settings\` erhalten.

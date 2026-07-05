#Requires -Version 5.1
<#
.SYNOPSIS
    VencordRepair - Überwacht und repariert Vencord nach Discord-Updates.

.DESCRIPTION
    Discord-Squirrel-Updates ersetzen das app-Verzeichnis und entfernen dabei
    den Vencord-Patch. Dieses Script erkennt fehlende Patches und repariert
    sie automatisch. Einstellungen bleiben erhalten.

.PARAMETER Action
    Check     Einmal prüfen ob Vencord installiert ist
    Repair    Einmal reparieren falls nötig
    Install   Autostart einrichten und Überwachung starten
    Watch     Endlosschleife, prüft alle 15 Minuten
    Status    Detaillierten Systemstatus anzeigen
    Uninstall Autostart entfernen und Überwachung beenden
    Restore   Letztes Einstellungs-Backup wiederherstellen
#>

[CmdletBinding()]
param(
    [ValidateSet('Check','Repair','Install','Watch','Status','Uninstall','Restore')]
    [string]$Action = 'Repair'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Konfiguration
# ============================================================

$VencordDistDir      = Join-Path $env:APPDATA 'Vencord\dist'
$VencordSettingsDir  = Join-Path $env:APPDATA 'Vencord\settings'
$VencordSettingsFile = Join-Path $env:APPDATA 'Vencord\settings\settings.json'
$InstallerUrl        = 'https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe'
$TempInstallerPath   = Join-Path $env:TEMP 'VencordInstallerCli.exe'
$PatchedAsarMaxSize  = 50000
$DataDir             = Join-Path $env:LOCALAPPDATA 'VencordRepair'
$BackupDir           = Join-Path $DataDir 'backups'
$LogFile             = Join-Path $DataDir 'repair.log'
$AutostartName       = 'VencordRepair'
$WatchIntervalSec    = 900
$MutexName           = 'Global\VencordRepairMutex'
$ScriptVersion       = '2.0'

$DiscordVariants = @(
    @{ Name = 'Discord';       LocalDir = Join-Path $env:LOCALAPPDATA 'Discord';       Process = 'Discord' }
    @{ Name = 'DiscordPTB';    LocalDir = Join-Path $env:LOCALAPPDATA 'DiscordPTB';    Process = 'DiscordPTB' }
    @{ Name = 'DiscordCanary'; LocalDir = Join-Path $env:LOCALAPPDATA 'DiscordCanary'; Process = 'DiscordCanary' }
)

# ============================================================
# Hilfsfunktionen
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message

    if (-not (Test-Path $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8

    switch ($Level) {
        'ERROR' { Write-Host ('  [FEHLER] {0}' -f $Message) -ForegroundColor Red }
        'WARN'  { Write-Host ('  [WARNUNG] {0}' -f $Message) -ForegroundColor Yellow }
        'OK'    { Write-Host ('  [OK] {0}' -f $Message) -ForegroundColor Green }
        default { Write-Host ('  [INFO] {0}' -f $Message) -ForegroundColor Cyan }
    }
}

function Get-LatestAppDir {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $dirs = @(Get-ChildItem -Path $Dir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    if ($dirs.Count -eq 0) { return $null }
    return $dirs[0].FullName
}

function Test-VencordPatched {
    param([string]$AppDir)

    $appAsar    = Join-Path $AppDir 'resources\app.asar'
    $backupAsar = Join-Path $AppDir 'resources\_app.asar'

    $result = [PSCustomObject]@{
        AppDir      = $AppDir
        AppAsar     = $appAsar
        BackupAsar  = $backupAsar
        IsPatched   = $false
        HasBackup   = $false
        AsarSize    = 0
        Details     = ''
    }

    if (-not (Test-Path $appAsar)) {
        $result.Details = 'app.asar existiert nicht'
        return $result
    }

    $item = Get-Item $appAsar
    $result.AsarSize  = $item.Length
    $result.HasBackup = Test-Path $backupAsar

    if ($item.Length -lt $PatchedAsarMaxSize) {
        $content = Get-Content $appAsar -Raw -ErrorAction SilentlyContinue
        if ($content -match 'patcher\.js') {
            $result.IsPatched = $true
            $result.Details = 'Vencord-Patch aktiv, app.asar = {0} Bytes' -f $item.Length
        } else {
            $result.Details = 'app.asar klein aber kein Vencord-Verweis, {0} Bytes' -f $item.Length
        }
    } else {
        $result.Details = 'app.asar original/ungepatcht, {0} Bytes' -f $item.Length
    }
    return $result
}

function Test-PatcherFilesExist {
    $patcher = Join-Path $VencordDistDir 'patcher.js'
    return (Test-Path $patcher)
}

function Backup-VencordSettings {
    if (-not (Test-Path $VencordSettingsFile)) {
        Write-Log 'Keine Vencord-Einstellungen zum Sichern gefunden' 'WARN'
        return $null
    }
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dest = Join-Path $BackupDir ('settings_backup_{0}.json' -f $ts)
    Copy-Item -Path $VencordSettingsFile -Destination $dest -Force
    Write-Log ('Einstellungen gesichert: {0}' -f $dest) 'OK'

    # Maximal 10 Backups behalten
    $old = @(Get-ChildItem -Path $BackupDir -Filter 'settings_backup_*.json' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10)
    foreach ($f in $old) {
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }
    return $dest
}

function Stop-DiscordProcesses {
    $stopped = $false
    foreach ($v in $DiscordVariants) {
        $procs = Get-Process -Name $v.Process -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log ('{0} wird geschlossen, {1} Prozesse' -f $v.Name, @($procs).Count)
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $stopped = $true
        }
    }
    if ($stopped) {
        Write-Log 'Warte 3 Sekunden...'
        Start-Sleep -Seconds 3
    }
    return $stopped
}

function Test-DiscordUpdating {
    # Prüfe ob Update.exe gerade läuft
    $updating = Get-Process -Name 'Update' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -match 'Discord' }
    return ($null -ne $updating)
}

function Wait-ForDiscordUpdate {
    $waited = $false
    while (Test-DiscordUpdating) {
        if (-not $waited) {
            Write-Log 'Discord Update.exe läuft, warte...' 'WARN'
            $waited = $true
        }
        Start-Sleep -Seconds 10
    }
    if ($waited) {
        Write-Log 'Discord-Update abgeschlossen, fahre fort'
        Start-Sleep -Seconds 5
    }
}

function Get-VencordInstaller {
    if (Test-Path $TempInstallerPath) {
        $age = (Get-Date) - (Get-Item $TempInstallerPath).LastWriteTime
        if ($age.TotalDays -lt 7) {
            $sz = (Get-Item $TempInstallerPath).Length
            Write-Log ('Verwende vorhandenen Installer, {0} Bytes, {1} Tage alt' -f $sz, [int]$age.TotalDays)
            return $TempInstallerPath
        }
        Remove-Item $TempInstallerPath -Force
    }

    Write-Log ('Lade Installer herunter: {0}' -f $InstallerUrl)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($InstallerUrl, $TempInstallerPath)
        $wc.Dispose()
    } catch {
        Write-Log ('Download fehlgeschlagen: {0}' -f $_.Exception.Message) 'ERROR'
        return $null
    }

    if (-not (Test-Path $TempInstallerPath)) {
        Write-Log 'Installer nach Download nicht vorhanden' 'ERROR'
        return $null
    }

    $sz = (Get-Item $TempInstallerPath).Length
    Write-Log ('Installer heruntergeladen, {0} Bytes' -f $sz) 'OK'
    return $TempInstallerPath
}

function Invoke-VencordInstallForDir {
    param([string]$InstallerPath, [string]$DiscordDir)

    Write-Log ('Installiere Vencord für: {0}' -f $DiscordDir)

    $proc = Start-Process -FilePath $InstallerPath `
        -ArgumentList '--install', '--location', (('"{0}"') -f $DiscordDir) `
        -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    if ($proc -and $proc.ExitCode -eq 0) {
        Write-Log 'Installation mit --location erfolgreich' 'OK'
        return $true
    }

    Write-Log '--location fehlgeschlagen, versuche --branch auto' 'WARN'
    $proc = Start-Process -FilePath $InstallerPath `
        -ArgumentList '--install', '--branch', 'auto' `
        -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    if ($proc -and $proc.ExitCode -eq 0) {
        Write-Log '--branch auto erfolgreich' 'OK'
        return $true
    }

    $ec = if ($proc) { $proc.ExitCode } else { 'unbekannt' }
    Write-Log ('Installation fehlgeschlagen, Exit-Code: {0}' -f $ec) 'ERROR'
    return $false
}

function Get-AutostartValue {
    $scriptPath = $PSCommandPath
    return 'PowerShell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Watch' -f $scriptPath
}

function Get-AutostartRegistryPath {
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

function Test-AutostartInstalled {
    $regPath = Get-AutostartRegistryPath
    try {
        $val = Get-ItemProperty -Path $regPath -Name $AutostartName -ErrorAction SilentlyContinue
        return ($null -ne $val)
    } catch {
        return $false
    }
}

# ============================================================
# Aktionen
# ============================================================

function Invoke-Check {
    Write-Host ''
    Write-Host '  Vencord-Status prüfen...' -ForegroundColor White
    Write-Host ('  {0}' -f ('=' * 50)) -ForegroundColor DarkGray

    $anyFound = $false
    $allPatched = $true

    foreach ($v in $DiscordVariants) {
        $appDir = Get-LatestAppDir -Dir $v.LocalDir
        if (-not $appDir) { continue }

        $anyFound = $true
        $check = Test-VencordPatched -AppDir $appDir
        $ver = Split-Path $appDir -Leaf

        if ($check.IsPatched) {
            Write-Log ('{0} {1}: {2}' -f $v.Name, $ver, $check.Details) 'OK'
        } else {
            Write-Log ('{0} {1}: {2}' -f $v.Name, $ver, $check.Details) 'WARN'
            $allPatched = $false
        }
    }

    if (-not $anyFound) {
        Write-Log 'Keine Discord-Installation gefunden' 'WARN'
        return $false
    }

    if (Test-PatcherFilesExist) {
        Write-Log ('Vencord-Dist vorhanden: {0}' -f $VencordDistDir) 'OK'
    } else {
        Write-Log ('Vencord-Dist FEHLT: {0}' -f $VencordDistDir) 'ERROR'
        $allPatched = $false
    }

    if (Test-Path $VencordSettingsFile) {
        $sz = (Get-Item $VencordSettingsFile).Length
        Write-Log ('Einstellungen vorhanden, {0} Bytes' -f $sz) 'OK'
    } else {
        Write-Log 'Keine Vencord-Einstellungen gefunden' 'INFO'
    }

    return $allPatched
}

function Invoke-Repair {
    Write-Host ''
    Write-Host '  Vencord-Reparatur...' -ForegroundColor White
    Write-Host ('  {0}' -f ('=' * 50)) -ForegroundColor DarkGray

    Wait-ForDiscordUpdate

    $needsRepair = $false
    $toRepair = @()

    foreach ($v in $DiscordVariants) {
        $appDir = Get-LatestAppDir -Dir $v.LocalDir
        if (-not $appDir) { continue }

        $check = Test-VencordPatched -AppDir $appDir
        if (-not $check.IsPatched) {
            $needsRepair = $true
            $toRepair += @{ Variant = $v; AppDir = $appDir; Check = $check }
            Write-Log ('{0}: Reparatur nötig - {1}' -f $v.Name, $check.Details) 'WARN'
        } else {
            Write-Log ('{0}: Patch intakt - {1}' -f $v.Name, $check.Details) 'OK'
        }
    }

    if (-not $needsRepair) {
        Write-Log 'Alle Installationen gepatcht. Keine Reparatur nötig.' 'OK'
        return $true
    }

    Backup-VencordSettings

    $installer = Get-VencordInstaller
    if (-not $installer) {
        Write-Log 'Installer nicht verfügbar. Abbruch.' 'ERROR'
        return $false
    }

    $wasRunning = Stop-DiscordProcesses

    $allOk = $true
    foreach ($item in $toRepair) {
        $ok = Invoke-VencordInstallForDir -InstallerPath $installer -DiscordDir $item.Variant.LocalDir
        if (-not $ok) { $allOk = $false }
    }

    Write-Host ''
    Write-Host '  Verifizierung...' -ForegroundColor White
    foreach ($item in $toRepair) {
        $appDir = Get-LatestAppDir -Dir $item.Variant.LocalDir
        if ($appDir) {
            $v = Test-VencordPatched -AppDir $appDir
            if ($v.IsPatched) {
                Write-Log ('{0}: Reparatur erfolgreich' -f $item.Variant.Name) 'OK'
            } else {
                Write-Log ('{0}: Reparatur fehlgeschlagen - {1}' -f $item.Variant.Name, $v.Details) 'ERROR'
                $allOk = $false
            }
        }
    }

    if ($wasRunning) {
        $upd = Join-Path $env:LOCALAPPDATA 'Discord\Update.exe'
        if (Test-Path $upd) {
            Start-Process -FilePath $upd -ArgumentList '--processStart', 'Discord.exe'
            Write-Log 'Discord neu gestartet' 'OK'
        }
    }

    return $allOk
}

function Invoke-Install {
    Write-Host ''
    Write-Host '  Autostart einrichten...' -ForegroundColor White
    Write-Host ('  {0}' -f ('=' * 50)) -ForegroundColor DarkGray

    $regPath = Get-AutostartRegistryPath
    $regValue = Get-AutostartValue

    try {
        Set-ItemProperty -Path $regPath -Name $AutostartName -Value $regValue -Force
        Write-Log ('Autostart-Eintrag erstellt: {0}' -f $AutostartName) 'OK'
        Write-Log ('Registry: {0}\{1}' -f $regPath, $AutostartName) 'INFO'
        Write-Log ('Wert: {0}' -f $regValue) 'INFO'
    } catch {
        Write-Log ('Autostart-Eintrag fehlgeschlagen: {0}' -f $_.Exception.Message) 'ERROR'
        return
    }

    # Direkt eine Reparatur durchführen
    $null = Invoke-Repair

    # Dann in Watch-Modus wechseln
    Write-Log 'Starte Überwachung...' 'OK'
    Invoke-Watch
}

function Invoke-Watch {
    # Mutex: Nur eine Instanz erlauben
    $mutexCreated = $false
    try {
        $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$mutexCreated)
    } catch {
        Write-Log 'Konnte Mutex nicht erstellen, möglicherweise läuft bereits eine Instanz' 'ERROR'
        return
    }

    if (-not $mutexCreated) {
        Write-Log 'Eine andere VencordRepair-Instanz läuft bereits. Beende.' 'WARN'
        $mutex.Dispose()
        return
    }

    Write-Log ('Überwachung gestartet, Intervall: {0} Sekunden' -f $WatchIntervalSec) 'OK'

    try {
        while ($true) {
            try {
                Wait-ForDiscordUpdate

                $repaired = $false
                foreach ($v in $DiscordVariants) {
                    $appDir = Get-LatestAppDir -Dir $v.LocalDir
                    if (-not $appDir) { continue }

                    $check = Test-VencordPatched -AppDir $appDir
                    if (-not $check.IsPatched) {
                        Write-Log ('{0}: Patch fehlt, starte Reparatur' -f $v.Name) 'WARN'

                        Backup-VencordSettings

                        $installer = Get-VencordInstaller
                        if ($installer) {
                            $wasRunning = Stop-DiscordProcesses
                            $null = Invoke-VencordInstallForDir -InstallerPath $installer -DiscordDir $v.LocalDir

                            # Verifizieren
                            $verify = Test-VencordPatched -AppDir (Get-LatestAppDir -Dir $v.LocalDir)
                            if ($verify.IsPatched) {
                                Write-Log ('{0}: Automatische Reparatur erfolgreich' -f $v.Name) 'OK'
                            } else {
                                Write-Log ('{0}: Automatische Reparatur fehlgeschlagen' -f $v.Name) 'ERROR'
                            }

                            if ($wasRunning) {
                                $upd = Join-Path $env:LOCALAPPDATA 'Discord\Update.exe'
                                if (Test-Path $upd) {
                                    Start-Process -FilePath $upd -ArgumentList '--processStart', 'Discord.exe'
                                }
                            }
                            $repaired = $true
                        }
                    }
                }

                if (-not $repaired) {
                    Write-Log 'Prüfung: Alle Patches intakt'
                }
            } catch {
                Write-Log ('Fehler im Watch-Loop: {0}' -f $_.Exception.Message) 'ERROR'
            }

            Start-Sleep -Seconds $WatchIntervalSec
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
        Write-Log 'Überwachung beendet'
    }
}

function Invoke-StatusAction {
    Write-Host ''
    Write-Host '  Vencord-Systemstatus' -ForegroundColor White
    Write-Host ('  {0}' -f ('=' * 50)) -ForegroundColor DarkGray

    # Discord
    Write-Host ''
    Write-Host '  Discord-Installationen:' -ForegroundColor White
    foreach ($v in $DiscordVariants) {
        if (-not (Test-Path $v.LocalDir)) {
            Write-Host ('    {0}: nicht installiert' -f $v.Name) -ForegroundColor DarkGray
            continue
        }
        $appDir = Get-LatestAppDir -Dir $v.LocalDir
        if (-not $appDir) {
            Write-Host ('    {0}: kein app-* Verzeichnis' -f $v.Name) -ForegroundColor Yellow
            continue
        }
        $ver = Split-Path $appDir -Leaf
        $check = Test-VencordPatched -AppDir $appDir

        $color = if ($check.IsPatched) { 'Green' } else { 'Yellow' }
        $tag   = if ($check.IsPatched) { 'GEPATCHT' } else { 'UNGEPATCHT' }

        Write-Host ('    {0} - {1}: ' -f $v.Name, $ver) -NoNewline
        Write-Host ('[{0}]' -f $tag) -ForegroundColor $color
        Write-Host ('      app.asar: {0} Bytes' -f $check.AsarSize) -ForegroundColor DarkGray
        $bk = if ($check.HasBackup) { 'vorhanden' } else { 'nicht vorhanden' }
        Write-Host ('      _app.asar Backup: {0}' -f $bk) -ForegroundColor DarkGray
        Write-Host ('      Pfad: {0}' -f $appDir) -ForegroundColor DarkGray
    }

    # Vencord-Dateien
    Write-Host ''
    Write-Host '  Vencord-Dateien:' -ForegroundColor White
    $patcher = Join-Path $VencordDistDir 'patcher.js'
    if (Test-Path $patcher) {
        $pi = Get-Item $patcher
        Write-Host ('    patcher.js: vorhanden, {0} Bytes, {1}' -f $pi.Length, $pi.LastWriteTime) -ForegroundColor Green
    } else {
        Write-Host '    patcher.js: FEHLT' -ForegroundColor Red
    }
    if (Test-Path $VencordSettingsFile) {
        $si = Get-Item $VencordSettingsFile
        Write-Host ('    settings.json: vorhanden, {0} Bytes' -f $si.Length) -ForegroundColor Green
    } else {
        Write-Host '    settings.json: nicht vorhanden' -ForegroundColor Yellow
    }

    # Autostart
    Write-Host ''
    Write-Host '  Autostart:' -ForegroundColor White
    if (Test-AutostartInstalled) {
        $regPath = Get-AutostartRegistryPath
        $val = (Get-ItemProperty -Path $regPath -Name $AutostartName).$AutostartName
        Write-Host ('    {0}: aktiv' -f $AutostartName) -ForegroundColor Green
        Write-Host ('    Wert: {0}' -f $val) -ForegroundColor DarkGray
    } else {
        Write-Host ('    {0}: nicht eingerichtet' -f $AutostartName) -ForegroundColor Yellow
    }

    # Laufende Instanz
    Write-Host ''
    Write-Host '  Überwachung:' -ForegroundColor White
    $mutexCheck = $false
    try {
        $m = New-Object System.Threading.Mutex($true, $MutexName, [ref]$mutexCheck)
        if ($mutexCheck) {
            Write-Host '    Keine laufende Instanz' -ForegroundColor DarkGray
            $m.ReleaseMutex()
        } else {
            Write-Host '    Watch-Instanz läuft' -ForegroundColor Green
        }
        $m.Dispose()
    } catch {
        Write-Host '    Watch-Instanz läuft' -ForegroundColor Green
    }

    # Backups
    Write-Host ''
    Write-Host '  Backups:' -ForegroundColor White
    if (Test-Path $BackupDir) {
        $bks = @(Get-ChildItem $BackupDir -Filter 'settings_backup_*.json' -ErrorAction SilentlyContinue)
        Write-Host ('    {0} Einstellungs-Backups unter: {1}' -f $bks.Count, $BackupDir) -ForegroundColor DarkGray
        if ($bks.Count -gt 0) {
            $latest = $bks | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            Write-Host ('    Letztes Backup: {0}' -f $latest.LastWriteTime) -ForegroundColor DarkGray
        }
    } else {
        Write-Host '    Keine Backups vorhanden' -ForegroundColor DarkGray
    }

    # Letzter Check aus Log
    Write-Host ''
    Write-Host '  Log:' -ForegroundColor White
    Write-Host ('    Pfad: {0}' -f $LogFile) -ForegroundColor DarkGray
    if (Test-Path $LogFile) {
        $lastLines = @(Get-Content $LogFile -Tail 5 -ErrorAction SilentlyContinue)
        if ($lastLines.Count -gt 0) {
            Write-Host '    Letzte Einträge:' -ForegroundColor DarkGray
            foreach ($l in $lastLines) {
                Write-Host ('      {0}' -f $l) -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ''
    Write-Host ('  Prüfintervall: {0} Minuten' -f ($WatchIntervalSec / 60)) -ForegroundColor White
    Write-Host ('  Version: {0}' -f $ScriptVersion) -ForegroundColor White
}

function Invoke-UninstallAction {
    Write-Host ''
    Write-Host '  Autostart und Überwachung entfernen...' -ForegroundColor White
    Write-Host ('  {0}' -f ('=' * 50)) -ForegroundColor DarkGray

    # Autostart entfernen
    $regPath = Get-AutostartRegistryPath
    if (Test-AutostartInstalled) {
        Remove-ItemProperty -Path $regPath -Name $AutostartName -Force -ErrorAction SilentlyContinue
        Write-Log ('Autostart-Eintrag entfernt: {0}' -f $AutostartName) 'OK'
    } else {
        Write-Log 'Kein Autostart-Eintrag vorhanden' 'INFO'
    }

    Write-Host ''
    Write-Log 'Vencord selbst bleibt installiert. Nur die Überwachung wurde entfernt.' 'OK'
    Write-Log 'Zum Entfernen von Vencord: VencordRepair.ps1 -Action Repair mit manuellem Uninstall' 'INFO'
}

function Invoke-RestoreAction {
    Write-Host ''
    Write-Host '  Letztes Einstellungs-Backup wiederherstellen...' -ForegroundColor White
    Write-Host ('  {0}' -f ('=' * 50)) -ForegroundColor DarkGray

    if (-not (Test-Path $BackupDir)) {
        Write-Log 'Kein Backup-Verzeichnis vorhanden' 'ERROR'
        return
    }

    $backups = @(Get-ChildItem $BackupDir -Filter 'settings_backup_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) {
        Write-Log 'Keine Backups gefunden' 'ERROR'
        return
    }

    $latest = $backups[0]
    Write-Log ('Stelle wieder her: {0}' -f $latest.FullName) 'INFO'
    Write-Log ('Backup vom: {0}' -f $latest.LastWriteTime) 'INFO'

    # Aktuelles sichern bevor wir überschreiben
    if (Test-Path $VencordSettingsFile) {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $preRestore = Join-Path $BackupDir ('settings_pre_restore_{0}.json' -f $ts)
        Copy-Item -Path $VencordSettingsFile -Destination $preRestore -Force
        Write-Log ('Aktuelle Einstellungen gesichert: {0}' -f $preRestore) 'OK'
    }

    # Zielverzeichnis sicherstellen
    $settingsDir = Split-Path $VencordSettingsFile -Parent
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    Copy-Item -Path $latest.FullName -Destination $VencordSettingsFile -Force
    Write-Log 'Einstellungen wiederhergestellt' 'OK'
    Write-Log 'Discord muss neu gestartet werden, damit die Änderungen wirksam werden' 'INFO'
}

# ============================================================
# Hauptprogramm
# ============================================================

# Banner nur bei interaktiven Aktionen
if ($Action -ne 'Watch') {
    Write-Host ''
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host ('  |  VencordRepair v{0}                             |' -f $ScriptVersion) -ForegroundColor Cyan
    Write-Host '  |  Repariert Vencord nach Discord-Updates         |' -ForegroundColor Cyan
    Write-Host '  +================================================+' -ForegroundColor Cyan
}

Write-Log ('VencordRepair gestartet, Aktion: {0}' -f $Action)

switch ($Action) {
    'Check' {
        $result = Invoke-Check
        Write-Host ''
        if ($result) {
            Write-Host '  Ergebnis: Vencord ist vollständig installiert.' -ForegroundColor Green
        } else {
            Write-Host '  Ergebnis: Reparatur empfohlen.' -ForegroundColor Yellow
            Write-Host '    .\VencordRepair.ps1 -Action Repair' -ForegroundColor White
        }
    }
    'Repair' {
        $result = Invoke-Repair
        Write-Host ''
        if ($result) {
            Write-Host '  Reparatur abgeschlossen.' -ForegroundColor Green
        } else {
            Write-Host '  Reparatur mit Fehlern. Siehe Log:' -ForegroundColor Yellow
            Write-Host ('    {0}' -f $LogFile) -ForegroundColor White
        }
    }
    'Install' {
        Invoke-Install
    }
    'Watch' {
        Invoke-Watch
    }
    'Status' {
        Invoke-StatusAction
    }
    'Uninstall' {
        Invoke-UninstallAction
    }
    'Restore' {
        Invoke-RestoreAction
    }
}

if ($Action -ne 'Watch') {
    Write-Host ''
    Write-Log ('VencordRepair beendet, Aktion: {0}' -f $Action)
}

#Requires -Version 5.1
<#
.SYNOPSIS
    VencordRepair - Erkennt und repariert Vencord nach Discord-Updates.

.DESCRIPTION
    Discord verwendet Squirrel fuer Auto-Updates. Bei jedem Update wird ein neues
    app-X.Y.Z Verzeichnis erstellt und das alte mit Vencord-Patch geloescht.
    Dieses Script erkennt fehlende Vencord-Patches und installiert sie neu,
    ohne Einstellungen zu verlieren.

.PARAMETER Action
    Die auszufuehrende Aktion: Check, Repair, Uninstall, Status
#>

[CmdletBinding()]
param(
    [ValidateSet('Check', 'Repair', 'Uninstall', 'Status')]
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
$BackupDir           = Join-Path $env:LOCALAPPDATA 'VencordRepair\backups'
$LogFile             = Join-Path $env:LOCALAPPDATA 'VencordRepair\repair.log'

$DiscordVariants = @(
    @{ Name = 'Discord';       LocalDir = Join-Path $env:LOCALAPPDATA 'Discord';       ProcessName = 'Discord' }
    @{ Name = 'DiscordPTB';    LocalDir = Join-Path $env:LOCALAPPDATA 'DiscordPTB';    ProcessName = 'DiscordPTB' }
    @{ Name = 'DiscordCanary'; LocalDir = Join-Path $env:LOCALAPPDATA 'DiscordCanary'; ProcessName = 'DiscordCanary' }
)

# ============================================================
# Hilfsfunktionen
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Level] $Message"

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    Add-Content -Path $LogFile -Value $logLine -Encoding UTF8
    switch ($Level) {
        'ERROR'   { Write-Host "  [FEHLER] $Message" -ForegroundColor Red }
        'WARN'    { Write-Host "  [WARNUNG] $Message" -ForegroundColor Yellow }
        'OK'      { Write-Host "  [OK] $Message" -ForegroundColor Green }
        default   { Write-Host "  [INFO] $Message" -ForegroundColor Cyan }
    }
}

function Get-LatestAppDir {
    param([string]$DiscordLocalDir)

    if (-not (Test-Path $DiscordLocalDir)) { return $null }

    $appDirs = @(Get-ChildItem -Path $DiscordLocalDir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    if ($appDirs.Count -eq 0) { return $null }

    return $appDirs[0].FullName
}

function Test-VencordPatched {
    param([string]$AppDir)

    $result = [PSCustomObject]@{
        AppDir          = $AppDir
        ResourcesDir    = Join-Path $AppDir 'resources'
        AppAsar         = Join-Path $AppDir 'resources\app.asar'
        BackupAsar      = Join-Path $AppDir 'resources\_app.asar'
        IsPatched       = $false
        HasBackup       = $false
        AppAsarSize     = 0
        PatcherExists   = $false
        Details         = ''
    }

    if (-not (Test-Path $result.AppAsar)) {
        $result.Details = 'app.asar existiert nicht'
        return $result
    }

    $asarItem = Get-Item $result.AppAsar
    $result.AppAsarSize = $asarItem.Length
    $result.HasBackup = Test-Path $result.BackupAsar
    $result.PatcherExists = Test-Path (Join-Path $VencordDistDir 'patcher.js')

    if ($result.AppAsarSize -lt $PatchedAsarMaxSize) {
        $content = Get-Content $result.AppAsar -Raw -ErrorAction SilentlyContinue
        if ($content -match 'patcher\.js') {
            $result.IsPatched = $true
            $result.Details = 'Vencord-Patch aktiv, app.asar = {0} Bytes, verweist auf patcher.js' -f $result.AppAsarSize
        } else {
            $result.Details = 'app.asar ist klein, {0} Bytes, aber enthält keinen Vencord-Verweis' -f $result.AppAsarSize
        }
    } else {
        $result.Details = 'app.asar ist original, {0} Bytes, ungepatcht' -f $result.AppAsarSize
    }

    return $result
}

function Backup-VencordSettings {
    if (-not (Test-Path $VencordSettingsFile)) {
        Write-Log 'Keine Vencord-Einstellungen zum Sichern gefunden' 'WARN'
        return $null
    }

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFile = Join-Path $BackupDir "settings_backup_$timestamp.json"

    Copy-Item -Path $VencordSettingsFile -Destination $backupFile -Force
    Write-Log "Einstellungen gesichert: $backupFile" 'OK'

    $oldBackups = Get-ChildItem -Path $BackupDir -Filter 'settings_backup_*.json' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10
    foreach ($old in $oldBackups) {
        Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
    }

    return $backupFile
}

function Stop-DiscordProcesses {
    $stopped = $false
    foreach ($variant in $DiscordVariants) {
        $procs = Get-Process -Name $variant.ProcessName -ErrorAction SilentlyContinue
        if ($procs) {
            $cnt = $procs.Count
            Write-Log "$($variant.Name) wird geschlossen, $cnt Prozesse..."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $stopped = $true
        }
    }
    if ($stopped) {
        Write-Log 'Warte 3 Sekunden bis Discord vollständig geschlossen ist...'
        Start-Sleep -Seconds 3
    }
    return $stopped
}

function Get-VencordInstaller {
    if (Test-Path $TempInstallerPath) {
        $age = (Get-Date) - (Get-Item $TempInstallerPath).LastWriteTime
        if ($age.TotalDays -lt 7) {
            $sz = (Get-Item $TempInstallerPath).Length
            $days = [int]$age.TotalDays
            Write-Log "Verwende vorhandenen Installer, $sz Bytes, $days Tage alt"
            return $TempInstallerPath
        }
        Remove-Item $TempInstallerPath -Force
    }

    Write-Log "Lade Vencord Installer herunter: $InstallerUrl"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($InstallerUrl, $TempInstallerPath)
        $webClient.Dispose()
    } catch {
        Write-Log "Download fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        return $null
    }

    if (-not (Test-Path $TempInstallerPath)) {
        Write-Log 'Installer-Datei nicht vorhanden nach Download' 'ERROR'
        return $null
    }

    $sz = (Get-Item $TempInstallerPath).Length
    Write-Log "Installer heruntergeladen, $sz Bytes" 'OK'
    return $TempInstallerPath
}

function Invoke-VencordInstall {
    param(
        [string]$InstallerPath,
        [string]$DiscordDir
    )

    Write-Log "Installiere Vencord für: $DiscordDir"

    $proc = Start-Process -FilePath $InstallerPath -ArgumentList '--install', '--location', "`"$DiscordDir`"" `
        -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    if ($proc -and $proc.ExitCode -eq 0) {
        Write-Log 'Installation mit --location erfolgreich' 'OK'
        return $true
    }

    Write-Log 'Installation mit --location fehlgeschlagen, versuche --branch auto' 'WARN'
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList '--install', '--branch', 'auto' `
        -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    if ($proc -and $proc.ExitCode -eq 0) {
        Write-Log 'Installation mit --branch auto erfolgreich' 'OK'
        return $true
    }

    $exitCode = if ($proc) { $proc.ExitCode } else { 'unbekannt' }
    Write-Log "Installation fehlgeschlagen, Exit-Code: $exitCode" 'ERROR'
    return $false
}

# ============================================================
# Hauptaktionen
# ============================================================

function Invoke-Check {
    Write-Host ''
    Write-Host '  Vencord-Status prüfen...' -ForegroundColor White
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray

    $anyFound = $false
    $allPatched = $true

    foreach ($variant in $DiscordVariants) {
        $appDir = Get-LatestAppDir -DiscordLocalDir $variant.LocalDir
        if (-not $appDir) { continue }

        $anyFound = $true
        $check = Test-VencordPatched -AppDir $appDir
        $versionName = Split-Path $appDir -Leaf

        if ($check.IsPatched) {
            Write-Log "$($variant.Name) - $versionName : $($check.Details)" 'OK'
        } else {
            Write-Log "$($variant.Name) - $versionName : $($check.Details)" 'WARN'
            $allPatched = $false
        }
    }

    if (-not $anyFound) {
        Write-Log 'Keine Discord-Installation gefunden' 'WARN'
        return $false
    }

    $patcherPath = Join-Path $VencordDistDir 'patcher.js'
    if (Test-Path $patcherPath) {
        Write-Log "Vencord-Dist vorhanden: $VencordDistDir" 'OK'
    } else {
        Write-Log "Vencord-Dist FEHLT: $VencordDistDir" 'ERROR'
        $allPatched = $false
    }

    if (Test-Path $VencordSettingsFile) {
        $sz = (Get-Item $VencordSettingsFile).Length
        Write-Log "Einstellungen vorhanden, $sz Bytes: $VencordSettingsFile" 'OK'
    } else {
        Write-Log 'Keine Vencord-Einstellungen gefunden' 'INFO'
    }

    return $allPatched
}

function Invoke-Repair {
    Write-Host ''
    Write-Host '  Vencord-Reparatur starten...' -ForegroundColor White
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray

    $needsRepair = $false
    $variantsToRepair = @()

    foreach ($variant in $DiscordVariants) {
        $appDir = Get-LatestAppDir -DiscordLocalDir $variant.LocalDir
        if (-not $appDir) { continue }

        $check = Test-VencordPatched -AppDir $appDir
        if (-not $check.IsPatched) {
            $needsRepair = $true
            $variantsToRepair += @{ Variant = $variant; AppDir = $appDir; Check = $check }
            Write-Log "$($variant.Name): Reparatur nötig - $($check.Details)" 'WARN'
        } else {
            Write-Log "$($variant.Name): Patch intakt - $($check.Details)" 'OK'
        }
    }

    if (-not $needsRepair) {
        Write-Log 'Alle Discord-Installationen sind korrekt gepatcht. Keine Reparatur nötig.' 'OK'
        return $true
    }

    Backup-VencordSettings

    $installerPath = Get-VencordInstaller
    if (-not $installerPath) {
        Write-Log 'Kann Installer nicht herunterladen. Reparatur abgebrochen.' 'ERROR'
        return $false
    }

    $wasRunning = Stop-DiscordProcesses

    $allSuccess = $true
    foreach ($item in $variantsToRepair) {
        $success = Invoke-VencordInstall -InstallerPath $installerPath -DiscordDir $item.Variant.LocalDir
        if (-not $success) { $allSuccess = $false }
    }

    Write-Host ''
    Write-Host '  Verifizierung...' -ForegroundColor White
    foreach ($item in $variantsToRepair) {
        $appDir = Get-LatestAppDir -DiscordLocalDir $item.Variant.LocalDir
        if ($appDir) {
            $verify = Test-VencordPatched -AppDir $appDir
            if ($verify.IsPatched) {
                Write-Log "$($item.Variant.Name): Reparatur erfolgreich - $($verify.Details)" 'OK'
            } else {
                Write-Log "$($item.Variant.Name): Reparatur möglicherweise fehlgeschlagen - $($verify.Details)" 'ERROR'
                $allSuccess = $false
            }
        }
    }

    if ($wasRunning) {
        $mainDiscord = Join-Path $env:LOCALAPPDATA 'Discord\Update.exe'
        if (Test-Path $mainDiscord) {
            Start-Process -FilePath $mainDiscord -ArgumentList '--processStart', 'Discord.exe'
            Write-Log 'Discord wird neu gestartet' 'OK'
        }
    }

    return $allSuccess
}

function Invoke-Uninstall {
    Write-Host ''
    Write-Host '  Vencord deinstallieren...' -ForegroundColor White
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray

    Backup-VencordSettings

    $wasRunning = Stop-DiscordProcesses

    foreach ($variant in $DiscordVariants) {
        $appDir = Get-LatestAppDir -DiscordLocalDir $variant.LocalDir
        if (-not $appDir) { continue }

        $check = Test-VencordPatched -AppDir $appDir
        if (-not $check.IsPatched -and -not $check.HasBackup) {
            Write-Log "$($variant.Name): Kein Vencord-Patch vorhanden, überspringe" 'INFO'
            continue
        }

        if ($check.HasBackup) {
            Remove-Item $check.AppAsar -Force -ErrorAction SilentlyContinue
            Rename-Item $check.BackupAsar -NewName 'app.asar' -Force
            Write-Log "$($variant.Name): Original app.asar wiederhergestellt" 'OK'
        } else {
            Write-Log "$($variant.Name): Kein Backup vorhanden, kann Original nicht wiederherstellen" 'ERROR'
            Write-Log "$($variant.Name): Discord muss möglicherweise neu installiert werden" 'WARN'
        }

        $appPatchDir = Join-Path $appDir 'resources\app'
        if (Test-Path $appPatchDir) {
            Remove-Item $appPatchDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "$($variant.Name): Patch-Ordner entfernt" 'OK'
        }
    }

    Write-Host ''
    Write-Log 'Vencord-Patches entfernt. Einstellungen bleiben erhalten.' 'OK'
    Write-Log "  Einstellungen: $VencordSettingsDir" 'INFO'
    Write-Log "  Backup: $BackupDir" 'INFO'

    if ($wasRunning) {
        $mainDiscord = Join-Path $env:LOCALAPPDATA 'Discord\Update.exe'
        if (Test-Path $mainDiscord) {
            Start-Process -FilePath $mainDiscord -ArgumentList '--processStart', 'Discord.exe'
            Write-Log 'Discord neu gestartet' 'OK'
        }
    }
}

function Invoke-Status {
    Write-Host ''
    Write-Host '  Vencord-Systemstatus' -ForegroundColor White
    Write-Host "  $('=' * 50)" -ForegroundColor DarkGray

    # Discord-Varianten
    Write-Host ''
    Write-Host '  Discord-Installationen:' -ForegroundColor White
    foreach ($variant in $DiscordVariants) {
        if (-not (Test-Path $variant.LocalDir)) {
            Write-Host "    $($variant.Name): nicht installiert" -ForegroundColor DarkGray
            continue
        }

        $appDir = Get-LatestAppDir -DiscordLocalDir $variant.LocalDir
        if (-not $appDir) {
            Write-Host "    $($variant.Name): kein app-* Verzeichnis gefunden" -ForegroundColor Yellow
            continue
        }

        $versionName = Split-Path $appDir -Leaf
        $check = Test-VencordPatched -AppDir $appDir

        $statusColor = if ($check.IsPatched) { 'Green' } else { 'Yellow' }
        $statusText = if ($check.IsPatched) { 'GEPATCHT' } else { 'UNGEPATCHT' }

        Write-Host "    $($variant.Name) - $versionName : " -NoNewline
        Write-Host "[$statusText]" -ForegroundColor $statusColor
        Write-Host "      app.asar: $($check.AppAsarSize) Bytes" -ForegroundColor DarkGray
        $backupText = if ($check.HasBackup) { 'vorhanden' } else { 'nicht vorhanden' }
        Write-Host "      _app.asar Backup: $backupText" -ForegroundColor DarkGray
        Write-Host "      Pfad: $appDir" -ForegroundColor DarkGray
    }

    # Vencord-Dateien
    Write-Host ''
    Write-Host '  Vencord-Dateien:' -ForegroundColor White
    $patcherPath = Join-Path $VencordDistDir 'patcher.js'
    if (Test-Path $patcherPath) {
        $patcherInfo = Get-Item $patcherPath
        $pLen = $patcherInfo.Length
        $pTime = $patcherInfo.LastWriteTime
        Write-Host "    patcher.js: vorhanden, $pLen Bytes, $pTime" -ForegroundColor Green
    } else {
        Write-Host '    patcher.js: FEHLT' -ForegroundColor Red
    }

    if (Test-Path $VencordSettingsFile) {
        $settingsInfo = Get-Item $VencordSettingsFile
        $sLen = $settingsInfo.Length
        Write-Host "    settings.json: vorhanden, $sLen Bytes" -ForegroundColor Green
    } else {
        Write-Host '    settings.json: nicht vorhanden' -ForegroundColor Yellow
    }

    # Backups
    Write-Host ''
    Write-Host '  Backups:' -ForegroundColor White
    if (Test-Path $BackupDir) {
        $backups = Get-ChildItem $BackupDir -Filter 'settings_backup_*.json' -ErrorAction SilentlyContinue
        $bCount = 0
        if ($backups) { $bCount = @($backups).Count }
        Write-Host "    $bCount Einstellungs-Backups unter: $BackupDir" -ForegroundColor DarkGray
    } else {
        Write-Host '    Keine Backups vorhanden' -ForegroundColor DarkGray
    }

    # Log
    Write-Host ''
    Write-Host '  Log-Datei:' -ForegroundColor White
    Write-Host "    $LogFile" -ForegroundColor DarkGray
}

# ============================================================
# Hauptprogramm
# ============================================================

Write-Host ''
Write-Host '  +================================================+' -ForegroundColor Cyan
Write-Host '  |          VencordRepair v1.0                     |' -ForegroundColor Cyan
Write-Host '  |  Repariert Vencord nach Discord-Updates         |' -ForegroundColor Cyan
Write-Host '  +================================================+' -ForegroundColor Cyan

Write-Log "VencordRepair gestartet, Aktion: $Action"

switch ($Action) {
    'Check' {
        $result = Invoke-Check
        Write-Host ''
        if ($result) {
            Write-Host '  Ergebnis: Vencord ist vollständig installiert.' -ForegroundColor Green
        } else {
            Write-Host '  Ergebnis: Vencord-Reparatur empfohlen. Führe aus:' -ForegroundColor Yellow
            Write-Host '    .\VencordRepair.ps1 -Action Repair' -ForegroundColor White
        }
    }
    'Repair' {
        $result = Invoke-Repair
        Write-Host ''
        if ($result) {
            Write-Host '  Reparatur abgeschlossen.' -ForegroundColor Green
        } else {
            Write-Host '  Reparatur mit Fehlern abgeschlossen. Siehe Log:' -ForegroundColor Yellow
            Write-Host "    $LogFile" -ForegroundColor White
        }
    }
    'Uninstall' {
        Invoke-Uninstall
    }
    'Status' {
        Invoke-Status
    }
}

Write-Host ''
Write-Log "VencordRepair beendet, Aktion: $Action"

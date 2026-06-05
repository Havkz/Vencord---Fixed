@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

:: ============================================================
:: VencordAutoInstaller.bat
:: Lädt Vencord CLI Installer herunter, installiert Vencord,
:: trägt sich in den Autostart ein und prüft bei jedem Start
:: ob Vencord noch in Discord injiziert ist.
:: Wenn nicht, wird es automatisch im Hintergrund neu installiert.
:: Läuft komplett unsichtbar im Hintergrund.
:: ============================================================

:: --- Modus erkennen ---
:: /silent = Autostart (kein Output, kein Log)
:: Ohne Parameter = Manueller Erststart (mit Ausgaben)
if /I "%~1"=="/silent" set "SILENT=1"

:: --- Konfiguration ---
:: Installationsverzeichnis (im lokalen AppData des Benutzers)
set "INSTALL_DIR=%LOCALAPPDATA%\VencordAutoInstaller"
set "INSTALL_SCRIPT=%INSTALL_DIR%\VencordAutoInstaller.bat"
set "INSTALLER_EXE=%INSTALL_DIR%\VencordInstallerCli.exe"
set "VBS_LAUNCHER=%INSTALL_DIR%\VencordSilentLauncher.vbs"
set "DOWNLOAD_URL=https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe"
set "AUTOSTART_NAME=VencordAutoInstaller"
set "SCRIPT_PATH=%~f0"
set "LOG_FILE=%INSTALL_DIR%\vencord_installer.log"
set "AUTOSTART_CMD=PowerShell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command ""& '%INSTALL_SCRIPT%' /silent"""
:: Discord-Installationsverzeichnisse (Standard-Pfade)
set "DISCORD_LOCAL=%LOCALAPPDATA%\Discord"
set "DISCORD_PTB_LOCAL=%LOCALAPPDATA%\DiscordPTB"
set "DISCORD_CANARY_LOCAL=%LOCALAPPDATA%\DiscordCanary"
set "PATCHED_ASAR_MAX_SIZE=50000"

:: --- Installationsverzeichnis erstellen ---
if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
    if errorlevel 1 exit /b 1
)

:: Script in stabiles Installationsverzeichnis kopieren (für zuverlässigen Autostart)
if /I not "%SCRIPT_PATH%"=="%INSTALL_SCRIPT%" (
    copy /Y "%SCRIPT_PATH%" "%INSTALL_SCRIPT%" >nul 2>&1
    if errorlevel 1 (
        call :Output "[FEHLER] Konnte Script nicht nach %INSTALL_SCRIPT% kopieren."
        exit /b 1
    )
)

:: Alte VBS-Datei aufräumen (VBS wird nicht mehr verwendet)
if exist "%VBS_LAUNCHER%" del /f /q "%VBS_LAUNCHER%" >nul 2>&1

call :Log "VencordAutoInstaller gestartet"

:: --- Autostart-Eintrag prüfen und setzen ---
call :SetupAutostart

:: --- Prüfen ob Vencord Installer-Exe vorhanden ist ---
call :CheckAndDownloadInstaller

:: --- Prüfen ob Vencord in Discord injiziert ist ---
call :CheckVencordInjection
if "!VENCORD_INSTALLED!"=="0" (
    call :Log "Vencord ist NICHT in Discord injiziert. Starte Neuinstallation..."
    call :Output "[INFO] Vencord nicht in Discord gefunden. Installiere neu..."
    call :InstallVencord
) else (
    call :Log "Vencord ist in Discord injiziert. Keine Aktion nötig."
    call :Output "[OK] Vencord ist installiert und aktiv."
)

call :Log "VencordAutoInstaller abgeschlossen"
call :Output ""
call :Output "============================================"
call :Output " Vencord Prüfung abgeschlossen"
call :Output "============================================"
if not defined SILENT timeout /t 5 /nobreak >nul
exit /b 0


:: ============================================================
:: FUNKTIONEN
:: ============================================================

:: --- Logging-Funktion (nur beim manuellen Start) ---
:Log
    if not defined SILENT echo [%date% %time%] %~1 >> "%LOG_FILE%"
    goto :eof

:: --- Ausgabe nur beim manuellen Start ---
:Output
    if not defined SILENT echo %~1
    goto :eof

:: --- Autostart einrichten (ohne VBS, via verstecktem PowerShell-Start) ---
:SetupAutostart
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "%AUTOSTART_NAME%" /t REG_SZ /d "%AUTOSTART_CMD%" /f >nul 2>&1
    if errorlevel 1 (
        call :Log "FEHLER: Autostart-Eintrag fehlgeschlagen"
        call :Output "[FEHLER] Konnte Autostart-Eintrag nicht setzen."
    ) else (
        call :Log "Autostart-Eintrag gesetzt/aktualisiert"
        call :Output "[OK] Autostart-Eintrag gesetzt/aktualisiert."
    )
    goto :eof

:: --- Installer-Exe prüfen und ggf. herunterladen ---
:CheckAndDownloadInstaller
    if exist "%INSTALLER_EXE%" (
        call :Log "Installer vorhanden"
        call :Output "[OK] Vencord Installer gefunden."
    ) else (
        call :Log "Installer nicht gefunden, starte Download"
        call :DownloadInstaller
    )
    goto :eof

:: --- Download-Funktion ---
:DownloadInstaller
    where curl >nul 2>&1
    if not errorlevel 1 (
        if defined SILENT (
            curl -L -s -o "%INSTALLER_EXE%" "%DOWNLOAD_URL%"
        ) else (
            curl -L -# -o "%INSTALLER_EXE%" "%DOWNLOAD_URL%"
        )
        if exist "%INSTALLER_EXE%" (
            call :Log "Download via curl erfolgreich"
            goto :eof
        )
    )
    PowerShell -NoProfile -ExecutionPolicy Bypass -Command ^
        "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%INSTALLER_EXE%' -UseBasicParsing" >nul 2>&1
    if exist "%INSTALLER_EXE%" (
        call :Log "Download via PowerShell erfolgreich"
    ) else (
        call :Log "FEHLER: Download fehlgeschlagen"
    )
    goto :eof

:: --- Prüfen ob Vencord tatsächlich in Discord injiziert ist ---
:: Prüft jedes Discord-Verzeichnis einzeln auf Vencord-Dateien
:CheckVencordInjection
    set "VENCORD_INSTALLED=0"
    call :CheckSingleDiscordDir "%DISCORD_LOCAL%"
    if "!VENCORD_INSTALLED!"=="1" goto :eof
    call :CheckSingleDiscordDir "%DISCORD_PTB_LOCAL%"
    if "!VENCORD_INSTALLED!"=="1" goto :eof
    call :CheckSingleDiscordDir "%DISCORD_CANARY_LOCAL%"
    goto :eof

:: --- Einzelnes Discord-Verzeichnis auf Vencord-Injektion prüfen ---
:CheckSingleDiscordDir
    set "CHECK_DIR=%~1"
    if not exist "%CHECK_DIR%" goto :eof

    :: Finde das neueste app-* Verzeichnis
    set "LATEST_APP="
    for /f "delims=" %%A in ('dir /b /ad /o-n "%CHECK_DIR%\app-*" 2^>nul') do (
        if not defined LATEST_APP set "LATEST_APP=%%A"
    )
    if not defined LATEST_APP goto :eof

    set "APP_DIR=%CHECK_DIR%\!LATEST_APP!"

    :: Methode 1: Prüfe ob _app.asar (Backup) existiert
    :: Hinweis: Backup allein ist KEIN sicherer Indikator (kann nach Deinstallation übrig bleiben)
    if exist "!APP_DIR!\resources\_app.asar" (
        call :Log "Hinweis: _app.asar gefunden in !APP_DIR! (allein kein Installationsbeweis)"
    )

    :: Methode 2: Prüfe ob app.asar gepatchte Version ist (deutlich kleiner)
    if exist "!APP_DIR!\resources\app.asar" (
        for %%F in ("!APP_DIR!\resources\app.asar") do (
            if %%~zF LSS %PATCHED_ASAR_MAX_SIZE% (
                set "VENCORD_INSTALLED=1"
                call :Log "Vencord (gepatchte app.asar) gefunden in: !APP_DIR!"
            )
        )
    )

    :: Methode 3: Prüfe ob ein app-Ordner mit Vencord-Patcher existiert
    if exist "!APP_DIR!\resources\app\patcher.js" (
        set "VENCORD_INSTALLED=1"
        call :Log "Vencord (patcher.js) gefunden in: !APP_DIR!"
    )
    goto :eof

:: --- Vencord installieren ---
:InstallVencord
    if not exist "%INSTALLER_EXE%" (
        call :Log "FEHLER: Installer fehlt, Installation abgebrochen"
        goto :eof
    )

    :: Prüfe ob Discord (alle Varianten) läuft und schließe es vor der Installation
    tasklist /FI "IMAGENAME eq Discord.exe" 2>nul | find /I "Discord.exe" >nul
    if not errorlevel 1 (
        call :Log "Discord läuft, schließe es"
        taskkill /IM Discord.exe /F >nul 2>&1
    )
    tasklist /FI "IMAGENAME eq DiscordPTB.exe" 2>nul | find /I "DiscordPTB.exe" >nul
    if not errorlevel 1 (
        call :Log "DiscordPTB läuft, schließe es"
        taskkill /IM DiscordPTB.exe /F >nul 2>&1
    )
    tasklist /FI "IMAGENAME eq DiscordCanary.exe" 2>nul | find /I "DiscordCanary.exe" >nul
    if not errorlevel 1 (
        call :Log "DiscordCanary läuft, schließe es"
        taskkill /IM DiscordCanary.exe /F >nul 2>&1
    )
    timeout /t 3 /nobreak >nul

    :: Vencord via CLI Installer installieren
    :: Versuche jede erkannte Discord-Installation einzeln mit explizitem Pfad
    set "INSTALL_SUCCESS=0"

    if exist "%DISCORD_LOCAL%" (
        call :InstallForPath "%DISCORD_LOCAL%"
    )
    if exist "%DISCORD_PTB_LOCAL%" (
        call :InstallForPath "%DISCORD_PTB_LOCAL%"
    )
    if exist "%DISCORD_CANARY_LOCAL%" (
        call :InstallForPath "%DISCORD_CANARY_LOCAL%"
    )

    if "!INSTALL_SUCCESS!"=="0" (
        call :Log "Kein Discord-Pfad, versuche Fallback mit --branch auto"
        call :Output "[INFO] Versuche mit --branch auto..."
        "%INSTALLER_EXE%" --install --branch auto >nul 2>&1
        if errorlevel 1 (
            "%INSTALLER_EXE%" --install --branch stable >nul 2>&1
        )
    )

    :: Ergebnis prüfen
    call :CheckVencordInjection
    if "!VENCORD_INSTALLED!"=="1" (
        call :Log "Vencord erfolgreich installiert"
        call :Output "[OK] Vencord erfolgreich installiert."
    ) else (
        call :Log "WARNUNG: Vencord Installation möglicherweise fehlgeschlagen"
        call :Output "[FEHLER] Vencord Installation möglicherweise fehlgeschlagen."
    )
    goto :eof

:: --- Vencord für einen bestimmten Discord-Pfad installieren ---
:InstallForPath
    set "TARGET_PATH=%~1"
    call :Log "Starte Vencord CLI Installation für: %TARGET_PATH%"

    :: --location und --branch sind gegenseitig ausschließend, daher nur --location
    "%INSTALLER_EXE%" --install --location "%TARGET_PATH%" >nul 2>&1
    if not errorlevel 1 (
        set "INSTALL_SUCCESS=1"
        call :Log "Installation erfolgreich für: %TARGET_PATH%"
        goto :eof
    )

    call :Log "Installation mit --location fehlgeschlagen für: %TARGET_PATH%"
    goto :eof

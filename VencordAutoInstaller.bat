@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: VencordAutoInstaller.bat
:: Laedt Vencord CLI Installer herunter, installiert Vencord,
:: traegt sich in den Autostart ein und prueft bei jedem Start
:: ob Vencord noch in Discord injiziert ist.
:: Wenn nicht, wird es automatisch im Hintergrund neu installiert.
:: ============================================================

:: --- Hintergrund-Modus ---
:: Wenn mit Parameter /silent aufgerufen, laeuft es komplett unsichtbar
:: Beim ersten manuellen Start wird nur der Autostart eingerichtet
if /I "%~1"=="/silent" goto :SilentMode

:: --- Manueller Start: Normaler Modus mit Konsolenausgabe ---
goto :MainStart

:SilentMode
:: Im Silent-Modus keine Konsolenausgabe, nur Logging
set "SILENT=1"
goto :MainStart

:MainStart

:: --- Konfiguration ---
:: Installationsverzeichnis (im lokalen AppData des Benutzers)
set "INSTALL_DIR=%LOCALAPPDATA%\VencordAutoInstaller"
set "INSTALLER_EXE=%INSTALL_DIR%\VencordInstallerCli.exe"
set "VBS_LAUNCHER=%INSTALL_DIR%\VencordSilentLauncher.vbs"
set "DOWNLOAD_URL=https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe"
set "AUTOSTART_NAME=VencordAutoInstaller"
set "SCRIPT_PATH=%~f0"
set "LOG_FILE=%INSTALL_DIR%\vencord_installer.log"
:: Discord-Installationsverzeichnisse (Standard-Pfade)
set "DISCORD_LOCAL=%LOCALAPPDATA%\Discord"
set "DISCORD_PTB_LOCAL=%LOCALAPPDATA%\DiscordPTB"
set "DISCORD_CANARY_LOCAL=%LOCALAPPDATA%\DiscordCanary"

:: --- Installationsverzeichnis erstellen ---
if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
    if errorlevel 1 (
        call :Log "FEHLER: Konnte Installationsverzeichnis nicht erstellen"
        exit /b 1
    )
)

call :Log "VencordAutoInstaller gestartet (Modus: %~1)"

:: --- VBS-Launcher fuer Hintergrund-Autostart erstellen ---
call :CreateVBSLauncher

:: --- Autostart-Eintrag pruefen und setzen (nutzt VBS fuer unsichtbaren Start) ---
call :SetupAutostart

:: --- Pruefen ob Vencord Installer-Exe vorhanden ist ---
call :CheckAndDownloadInstaller

:: --- Pruefen ob Vencord in Discord injiziert ist ---
call :CheckVencordInjection
if "!VENCORD_INSTALLED!"=="0" (
    call :Log "Vencord ist NICHT in Discord injiziert. Starte Neuinstallation..."
    call :Output "[INFO] Vencord nicht in Discord gefunden. Installiere neu..."
    call :InstallVencord
) else (
    call :Log "Vencord ist in Discord injiziert. Keine Aktion noetig."
    call :Output "[OK] Vencord ist installiert und aktiv."
)

call :Log "VencordAutoInstaller abgeschlossen"
if not defined SILENT (
    echo.
    echo ============================================
    echo  Vencord Pruefung abgeschlossen
    echo ============================================
    timeout /t 5 /nobreak >nul
)
exit /b 0


:: ============================================================
:: FUNKTIONEN
:: ============================================================

:: --- Logging-Funktion ---
:Log
    echo [%date% %time%] %~1 >> "%LOG_FILE%"
    goto :eof

:: --- Ausgabe nur im nicht-silent Modus ---
:Output
    if not defined SILENT echo %~1
    goto :eof

:: --- VBS-Launcher erstellen (startet BAT unsichtbar im Hintergrund) ---
:CreateVBSLauncher
    :: Erstelle VBS-Datei die das BAT-Script unsichtbar startet
    if not exist "%VBS_LAUNCHER%" (
        (
            echo Set WshShell = CreateObject^("WScript.Shell"^)
            echo WshShell.Run chr^(34^) ^& "%SCRIPT_PATH%" ^& chr^(34^) ^& " /silent", 0, False
        ) > "%VBS_LAUNCHER%"
        call :Log "VBS-Launcher erstellt: %VBS_LAUNCHER%"
    )
    goto :eof

:: --- Autostart einrichten (via VBS fuer unsichtbaren Start) ---
:SetupAutostart
    reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "%AUTOSTART_NAME%" >nul 2>&1
    if errorlevel 1 (
        call :Output "[INFO] Trage Script in den Autostart ein..."
        reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "%AUTOSTART_NAME%" /t REG_SZ /d "\"%VBS_LAUNCHER%\"" /f >nul 2>&1
        if errorlevel 1 (
            call :Log "FEHLER: Autostart-Eintrag fehlgeschlagen"
            call :Output "[FEHLER] Konnte Autostart-Eintrag nicht setzen."
        ) else (
            call :Log "Autostart-Eintrag gesetzt (via VBS-Launcher)"
            call :Output "[OK] Autostart-Eintrag gesetzt (laeuft unsichtbar im Hintergrund)."
        )
    ) else (
        call :Output "[OK] Autostart-Eintrag bereits vorhanden."
    )
    goto :eof

:: --- Installer-Exe pruefen und ggf. herunterladen ---
:CheckAndDownloadInstaller
    if exist "%INSTALLER_EXE%" (
        call :Output "[OK] Vencord Installer gefunden."
        call :Log "Installer vorhanden"
    ) else (
        call :Output "[INFO] Vencord Installer nicht gefunden. Lade herunter..."
        call :Log "Installer nicht gefunden, starte Download"
        call :DownloadInstaller
    )
    goto :eof

:: --- Download-Funktion ---
:DownloadInstaller
    where curl >nul 2>&1
    if not errorlevel 1 (
        call :Output "[INFO] Verwende curl zum Download..."
        curl -L -s -o "%INSTALLER_EXE%" "%DOWNLOAD_URL%"
        if exist "%INSTALLER_EXE%" (
            call :Output "[OK] Download erfolgreich."
            call :Log "Download via curl erfolgreich"
            goto :eof
        )
    )
    call :Output "[INFO] Verwende PowerShell zum Download..."
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%INSTALLER_EXE%' -UseBasicParsing" >nul 2>&1
    if exist "%INSTALLER_EXE%" (
        call :Output "[OK] Download via PowerShell erfolgreich."
        call :Log "Download via PowerShell erfolgreich"
    ) else (
        call :Output "[FEHLER] Download fehlgeschlagen."
        call :Log "FEHLER: Download fehlgeschlagen"
    )
    goto :eof

:: --- Pruefen ob Vencord tatsaechlich in Discord injiziert ist ---
:: Prueft jedes Discord-Verzeichnis einzeln auf Vencord-Dateien
:CheckVencordInjection
    set "VENCORD_INSTALLED=0"
    call :CheckSingleDiscordDir "%DISCORD_LOCAL%"
    if "!VENCORD_INSTALLED!"=="1" goto :eof
    call :CheckSingleDiscordDir "%DISCORD_PTB_LOCAL%"
    if "!VENCORD_INSTALLED!"=="1" goto :eof
    call :CheckSingleDiscordDir "%DISCORD_CANARY_LOCAL%"
    goto :eof

:: --- Einzelnes Discord-Verzeichnis auf Vencord-Injektion pruefen ---
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

    :: Methode 1: Pruefe ob _app.asar (Backup) existiert
    :: Das ist der zuverlaessigste Indikator dass Vencord injiziert ist
    if exist "!APP_DIR!\resources\_app.asar" (
        set "VENCORD_INSTALLED=1"
        call :Log "Vencord gefunden in: !APP_DIR! (_app.asar Backup vorhanden)"
        call :Output "[OK] Vencord gefunden in: !APP_DIR!"
        goto :eof
    )

    :: Methode 2: Pruefe ob app.asar gepatchte Version ist (deutlich kleiner)
    if exist "!APP_DIR!\resources\app.asar" (
        for %%F in ("!APP_DIR!\resources\app.asar") do (
            if %%~zF LSS 50000 (
                set "VENCORD_INSTALLED=1"
                call :Log "Vencord (gepatchte app.asar) gefunden in: !APP_DIR!"
                call :Output "[OK] Vencord (gepatchte app.asar) gefunden in: !APP_DIR!"
            )
        )
    )

    :: Methode 3: Pruefe ob ein app-Ordner mit Vencord-Patcher existiert
    if exist "!APP_DIR!\resources\app\patcher.js" (
        set "VENCORD_INSTALLED=1"
        call :Log "Vencord (patcher.js) gefunden in: !APP_DIR!"
        call :Output "[OK] Vencord (patcher.js) gefunden in: !APP_DIR!"
    )
    goto :eof

:: --- Vencord installieren ---
:InstallVencord
    if not exist "%INSTALLER_EXE%" (
        call :Log "FEHLER: Installer fehlt, Installation abgebrochen"
        call :Output "[FEHLER] Installer nicht vorhanden."
        goto :eof
    )

    :: Pruefe ob Discord laeuft
    tasklist /FI "IMAGENAME eq Discord.exe" 2>nul | find /I "Discord.exe" >nul
    if not errorlevel 1 (
        call :Output "[INFO] Discord laeuft. Schliesse Discord..."
        call :Log "Discord laeuft, schliesse es"
        taskkill /IM Discord.exe /F >nul 2>&1
        timeout /t 3 /nobreak >nul
    )

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
        call :Output "[INFO] Kein Discord-Pfad gefunden. Versuche mit --branch auto..."
        call :Log "Kein Discord-Pfad, versuche Fallback mit --branch auto"
        call :Output "[INFO] Starte Vencord Installation (Fallback)..."
        "%INSTALLER_EXE%" --install --branch auto
        if errorlevel 1 (
            "%INSTALLER_EXE%" --install --branch stable
        )
    )

    :: Ergebnis pruefen
    call :CheckVencordInjection
    if "!VENCORD_INSTALLED!"=="1" (
        call :Output "[OK] Vencord erfolgreich installiert."
        call :Log "Vencord erfolgreich installiert"
    ) else (
        call :Output "[FEHLER] Vencord Installation moeglicherweise fehlgeschlagen."
        call :Log "WARNUNG: Vencord Installation moeglicherweise fehlgeschlagen"
    )
    goto :eof

:: --- Vencord fuer einen bestimmten Discord-Pfad installieren ---
:InstallForPath
    set "TARGET_PATH=%~1"
    call :Output "[INFO] Starte Vencord Installation fuer: %TARGET_PATH%"
    call :Log "Starte Vencord CLI Installation fuer: %TARGET_PATH%"

    :: --location und --branch sind gegenseitig ausschliessend, daher nur --location
    "%INSTALLER_EXE%" --install --location "%TARGET_PATH%"
    if not errorlevel 1 (
        set "INSTALL_SUCCESS=1"
        call :Log "Installation erfolgreich fuer: %TARGET_PATH%"
        goto :eof
    )

    call :Log "Installation mit --location fehlgeschlagen fuer: %TARGET_PATH%"
    goto :eof

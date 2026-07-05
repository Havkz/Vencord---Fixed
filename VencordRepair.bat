@echo off
chcp 65001 >nul
title VencordRepair

if "%~1"=="" (
    echo.
    echo   VencordRepair - Verwendung:
    echo.
    echo     VencordRepair.bat               Reparatur durchführen
    echo     VencordRepair.bat Check          Nur prüfen
    echo     VencordRepair.bat Install        Autostart einrichten
    echo     VencordRepair.bat Status         Systemstatus anzeigen
    echo     VencordRepair.bat Uninstall      Autostart entfernen
    echo     VencordRepair.bat Restore        Letztes Backup wiederherstellen
    echo.
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VencordRepair.ps1" -Action Repair
) else (
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VencordRepair.ps1" -Action %~1
)
echo.
pause
exit /b 0

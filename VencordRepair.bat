@echo off
chcp 65001 >nul
title VencordRepair
echo.
echo   Starte VencordRepair...
echo.
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VencordRepair.ps1" %*
echo.
pause

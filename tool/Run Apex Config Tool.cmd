@echo off
rem Starts the Apex Config Tool window. Close Apex Legends before applying.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Apex-Config-Tool.ps1" %*
if errorlevel 1 pause

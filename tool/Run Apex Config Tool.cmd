@echo off
:: Starts the Apex Config Tool without changing your PowerShell execution policy
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Apex-Config-Tool.ps1"

@echo off
rem Starts the AirFeed test rig without changing the PowerShell script policy for the machine.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0airfeed.ps1" %*
pause

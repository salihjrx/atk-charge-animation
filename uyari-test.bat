@echo off
rem Dusuk pil uyari balonunu hemen bir kez gosterir / Shows the low battery warning once
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0atk-sarj.ps1" -TestWarning

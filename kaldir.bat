@echo off
rem Baslangictan kaldirir ve calisan izleyiciyi durdurur
rem Removes the startup shortcut and stops the running watcher
powershell -NoProfile -Command "Remove-Item -LiteralPath ([Environment]::GetFolderPath('Startup') + '\ATK Sarj Animasyonu.lnk') -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('atk-sarj.ps1') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo Kaldirildi. Klasoru artik silebilirsiniz.
echo Removed. You can now delete this folder.
pause

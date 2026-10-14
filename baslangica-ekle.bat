@echo off
rem Windows acilisinda otomatik baslamasi icin Baslangic klasorune kisayol ekler ve hemen baslatir
rem Adds a shortcut to the Startup folder and starts the watcher now
set "ATK_DIR=%~dp0"
powershell -NoProfile -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup') + '\ATK Sarj Animasyonu.lnk'); $s.TargetPath = 'wscript.exe'; $s.Arguments = '\"' + $env:ATK_DIR + 'baslat.vbs\"'; $s.WorkingDirectory = $env:ATK_DIR; $s.Save()"
wscript.exe "%~dp0baslat.vbs"
echo Tamam! Arka planda calisiyor ve Windows acilisinda otomatik baslayacak.
echo Done! Running in the background and will start automatically with Windows.
pause

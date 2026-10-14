' ATK sarj animasyonunu (ya da "ayarlar" argumaniyla ayarlar penceresini) konsol penceresi olmadan baslatir
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
script = "atk-sarj.ps1"
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "ayarlar" Then script = "ayarlar.ps1"
End If
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & dir & "\" & script & """", 0, False
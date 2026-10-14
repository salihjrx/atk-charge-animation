' ATK Charge Animation - programi acar (kontrol merkezi). Diger tum dosyalar "app" klasorundedir.
' Opens the program (control center). Everything else lives in the "app" folder.
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "wscript.exe """ & root & "\app\baslat.vbs"" ayarlar", 0, False
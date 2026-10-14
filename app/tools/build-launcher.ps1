<#
  Baslaticiyi derler: app\tools\AtkLauncher.cs -> ..\..\ATK Charge Animation.exe
  Windows'ta hazir gelen .NET Framework C# derleyicisini (csc.exe) kullanir; ek kurulum gerekmez.
  Ayrica app\icon.png'den cok boyutlu app\icon.ico uretir (exe ve masaustu kisayolu simgesi).

    powershell -NoProfile -STA -ExecutionPolicy Bypass -File app\tools\build-launcher.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase
$appDir  = Split-Path $PSScriptRoot -Parent
$rootDir = Split-Path $appDir -Parent
$pngPath = Join-Path $appDir 'icon.png'
$icoPath = Join-Path $appDir 'icon.ico'
$exePath = Join-Path $rootDir 'ATK Charge Animation.exe'

# --- icon.png -> icon.ico (PNG sikistirmali, 16..256 px) ---------------------------------
$source = New-Object Windows.Media.Imaging.BitmapImage
$source.BeginInit(); $source.UriSource = [Uri]$pngPath; $source.CacheOption = 'OnLoad'; $source.EndInit()
$images = foreach ($size in 16, 24, 32, 48, 64, 128, 256) {
    $scale = New-Object Windows.Media.ScaleTransform(($size / $source.PixelWidth), ($size / $source.PixelHeight))
    $scaled = New-Object Windows.Media.Imaging.TransformedBitmap($source, $scale)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($scaled))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms)
    [pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() }
}
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)   # ICONDIR
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {                                                  # ICONDIRENTRY
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$img.Bytes.Length); $w.Write([uint32]$offset)
    $offset += $img.Bytes.Length
}
foreach ($img in $images) { $w.Write($img.Bytes) }
$w.Flush(); [IO.File]::WriteAllBytes($icoPath, $out.ToArray())
"simge: $icoPath ($($images.Count) boyut)"

# --- Derleme ------------------------------------------------------------------------------
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$sma = [PSObject].Assembly.Location   # System.Management.Automation (Windows PowerShell 5.1, GAC)
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    "/win32icon:$icoPath" "/reference:$sma" /reference:System.Windows.Forms.dll `
    "/out:$exePath" (Join-Path $PSScriptRoot 'AtkLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw "derleme basarisiz ($LASTEXITCODE)" }
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
"uygulama: $exePath ($([int]((Get-Item $exePath).Length / 1KB)) KB, $($info.ProductName) $($info.FileVersion))"

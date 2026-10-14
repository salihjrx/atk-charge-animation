<#
  Test paketi / Test suite
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
    -SkipHardware : mouse gerektiren testleri atla / skip tests that need the mouse
    -SkipUI       : ekranda pencere acan testleri atla / skip tests that open windows
#>
param([switch]$SkipHardware, [switch]$SkipUI)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$script:Pass = 0; $script:Fail = 0; $script:Skipped = 0

function Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "  [OK]   $Name" -ForegroundColor Green; $script:Pass++ }
    catch { Write-Host "  [FAIL] $Name`n         $($_.Exception.Message)" -ForegroundColor Red; $script:Fail++ }
}
function Skip([string]$Name, [string]$Why) { Write-Host "  [SKIP] $Name ($Why)" -ForegroundColor DarkYellow; $script:Skipped++ }
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function AssertEq($Actual, $Expected, [string]$Msg) { if ($Actual -ne $Expected) { throw "$Msg (beklenen/expected: '$Expected', gelen/actual: '$Actual')" } }
function Section([string]$Name) { Write-Host "`n== $Name" -ForegroundColor Cyan }

# Ana script'i yalnizca fonksiyon/tip olarak yukle (izleme dongusu calismaz).
# Gercek ayarlar ve log dosyasi kirletilmez: gecici dosyalar kullanilir.
$env:ATK_SETTINGS    = Join-Path $env:TEMP "atk-sarj-test-$PID.json"
$env:ATK_STARTUP_DIR = Join-Path $env:TEMP "atk-sarj-test-startup-$PID"   # gercek Baslangic klasoru yerine
$env:ATK_MUTEX       = "Global\ATK_Charge_Animation_Test_$PID"           # calisan gercek izleyiciden bagimsiz
$env:ATK_TEST        = '1'                                               # kontrol merkezi sisteme dokunmasin
New-Item -ItemType Directory -Force $env:ATK_STARTUP_DIR | Out-Null
. (Join-Path $Root 'atk-sarj.ps1')
$LogPath = Join-Path $env:TEMP "atk-sarj-test-$PID.log"
Set-AppSettings @{}   # varsayilan ayarlar (kullanicinin temasi / dili testleri etkilemesin)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TestNative {
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    // DEV_BROADCAST_DEVICEINTERFACE: size, devicetype, reserved, guid(16), name
    public static IntPtr MakeInterfaceBroadcast(string name, int deviceType) {
        int size = 28 + (name.Length + 1) * 2;
        IntPtr p = Marshal.AllocHGlobal(size);
        for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteInt32(p, 0, size);
        Marshal.WriteInt32(p, 4, deviceType);
        byte[] g = new Guid("A5DCBF10-6530-11D2-901F-00C04FB951ED").ToByteArray();
        Marshal.Copy(g, 0, new IntPtr(p.ToInt64() + 12), 16);
        char[] c = name.ToCharArray();
        Marshal.Copy(c, 0, new IntPtr(p.ToInt64() + 28), c.Length);
        return p;
    }
}
'@

function New-Response([byte[]]$Data) {
    $buf = New-Object byte[] 17
    [Array]::Copy($Data, $buf, [Math]::Min($Data.Length, 17))
    , $buf
}
# Sahte pil okumasi: tamamlanmis Task<AtkBattery> (Level -1 = yanit yok)
function New-FakeRead([int]$Level, [int]$Charge = 1) {
    $tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[AtkBattery]'
    if ($Level -lt 0) { $tcs.SetResult($null) }
    else { $b = New-Object AtkBattery; $b.Level = $Level; $b.Charge = $Charge; $b.VoltageMv = 3900; $tcs.SetResult($b) }
    $tcs.Task
}
function With-Culture([string]$Name, [scriptblock]$Body) {
    $orig = [Threading.Thread]::CurrentThread.CurrentCulture
    [Threading.Thread]::CurrentThread.CurrentCulture = $Name
    try { & $Body } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $orig }
}
$x1u2   = $Devices['vid_373b&pid_11e7']
$dongle = $Devices['vid_373b&pid_11d9']

# =====================================================================
Section 'Statik kontroller / Static checks'

Test 'PowerShell dosyalari hatasiz ayrisiyor' {
    foreach ($f in Get-ChildItem $Root -Recurse -Filter *.ps1) {
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        Assert (-not $errs) "$($f.Name): $errs"
    }
}
Test 'Kod dosyalari ve cihazlar.csv yalnizca ASCII (PS 5.1 BOM''suz dosyayi ANSI okur)' {
    foreach ($n in 'atk-sarj.ps1', 'ayarlar.ps1', 'AtkHid.cs', 'cihazlar.csv') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $n))
        $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
        AssertEq $bad 0 "$n ASCII disi bayt"
    }
}
Test 'Yalnizca harf buyuklugu farkli degisken yok ($T / $t gibi; PowerShell bunlari ayni sayar)' {
    # ayarlar.ps1 atk-sarj.ps1'i ice aktardigi icin ikisi birlikte denetlenir
    $names = foreach ($n in 'atk-sarj.ps1', 'ayarlar.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $n), [ref]$null, [ref]$null)
        $ast.FindAll({ $args[0] -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
            ForEach-Object { $_.VariablePath.UserPath -replace '^(script|global|local|env):', '' }
    }
    $clash = $names | Sort-Object -Unique -CaseSensitive | Group-Object { $_.ToLowerInvariant() } | Where-Object Count -gt 1
    Assert (-not $clash) ("cakisan adlar: " + (($clash | ForEach-Object { $_.Group -join '/' }) -join ', '))
}
Test '-match / -like kullanilmiyor (Turkce I hatasina acik)' {
    $src = foreach ($n in 'atk-sarj.ps1', 'ayarlar.ps1') { Get-Content (Join-Path $Root $n) | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '# .*-match' } }
    $hits = @($src | Where-Object { $_.Contains(' -match ') -or $_.Contains(' -like ') -or $_.Contains(' -imatch ') })
    AssertEq $hits.Count 0 "satirlar: $($hits -join ' || ')"
}
Test 'metinler.json gecerli UTF-8 JSON, Turkce karakterler dogru' {
    AssertEq $Texts.tr.charging ([string][char]0x15E + 'arj oluyor') 'tr metin'
    AssertEq $Texts.tr.theme_gold ('Alt' + [char]0x131 + 'n') 'tr tema adi'
}
Test '.vbs dosyalari CRLF satir sonu kullaniyor (ana klasordeki baslatici dahil)' {
    $files = @(Get-ChildItem $Root -Include *.bat, *.vbs -Recurse) + @(Get-ChildItem (Split-Path $Root -Parent) -Filter *.vbs)
    Assert ($files.Count -ge 2) "vbs dosyasi bulunamadi"
    foreach ($f in $files) {
        $txt = [IO.File]::ReadAllText($f.FullName)
        $lf = ([regex]::Matches($txt, "(?<!`r)`n")).Count
        AssertEq $lf 0 "$($f.Name) yalniz-LF satir"
    }
}
Test 'Ana klasorde yalnizca baslatici, README, LICENSE ve app klasoru var' {
    $top = @(Get-ChildItem (Split-Path $Root -Parent) -Force | Where-Object { $_.Name -notin '.git', '.gitignore', '.gitattributes' } | ForEach-Object Name | Sort-Object)
    AssertEq ($top -join ', ') 'app, ATK Charge Animation.vbs, LICENSE, README.md' 'ana klasor icerigi'
}
Test 'Animasyon XAML: yer tutucular doluyor, adlar mevcut, odak calmaz, en ustte' {
    $text = Expand-Template ([IO.File]::ReadAllText($XamlPath, [Text.Encoding]::UTF8)) @{ A1 = $Theme.A1; A2 = $Theme.A2; A1L = $Theme.A1L }
    Assert (-not $text.Contains('{{')) 'doldurulmamis yer tutucu'
    $w = [Windows.Markup.XamlReader]::Parse($text)
    foreach ($n in 'Root', 'LiquidY', 'PctText', 'StatusText', 'TitleText', 'LiqStop1', 'LiqStop2', 'WaveBBrush', 'Dot') {
        Assert ($null -ne $w.FindName($n)) "XAML'de '$n' yok"
    }
    AssertEq $w.ShowActivated $false 'ShowActivated'; AssertEq $w.Topmost $true 'Topmost'
    $w.Close()
}
Test 'Bildirim XAML: yer tutucular doluyor, adlar mevcut, odak calmaz, en ustte' {
    $text = Expand-Template ([IO.File]::ReadAllText($ToastPath, [Text.Encoding]::UTF8)) @{ BG1 = '112233'; BG2 = '445566'; BORDER = '778899' }
    Assert (-not $text.Contains('{{')) 'doldurulmamis yer tutucu'
    $w = [Windows.Markup.XamlReader]::Parse($text)
    foreach ($n in 'ToastRoot', 'ToastSlide', 'ToastTitle', 'ToastBody', 'ToastDevice', 'ToastBarScale', 'IconLow', 'IconFull') {
        Assert ($null -ne $w.FindName($n)) "XAML'de '$n' yok"
    }
    AssertEq $w.ShowActivated $false 'ShowActivated'; AssertEq $w.Topmost $true 'Topmost'
    $w.Close()
}
Test 'Ayarlar XAML: tum metin anahtarlari metinler.json''da var' {
    $text = [IO.File]::ReadAllText((Join-Path $Root 'ayarlar.xaml'), [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, '\{\{t:(\w+)\}\}')) {
        foreach ($lang in 'tr', 'en') { Assert ($Texts[$lang].ContainsKey($m.Groups[1].Value)) "$lang`: '$($m.Groups[1].Value)' yok" }
    }
    foreach ($id in @($Themes.Keys) + 'custom') { foreach ($lang in 'tr', 'en') { Assert ($Texts[$lang].ContainsKey("theme_$id")) "$lang`: theme_$id yok" } }
}
Test 'Dil metinleri tam (tr ve en ayni anahtarlara sahip)' {
    foreach ($k in $Texts.tr.Keys) { Assert ($Texts.en.ContainsKey($k)) "en: '$k' eksik" }
    foreach ($k in $Texts.en.Keys) { Assert ($Texts.tr.ContainsKey($k)) "tr: '$k' eksik" }
    AssertEq ($Texts.tr.Pct -f 60) '%60' 'tr yuzde'; AssertEq ($Texts.en.Pct -f 60) '60%' 'en yuzde'
    AssertEq ($Texts.tr.LowTitle -f 20) 'Mouse pili %20' 'tr uyari'; AssertEq ($Texts.en.LowTitle -f 20) 'Mouse battery 20%' 'en uyari'
}

# =====================================================================
Section 'Cihaz listesi / Device table'

Test 'cihazlar.csv yuklendi: 200+ cihaz, tekrar yok' {
    Assert ($Devices.Count -ge 200) "cihaz sayisi $($Devices.Count)"
    $rows = @(Import-Csv $DevicePath)
    AssertEq $rows.Count $Devices.Count 'tekrarlanan kimlik var'
    foreach ($r in $rows) { Assert ($r.vid -and $r.pid -and $r.family -and $r.name) "eksik alan: $($r.vid):$($r.pid)" }
}
Test 'X1 Ultimate 2.0 kablolu mouse, 11D9 alici, ikisi de COMPX (pil destekli)' {
    AssertEq $x1u2.Name 'ATK X1 Ultimate 2.0' 'ad'; AssertEq $x1u2.Receiver $false 'kablolu'; AssertEq $x1u2.Battery $true 'pil'
    AssertEq $dongle.Receiver $true 'alici'; AssertEq $dongle.Battery $true 'alici pil'
}
Test 'Izlenen ureticiler: VID 373B ve 3554' {
    Assert ($WatchFilter.Contains('vid_373b')) $WatchFilter; Assert ($WatchFilter.Contains('vid_3554')) $WatchFilter
}
Test 'Aygit yolundan cihaz bulunur (Turkce kultur dahil), bilinmeyen null' {
    With-Culture 'tr-TR' {
        AssertEq (Get-AtkDevice '\\?\USB#VID_373B&PID_11E7#000000000001#{a5dcbf10}').Name 'ATK X1 Ultimate 2.0' 'buyuk harf yol'
        AssertEq (Get-AtkDevice '\\?\hid#vid_373b&pid_11d9&mi_01#x').Receiver $true 'kucuk harf yol'
        Assert ($null -eq (Get-AtkDevice '\\?\USB#VID_373B&PID_0001#x')) 'bilinmeyen PID'
        Assert ($null -eq (Get-AtkDevice '\\?\USB#VID_046D&PID_C52B#x')) 'baska uretici'
    }
}
Test 'Baslik bicimi: kisa adlar aralikli, uzun adlar duz, Turkce kulturde noktali I yok' {
    With-Culture 'tr-TR' {
        AssertEq (Format-DeviceTitle 'ATK X1 Ultimate 2.0') 'A T K   X 1   U L T I M A T E   2 . 0' 'kisa'
        AssertEq (Format-DeviceTitle 'VXE R1 / VXE R1SE / VXE R1SE+') 'VXE R1 / VXE R1SE / VXE R1SE+' 'uzun'
        AssertEq (Format-DeviceTitle 'ATK Mini') 'A T K   M I N I' 'Turkce I'
        AssertEq (Format-DeviceTitle '') 'A T K' 'bos'
    }
}

# =====================================================================
Section 'Temalar ve ayarlar / Themes and settings'

Test 'Renk karistirma dogru (siyah-beyaz %50 = 808080, sinirlar)' {
    AssertEq (Mix-Color '000000' 'FFFFFF' 0.5) '808080' 'orta'
    AssertEq (Mix-Color '39FF88' 'FFFFFF' 0) '39FF88' 't=0'
    AssertEq (Mix-Color '39FF88' '000000' 1) '000000' 't=1'
}
Test 'Tum hazir temalar gecerli renk uretir' {
    foreach ($id in $Themes.Keys) {
        $t = Get-Theme $id '' ''
        foreach ($k in 'A1', 'A2', 'A1L', 'Dark1', 'Dark2') { Assert (Test-HexColor $t[$k]) "$id.$k = '$($t[$k])'" }
    }
}
Test 'Ozel tema: gecerli HEX kullanilir, gecersizse neon temaya doner' {
    $t = Get-Theme 'custom' 'ff0000' '0000ff'
    AssertEq $t.A1 'FF0000' 'renk 1'; AssertEq $t.A2 '0000FF' 'renk 2'
    AssertEq (Get-Theme 'custom' 'zzz' '0000FF').A1 '39FF88' 'gecersiz'
    AssertEq (Get-Theme 'yok-boyle' '' '').A1 '39FF88' 'bilinmeyen tema'
}
Test 'Ayarlar kaydedilir ve geri okunur; eksik / bozuk dosyada varsayilanlar' {
    try {
        Set-AppSettings @{ theme = 'gold'; language = 'en'; fullNotify = $false }
        Save-Settings
        Set-AppSettings @{}
        Import-Settings
        AssertEq $AppSettings.theme 'gold' 'tema'; AssertEq $Txt.charging 'Charging' 'dil'
        AssertEq $FullNotify $false 'secenek'; AssertEq $LowWarn $true 'eksik anahtar varsayilan'
        AssertEq $Theme.A1 $Themes['gold'][0] 'tema rengi'
        [IO.File]::WriteAllText($SettingsPath, '{ bozuk json')
        Import-Settings
        AssertEq $AppSettings.theme 'neon' 'bozuk dosya'
    } finally { Remove-Item $SettingsPath -ErrorAction SilentlyContinue; Set-AppSettings @{} }
}
Test 'Ayar dosyasi degisince izleyici yeniden yukler' {
    try {
        $loopState.SettingsCheck = [datetime]::MinValue; Update-SettingsIfChanged
        Set-AppSettings @{ theme = 'pink' }; Save-Settings; Set-AppSettings @{}
        (Get-Item $SettingsPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(5)
        $loopState.SettingsCheck = [datetime]::MinValue; Update-SettingsIfChanged
        AssertEq $AppSettings.theme 'pink' 'yeni tema'
    } finally { Remove-Item $SettingsPath -ErrorAction SilentlyContinue; Set-AppSettings @{} }
}

# =====================================================================
Section 'Protokol / Protocol'

Test 'Pil istegi paketi ATK HUB ile birebir: 08 04 00x14 49' {
    $req = [AtkHid]::BuildRequest(4, 17)
    AssertEq ([BitConverter]::ToString($req)) '08-04-00-00-00-00-00-00-00-00-00-00-00-00-00-00-49' 'istek baytlari'
}
Test 'Saglama bayti, tum komutlar icin ATK HUB formulune esit' {
    # ATK HUB: checkSum = 85 - (255 & sum([8, ...ilk 15 bayt])), Uint8 olarak yazilir
    for ($cmd = 0; $cmd -le 255; $cmd++) {
        $expected = ((85 - (255 -band (8 + $cmd))) % 256 + 256) % 256
        AssertEq ([AtkHid]::BuildRequest([byte]$cmd, 17)[16]) $expected "komut $cmd"
    }
}
Test 'Daha uzun rapor boyunda saglama hala 16. baytta' {
    $req = [AtkHid]::BuildRequest(4, 65)
    AssertEq $req.Length 65 'uzunluk'; AssertEq $req[16] 0x49 'saglama'
    AssertEq ($req[17..64] | Measure-Object -Sum).Sum 0 'dolgu sifir'
}
Test 'Gercek ornek yanit: %60, sarj oluyor, 3967 mV' {
    $b = [AtkHid]::ParseBatteryResponse((New-Response @(8, 4, 0, 0, 0, 4, 60, 1, 0x0F, 0x7F)), 17)
    AssertEq $b.Level 60 'seviye'; AssertEq $b.IsCharging $true 'sarj'; AssertEq $b.VoltageMv 3967 'voltaj'
}
Test 'Mouse''tan kaydedilen yanit: %65, saglama bayti dogrulaniyor' {
    # 08-04-00-00-00-02-41-01-0F-9F-00x6-57 (gercek mouse, kabloyla sarjda)
    $raw = New-Response @(8, 4, 0, 0, 0, 2, 0x41, 1, 0x0F, 0x9F, 0, 0, 0, 0, 0, 0, 0x57)
    $b = [AtkHid]::ParseBatteryResponse($raw, 17)
    AssertEq $b.Level 65 'seviye'; AssertEq $b.VoltageMv 3999 'voltaj'; AssertEq $b.ChecksumOk $true 'saglama'
    $raw[16] = 0x58
    AssertEq ([AtkHid]::ParseBatteryResponse($raw, 17)).ChecksumOk $false 'bozuk saglama fark edilmeli'
}
Test 'Sarj durumu ATK HUB ile ayni (yalnizca 1 = sarj oluyor)' {
    foreach ($c in 0, 2, 3, 255) {
        $b = [AtkHid]::ParseBatteryResponse((New-Response @(8, 4, 0, 0, 0, 4, 50, $c, 0, 0)), 17)
        AssertEq $b.IsCharging $false "durum bayti $c"
    }
}
Test '100 ustu seviye 100 ile sinirlanir' {
    AssertEq ([AtkHid]::ParseBatteryResponse((New-Response @(8, 4, 0, 0, 0, 4, 255, 1, 0, 0)), 17)).Level 100 'seviye'
}
Test 'Baska raporlar pil yaniti sanilmaz (yanlis rapor no, DPI raporu=10, kisa veri, null)' {
    Assert ($null -eq [AtkHid]::ParseBatteryResponse((New-Response @(7, 4, 0, 0, 0, 4, 60, 1, 0, 0)), 17)) 'rapor 7'
    Assert ($null -eq [AtkHid]::ParseBatteryResponse((New-Response @(8, 10, 0, 0, 0, 4, 60, 1, 0, 0)), 17)) 'komut 10'
    Assert ($null -eq [AtkHid]::ParseBatteryResponse((New-Response @(8, 4, 0, 0, 0, 4, 60, 1, 0, 0)), 9)) 'kisa'
    Assert ($null -eq [AtkHid]::ParseBatteryResponse($null, 17)) 'null'
}

# =====================================================================
Section 'Takma algilama / Plug detection'

$WM_DEVICECHANGE = 0x219; $DBT_DEVICEARRIVAL = 0x8000; $DBT_DEVICEREMOVECOMPLETE = 0x8004
$mouseName = '\\?\USB#VID_373B&PID_11E7#000000000001#{a5dcbf10-6530-11d2-901f-00c04fb951ed}'
function Send-DeviceChange($Watcher, [int]$Event, [string]$Name, [int]$Type = 5) {
    $p = [TestNative]::MakeInterfaceBroadcast($Name, $Type)
    try { [void][TestNative]::SendMessage($Watcher.Handle, $WM_DEVICECHANGE, [IntPtr]$Event, $p) }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($p) }
}

Test 'Windows bildirimine kayit basarili' {
    $w = New-Object AtkDeviceWatcher $WatchFilter
    Assert ($w.Handle -ne [IntPtr]::Zero) 'pencere tanitici yok'
    $w.Dispose()
}
Test 'ATK (373B) ve eski ATK/VXE (3554) cihazlari yakalanir' {
    $w = New-Object AtkDeviceWatcher $WatchFilter
    try {
        Send-DeviceChange $w $DBT_DEVICEARRIVAL $mouseName
        Send-DeviceChange $w $DBT_DEVICEARRIVAL '\\?\USB#VID_3554&PID_F502#1#{a5dcbf10-6530-11d2-901f-00c04fb951ed}'
        AssertEq $w.TakeArrival() $mouseName 'olay 1'
        Assert ($w.TakeArrival().Contains('VID_3554')) 'olay 2'
        AssertEq $w.TakeArrival() $null 'kuyruk bos olmali'
    } finally { $w.Dispose() }
}
Test 'Baska uretici, cikarma olayi ve arayuz olmayan bildirim yakalanmaz' {
    $w = New-Object AtkDeviceWatcher $WatchFilter
    try {
        Send-DeviceChange $w $DBT_DEVICEARRIVAL '\\?\USB#VID_046D&PID_C52B#123#{a5dcbf10-6530-11d2-901f-00c04fb951ed}'
        Send-DeviceChange $w $DBT_DEVICEREMOVECOMPLETE $mouseName
        Send-DeviceChange $w $DBT_DEVICEARRIVAL $mouseName 3
        AssertEq $w.TakeArrival() $null 'hicbiri yakalanmamali'
    } finally { $w.Dispose() }
}
Test 'Ogrenme modu (bos filtre) tum USB cihazlarini yakalar' {
    $w = New-Object AtkDeviceWatcher ''
    try {
        Send-DeviceChange $w $DBT_DEVICEARRIVAL '\\?\USB#VID_046D&PID_C52B#123#{x}'
        Assert ($null -ne $w.TakeArrival()) 'yakalanmali'
    } finally { $w.Dispose() }
}
Test 'Alici, listede olmayan ATK cihazi (orn. klavye) ve alt arayuz sarj animasyonu acmaz' {
    With-Culture 'tr-TR' {
        $loopState.LastShown = [datetime]::MinValue
        $monitor.NextCheck = [datetime]::MaxValue
        AssertEq (Invoke-Arrival '\\?\USB#VID_373B&PID_11D9#000000000001#{x}') $false 'alici'
        Assert ($monitor.NextCheck -lt (Get-Date).AddSeconds(10)) 'alici takilinca pil kontrolu one alinmali'
        AssertEq (Invoke-Arrival '\\?\USB#VID_373B&PID_0001#1#{x}') $false 'bilinmeyen'
        AssertEq (Invoke-Arrival '\\?\USB#VID_373B&PID_11E7&MI_01#7&4761eb6&0&0001#{x}') $false 'alt arayuz'
    }
}

# =====================================================================
Section 'Dusuk pil uyarisi / Low battery warning'

function Reset-Warnings { foreach ($w in $WarnLevels) { $monitor.Warned[$w] = $false } }

Test 'Esikler: 20, 10, 5 birer kez; 19-21 dalgalanmasi tekrar uyarmaz; sarj sifirlar' {
    Reset-Warnings
    $steps = @(
        @(25, $false, $false), @(20, $false, $true), @(19, $false, $false), @(21, $false, $false), @(20, $false, $false),
        @(26, $false, $false), @(20, $false, $true),  @(12, $false, $false), @(10, $false, $true), @(5, $false, $true),
        @(3, $false, $false),  @(3, $true, $false),   @(18, $false, $true)
    )
    $i = 0
    foreach ($s in $steps) {
        $i++
        AssertEq (Update-LowBatteryWarnings $s[0] $s[1]) $s[2] "adim $i (seviye $($s[0]), sarj $($s[1]))"
    }
}
Test 'Baslangicta dusuk pil: tek uyari (ornegin %8 -> 20 ve 10 birlikte)' {
    Reset-Warnings
    AssertEq (Update-LowBatteryWarnings 8 $false) $true 'ilk'
    AssertEq (Update-LowBatteryWarnings 8 $false) $false 'tekrar yok'
    AssertEq (Update-LowBatteryWarnings 5 $false) $true '5'
}

# Izleme dongusunu sahte cihaz ve sahte okumayla bir tur calistirir; gosterilen uyarilari dondurur
function Invoke-MonitorRound($FakeDevices, [int]$Level, [int]$Charge = 0) {
    $toasts = New-Object Collections.ArrayList
    function Get-PresentAtkDevices { $FakeDevices }
    function Show-Toast([string]$Kind, [int]$Level, [string]$DeviceName) { [void]$toasts.Add("$Kind|$Level|$DeviceName") }
    $fakeLevel = $Level; $fakeCharge = $Charge
    $BatteryReader = { param($ReadId, $ReadTries) New-FakeRead $fakeLevel $fakeCharge }
    $monitor.Task = $null
    $monitor.NextCheck = [datetime]::MinValue
    Invoke-BatteryMonitor            # okumayi baslatir
    if ($monitor.Task) { [void]$monitor.Task.Wait(2000); Invoke-BatteryMonitor }   # sonucu isler
    , $toasts
}
Test 'Kablosuzken pil %19: uyari gosterilir, en son kabloyla gorulen mouse adiyla' {
    Reset-Warnings
    $monitor.MouseName = 'ATK X1 Ultimate 2.0'
    $t = Invoke-MonitorRound @($dongle) 19
    AssertEq $t.Count 1 'uyari sayisi'; AssertEq $t[0] 'low|19|ATK X1 Ultimate 2.0' 'uyari'
}
Test 'Mouse adi bilinmiyorsa alici adiyla uyarir' {
    Reset-Warnings
    $monitor.MouseName = $null
    $t = Invoke-MonitorRound @($dongle) 9
    AssertEq $t.Count 1 'uyari sayisi'; AssertEq $t[0] "low|9|$($dongle.Name)" 'uyari'
}
Test 'Dusuk pil uyarilari kapaliysa alici okunmaz' {
    Reset-Warnings
    $LowWarn = $false
    AssertEq (Invoke-MonitorRound @($dongle) 5).Count 0 'uyari sayisi'
}

Section 'Sarj doldu bildirimi / Fully charged notification'

Test 'Kabloda %98 -> %100: bir kez "sarj tamamlandi" bildirimi' {
    $monitor.FullNotified = $false; $monitor.WiredLastLevel = 98
    $t = Invoke-MonitorRound @($x1u2) 100 1
    AssertEq $t.Count 1 'bildirim sayisi'; AssertEq $t[0] 'full|100|ATK X1 Ultimate 2.0' 'bildirim'
    AssertEq (Invoke-MonitorRound @($x1u2) 100 0).Count 0 'tekrar bildirilmemeli'
}
Test 'Zaten doluyken takilirsa bildirim yok (animasyon "Tam dolu" der)' {
    $monitor.FullNotified = $false; $monitor.WiredLastLevel = $null
    AssertEq (Invoke-MonitorRound @($x1u2) 100 0).Count 0 'ilk okuma'
    AssertEq (Invoke-MonitorRound @($x1u2) 100 0).Count 0 'ikinci okuma'
}
Test 'Sarj suruyorsa (%100 degil) bildirim yok' {
    $monitor.FullNotified = $false; $monitor.WiredLastLevel = 80
    AssertEq (Invoke-MonitorRound @($x1u2) 85 1).Count 0 'bildirim sayisi'
    AssertEq $monitor.WiredLastLevel 85 'son seviye'
}
Test 'Bildirim kapaliysa okuma yapilmaz' {
    $monitor.FullNotified = $false; $monitor.WiredLastLevel = 98
    $FullNotify = $false
    AssertEq (Invoke-MonitorRound @($x1u2) 100 0).Count 0 'bildirim sayisi'
}
Test 'Kablo cikinca "sarj doldu" durumu sifirlanir' {
    $monitor.FullNotified = $true; $monitor.WiredLastLevel = 100
    [void](Invoke-MonitorRound @($dongle) 90 0)
    AssertEq $monitor.FullNotified $false 'bildirildi bayragi'; AssertEq $monitor.WiredLastLevel $null 'son seviye'
}
Test 'Takma olayi "sarj doldu" durumunu sifirlar' {
    $monitor.FullNotified = $true; $monitor.WiredLastLevel = 100
    function Show-ChargeAnimation { }   # bu testte pencere acilmasin
    $loopState.LastShown = [datetime]::MinValue
    [void](Invoke-Arrival '\\?\USB#VID_373B&PID_11E7#000000000001#{x}')
    AssertEq $monitor.FullNotified $false 'bildirildi bayragi'
    $loopState.LastShown = [datetime]::MinValue
}
Test 'Kablo da takiliyken (sarjda) uyari gosterilmez ve esikler sifirlanir' {
    $monitor.Warned[20] = $true
    $t = Invoke-MonitorRound @($dongle, $x1u2) 15
    AssertEq $t.Count 0 'uyari sayisi'; AssertEq $monitor.Warned[20] $false 'sifirlanmali'
}
Test 'Mouse uykudayken (yanit yok ya da %0) uyari gosterilmez' {
    Reset-Warnings
    AssertEq (Invoke-MonitorRound @($dongle) -1).Count 0 'yanit yok'
    AssertEq (Invoke-MonitorRound @($dongle) 0).Count 0 '%0'
}
Test 'Pil destegi olmayan aile ya da cihaz yoksa okuma yapilmaz' {
    $other = [pscustomobject]@{ Id = 'vid_373b&pid_1234'; Name = 'X'; Family = 'BITMOUSE'; Receiver = $true; Battery = $false }
    AssertEq (Invoke-MonitorRound @($other) 10).Count 0 'desteksiz aile'
    AssertEq (Invoke-MonitorRound @() 10).Count 0 'cihaz yok'
}

# =====================================================================
Section 'Animasyon / Animation'

# Pencereyi gosterir ve ekrandaki degerleri okur. -ClickAtMs: o anda pencereye tiklamayi taklit eder
# Not: adlar Show-ChargeAnimation'in yerel degiskenleriyle cakismamali (olay bloklari dinamik kapsam kullanir)
function Invoke-WindowProbe([scriptblock]$Show, [string]$TextName, [int]$ClickAtMs = -1) {
    $probeData = @{ Texts = @{} }
    $probeSw = [Diagnostics.Stopwatch]::StartNew()
    $probeTimer = New-Object Windows.Threading.DispatcherTimer
    $probeTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $probeTimer.Add_Tick({
        foreach ($src in [Windows.PresentationSource]::CurrentSources) {
            $win = $src.RootVisual
            if ($win -isnot [Windows.Window] -or -not $win.IsVisible) { continue }
            $ms = $probeSw.ElapsedMilliseconds
            foreach ($n in 'PctText', 'StatusText', 'TitleText', 'ToastTitle', 'ToastBody', 'ToastDevice') {
                $el = $win.FindName($n); if ($el) { $probeData.Texts[$n] = $el.Text }
            }
            $liq = $win.FindName('LiquidY')
            if ($liq) {
                if ($ms -ge 1200 -and -not $probeData.ContainsKey('Y1')) { $probeData.Y1 = $liq.Y }
                $probeData.Y2 = $liq.Y
                $probeData.Stop1 = $win.FindName('LiqStop1').Color.ToString()
                [void]($probeData.PctSeen = @($probeData.PctSeen) + $probeData.Texts.PctText | Select-Object -Unique)
            }
            $probeData.Left = $win.Left; $probeData.Top = $win.Top; $probeData.Width = $win.Width; $probeData.Height = $win.Height
            $probeData.ShowActivated = $win.ShowActivated
            $iconFull = $win.FindName('IconFull'); if ($iconFull) { $probeData.IconFull = $iconFull.Visibility.ToString(); $probeData.IconLow = $win.FindName('IconLow').Visibility.ToString() }
            $probeData.LastMs = $ms
            if ($ClickAtMs -ge 0 -and $ms -ge $ClickAtMs -and -not $probeData.Clicked) {
                $probeData.Clicked = $true
                $click = New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
                $click.RoutedEvent = [Windows.UIElement]::MouseLeftButtonDownEvent
                $win.RaiseEvent($click)
            }
        }
    })
    $probeTimer.Start()
    & $Show
    $probeTimer.Stop()
    $probeData.Seconds = $probeSw.Elapsed.TotalSeconds
    $probeData.Pct = $probeData.Texts.PctText; $probeData.Status = $probeData.Texts.StatusText
    $probeData
}
function Invoke-AnimationProbe($Battery, $Device = $null, [int]$ClickAtMs = -1) {
    $p = Invoke-WindowProbe { Show-ChargeAnimation -Device $Device -Battery $Battery } 'PctText' $ClickAtMs
    # Sayac 1.6 sn surer; son okuma bundan sonra yapilmis olmali
    if ($ClickAtMs -lt 0 -and $p.LastMs -lt 2000) { throw "pencere erken kapandi ya da okunamadi (son okuma: $($p.LastMs) ms)" }
    $p
}
function FakeBattery([int]$Level, [bool]$Charging) { [pscustomobject]@{ Level = $Level; IsCharging = $Charging } }
$red = '#FFFF5A5A'; $green = '#FF' + $Theme.A1   # varsayilan tema (neon)

if ($SkipUI) { Skip 'Animasyon ve uyari balonu testleri' '-SkipUI' }
else {
    $DisplaySeconds = 2.6
    $ClickToClose = $false   # test sirasinda ekrana yapilan gercek tiklamalar sonucu bozmasin

    Test 'Tiklayinca kapanir (ayar acikken)' {
        $ClickToClose = $true
        $p = Invoke-AnimationProbe (FakeBattery 60 $true) -ClickAtMs 500
        Assert $p.Clicked 'tiklama gonderilemedi'
        Assert ($p.Seconds -lt 1.5) "tiklamadan sonra kapanmadi ($($p.Seconds) sn)"
    }
    Test 'Tiklama kapaliyken pencere tam sure kalir' {
        $p = Invoke-AnimationProbe (FakeBattery 60 $true) -ClickAtMs 500
        Assert ($p.Seconds -ge $DisplaySeconds) "erken kapandi ($($p.Seconds) sn)"
    }
    $cases = @(
        @{ L = 60;  C = $true;  Status = $Txt.Charging; Color = $green },
        @{ L = 0;   C = $true;  Status = $Txt.Charging; Color = $red },
        @{ L = 15;  C = $true;  Status = $Txt.Charging; Color = $red },
        @{ L = 20;  C = $true;  Status = $Txt.Charging; Color = $red },     # sinir / boundary
        @{ L = 21;  C = $true;  Status = $Txt.Charging; Color = $green },
        @{ L = 100; C = $false; Status = $Txt.Full;     Color = $green },
        @{ L = 50;  C = $false; Status = $Txt.Cable;    Color = $green }
    )
    foreach ($c in $cases) {
        $c.Pct = $Txt.Pct -f $c.L
        Test "Pil %$($c.L), sarj=$($c.C): '$($c.Pct)' / '$($c.Status)'" {
            $p = Invoke-AnimationProbe (FakeBattery $c.L $c.C)
            AssertEq $p.Pct $c.Pct 'yuzde yazisi'
            AssertEq $p.Status $c.Status 'durum yazisi'
            AssertEq $p.Stop1 $c.Color 'sivi rengi'
            $expectedY = 124 - 116 * $c.L / 100
            Assert ([Math]::Abs($p.Y2 - $expectedY) -lt 0.5) "sivi seviyesi Y=$($p.Y2), beklenen $expectedY"
            Assert ($p.Seconds -lt $DisplaySeconds + 1.5) "pencere kapanmadi ($($p.Seconds) sn)"
        }
    }
    Test 'Baslikta takilan cihazin adi yazar' {
        $p = Invoke-AnimationProbe (FakeBattery 60 $true) $x1u2
        AssertEq $p.Texts.TitleText 'A T K   X 1   U L T I M A T E   2 . 0' 'baslik'
    }
    Test 'Canli guncelleme: takinca %55, 2 sn sonra %65 -> animasyon %65 gosterir (ATK HUB gibi)' {
        $DisplaySeconds = 4.5
        $fakeStart = Get-Date
        $BatteryReader = { param($ReadId, $ReadTries) New-FakeRead $(if (((Get-Date) - $fakeStart).TotalSeconds -lt 2) { 55 } else { 65 }) 1 }
        $p = Invoke-AnimationProbe $null $x1u2
        AssertEq $p.Pct ($Txt.Pct -f 65) 'son deger'
        Assert (@($p.PctSeen) -contains ($Txt.Pct -f 55)) "once %55 gorulmeli: $(@($p.PctSeen) -join ',')"
        $expectedY = 124 - 116 * 65 / 100
        Assert ([Math]::Abs($p.Y2 - $expectedY) -lt 0.5) "sivi seviyesi Y=$($p.Y2), beklenen $expectedY"
        $log = Get-Content $LogPath -Raw
        Assert ($log.Contains('pil: %55') -and $log.Contains('pil: %65')) 'iki okuma da loga yazilmali'
    }
    Test 'Pil okunamazsa: sus animasyonu, metin degismez, hata yok' {
        $BatteryReader = { param($ReadId, $ReadTries) New-FakeRead -1 }
        $p = Invoke-AnimationProbe $null $x1u2
        AssertEq $p.Pct $Txt.Charging 'yazi'
        AssertEq $p.Status $Txt.Cable 'durum'
        Assert ([Math]::Abs($p.Y1 - $p.Y2) -gt 1) 'sivi hareket etmeli (dongu)'
    }
    Test 'Pil protokolu olmayan aile: okuma denenmez, sus animasyonu' {
        $script:readCalls = 0
        $BatteryReader = { param($ReadId, $ReadTries) $script:readCalls++; New-FakeRead 50 }
        $other = [pscustomobject]@{ Id = 'vid_373b&pid_12ab'; Name = 'ATK Test'; Family = 'BITMOUSE'; Receiver = $false; Battery = $false }
        $p = Invoke-AnimationProbe $null $other
        AssertEq $script:readCalls 0 'okuma cagrisi'; AssertEq $p.Pct $Txt.Charging 'yazi'
    }
    Test 'Ingilizce: 60% / Charging' {
        $Txt = $Texts.en
        $p = Invoke-AnimationProbe (FakeBattery 60 $true)
        AssertEq $p.Pct '60%' 'yuzde'; AssertEq $p.Status 'Charging' 'durum'
    }

    # Uyari balonu
    Test 'Uyari balonu: metin, sag alt kose, odak calmaz, sure sonunda kapanir' {
        $ToastSeconds = 1.5
        $p = Invoke-WindowProbe { Show-Toast 'low' 18 'ATK X1 Ultimate 2.0' } 'ToastTitle'
        AssertEq $p.Texts.ToastTitle ($Txt.LowTitle -f 18) 'baslik'
        AssertEq $p.Texts.ToastBody $Txt.LowBody 'metin'
        AssertEq $p.Texts.ToastDevice 'ATK X1 Ultimate 2.0' 'cihaz'
        $work = [Windows.SystemParameters]::WorkArea
        Assert ([Math]::Abs(($p.Left + $p.Width) - $work.Right) -lt 1) "sag kenar: $($p.Left + $p.Width) / $($work.Right)"
        Assert ([Math]::Abs(($p.Top + $p.Height) - $work.Bottom) -lt 1) "alt kenar: $($p.Top + $p.Height) / $($work.Bottom)"
        AssertEq $p.ShowActivated $false 'odak'
        Assert ($p.Seconds -ge 1.5 -and $p.Seconds -lt 3) "sure: $($p.Seconds) sn"
    }
    Test 'Uyari balonu %5 ve alti: kritik metin' {
        $ToastSeconds = 1
        $p = Invoke-WindowProbe { Show-Toast 'low' 5 'ATK X1 Ultimate 2.0' } 'ToastTitle'
        AssertEq $p.Texts.ToastBody $Txt.CriticalBody 'kritik metin'
    }
    Test '"Sarj tamamlandi" bildirimi: tema renginde, dolu pil simgesi, dogru metin' {
        $ToastSeconds = 1.2
        $p = Invoke-WindowProbe { Show-Toast 'full' 100 'ATK X1 Ultimate 2.0' } 'ToastTitle'
        AssertEq $p.Texts.ToastTitle $Txt.FullTitle 'baslik'; AssertEq $p.Texts.ToastBody $Txt.FullBody 'metin'
        AssertEq $p.IconFull 'Visible' 'dolu simgesi'; AssertEq $p.IconLow 'Collapsed' 'dusuk simgesi'
    }
    Test 'Tema animasyona uygulanir (mor tema: sivi rengi C471F5)' {
        Set-AppSettings @{ theme = 'purple'; clickToClose = $false }
        try {
            $p = Invoke-AnimationProbe (FakeBattery 70 $true) $x1u2
            AssertEq $p.Stop1 '#FFC471F5' 'sivi rengi'
        } finally { Set-AppSettings @{}; $script:ClickToClose = $false }
    }
    Test 'Uyari balonu tiklayinca kapanir' {
        $ToastSeconds = 5; $ClickToClose = $true
        $p = Invoke-WindowProbe { Show-Toast 'low' 10 'X' } 'ToastTitle' -ClickAtMs 400
        Assert ($p.Seconds -lt 1.5) "kapanmadi ($($p.Seconds) sn)"
    }

    # Uctan uca: takma olayi -> filtre -> bekleme suresi -> animasyon (gercek akis)
    Test 'Takma olayi animasyonu gosterir' {
        $BatteryReader = { param($ReadId, $ReadTries) New-FakeRead 70 1 }
        $loopState.LastShown = [datetime]::MinValue
        $sw = [Diagnostics.Stopwatch]::StartNew()
        AssertEq (Invoke-Arrival $mouseName) $true 'gosterilmeli'
        Assert ($sw.Elapsed.TotalSeconds -ge $DisplaySeconds) "pencere cok kisa surdu ($($sw.Elapsed.TotalSeconds) sn)"
    }
    Test "Bekleme suresi icinde ($CooldownSec sn) tekrar gosterilmez" {
        AssertEq (Invoke-Arrival $mouseName) $false 'gosterilmemeli'
    }
    Test 'Takma olaylari log dosyasina yaziliyor' {
        $lines = @(Get-Content $LogPath)
        Assert (@($lines | Where-Object { $_.Contains('takildi: ') }).Count -ge 2) 'takildi satiri yok'
    }

    # Ayarlar penceresi: gercek pencere acilir, tiklamalar programdan yapilir (gecici ayar dosyasiyla)
    Test 'Kontrol merkezi: durum karti, otomatik baslatma, 9 tema, secim/secenek/dil/ozel renk kaydedilir' {
        Remove-Item $SettingsPath -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $StartupDir '*') -ErrorAction SilentlyContinue
        $drive = @{ Step = 0; Log = @{}; Waits = 0; Mutex = $null }
        $readSaved = { [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json }
        $driveTimer = New-Object Windows.Threading.DispatcherTimer
        $driveTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $driveTimer.Add_Tick({
            foreach ($src in [Windows.PresentationSource]::CurrentSources) {
                $sw = $src.RootVisual
                if ($sw -isnot [Windows.Window] -or -not $sw.IsVisible -or -not $sw.FindName('ThemePanel')) { continue }
                $click = { param($el) $el.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
                $panel = $sw.FindName('ThemePanel')
                try {
                    switch ($drive.Step) {
                        0 { $drive.Log.Swatches = $panel.Children.Count
                            $drive.Log.StatusStopped = $sw.FindName('StatusText').Text
                            $drive.Log.ButtonStopped = $sw.FindName('ServiceButton').Content
                            $drive.Log.AutostartInitial = [bool]$sw.FindName('AutostartBox').IsChecked
                            $drive.Log.HasIcon = $null -ne $sw.Icon
                            $drive.Mutex = New-Object Threading.Mutex($true, $MutexName)   # izleyici calisiyormus gibi
                            $ab = $sw.FindName('AutostartBox'); $ab.IsChecked = $true; & $click $ab
                            & $click ($panel.Children | Where-Object { $_.Tag -eq 'ocean' }) }
                        1 { # durum karti zamanlayiciyla (1 sn) yenilenir: "calisiyor" gorunene kadar bekle
                            if ($sw.FindName('StatusText').Text -ne $Txt.statusRunning -and $drive.Waits++ -lt 20) { return }
                            $drive.Log.StatusRunning = $sw.FindName('StatusText').Text
                            $drive.Log.ButtonRunning = $sw.FindName('ServiceButton').Content
                            $drive.Log.AutostartFile = Test-Path (Join-Path $StartupDir $ShortcutName)
                            $drive.Log.Theme = (& $readSaved).theme
                            $cb = $sw.FindName('FullNotifyBox'); $cb.IsChecked = $false; & $click $cb }
                        2 { $drive.Log.FullNotify = (& $readSaved).fullNotify
                            $sw.FindName('LangEn').IsChecked = $true }
                        3 { $drive.Log.Language = (& $readSaved).language
                            & $click ($panel.Children | Where-Object { $_.Tag -eq 'custom' })
                            $sw.FindName('Custom1Box').Text = 'zz12' }
                        4 { $drive.Log.CustomVisible = $sw.FindName('CustomPanel').Visibility.ToString()
                            $drive.Log.InvalidBorder = $sw.FindName('Custom1Box').BorderBrush.Color.ToString()
                            $drive.Log.CustomAfterInvalid = (& $readSaved).custom1
                            $sw.FindName('Custom1Box').Text = '#ff0000' }
                        5 { $drive.Log.Custom1 = (& $readSaved).custom1; $drive.Log.Theme2 = (& $readSaved).theme
                            $sw.Close() }
                    }
                } catch { $drive.Log.Error = "adim $($drive.Step): $_"; $sw.Close() }
                $drive.Step++
            }
        })
        $driveTimer.Start()
        try { . (Join-Path $Root 'ayarlar.ps1') }
        finally {
            $driveTimer.Stop()
            if ($drive.Mutex) { $drive.Mutex.ReleaseMutex(); $drive.Mutex.Dispose() }
            Remove-Item $SettingsPath -ErrorAction SilentlyContinue; Remove-Item (Join-Path $StartupDir '*') -ErrorAction SilentlyContinue
            Set-AppSettings @{}; $script:ClickToClose = $false
        }
        Assert (-not $drive.Log.Error) $drive.Log.Error
        AssertEq $drive.Log.StatusStopped $Txt.statusStopped 'durum: calismiyor'; AssertEq $drive.Log.ButtonStopped $Txt.btnStart 'dugme: baslat'
        AssertEq $drive.Log.StatusRunning $Txt.statusRunning 'durum: calisiyor'; AssertEq $drive.Log.ButtonRunning $Txt.btnStop 'dugme: durdur'
        AssertEq $drive.Log.AutostartInitial $false 'otomatik baslatma baslangicta kapali (bos test klasoru)'
        AssertEq $drive.Log.AutostartFile $true 'otomatik baslatma kisayolu olusmali'
        AssertEq $drive.Log.HasIcon $true 'pencere simgesi'
        AssertEq $drive.Log.Swatches 9 'tema sayisi'
        AssertEq $drive.Log.Theme 'ocean' 'tema kaydi'
        AssertEq $drive.Log.FullNotify $false 'secenek kaydi'
        AssertEq $drive.Log.Language 'en' 'dil kaydi'
        AssertEq $drive.Log.CustomVisible 'Visible' 'ozel renk paneli'
        AssertEq $drive.Log.InvalidBorder '#FFE5484D' 'gecersiz renk kirmizi kenarlik'
        AssertEq $drive.Log.CustomAfterInvalid '39FF88' 'gecersiz renk kaydedilmemeli'
        AssertEq $drive.Log.Custom1 'FF0000' 'ozel renk kaydi'; AssertEq $drive.Log.Theme2 'custom' 'ozel tema'
    }
}

# =====================================================================
Section 'Gercek mouse / Real hardware'

$present = @(Get-PresentAtkDevices)
$hwWired = @($present | Where-Object { $_.Battery -and -not $_.Receiver })
$hwRx    = @($present | Where-Object { $_.Battery -and $_.Receiver })
Write-Host ("         takili ATK cihazlari / present: {0}" -f $(if ($present) { ($present | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', ' } else { '-' })) -ForegroundColor DarkGray
if ($SkipHardware) { Skip 'Donanim testleri' '-SkipHardware' }
elseif (-not $hwWired -and -not $hwRx) { Skip 'Donanim testleri' 'pil destekli ATK cihazi takili degil / no supported device plugged in' }
else {
    $hubRunning = [bool](Get-Process -Name 'ATK HUB' -ErrorAction SilentlyContinue)
    Write-Host "         (ATK HUB calisiyor mu / running: $hubRunning)" -ForegroundColor DarkGray
    foreach ($dev in @($hwWired + $hwRx)) {
        $kind = if ($dev.Receiver) { 'alici / receiver' } else { 'kablo / wired' }
        $reads = New-Object Collections.ArrayList
        Test "[$kind] 10 ardisik okuma: hepsi basarili, her biri 1 sn altinda" {
            for ($i = 0; $i -lt 10; $i++) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $b = [AtkHid]::ReadBattery($dev.Id, 1000)
                $sw.Stop()
                Assert ($null -ne $b) "okuma $i basarisiz"
                Assert ($sw.ElapsedMilliseconds -lt 1000) "okuma $i yavas: $($sw.ElapsedMilliseconds) ms"
                [void]$reads.Add([pscustomobject]@{ Level = $b.Level; Charge = $b.Charge; mV = $b.VoltageMv; ms = $sw.ElapsedMilliseconds; Raw = $b.Raw; ChecksumOk = $b.ChecksumOk })
                Start-Sleep -Milliseconds 100
            }
        }
        if ($reads.Count) {
            $first = $reads[0]
            Write-Host ("         ilk yanit / first response: {0}" -f $first.Raw) -ForegroundColor DarkGray
            Write-Host ("         %{0}, durum/charge {1}, {2} mV, ort. {3:N0} ms" -f $first.Level, $first.Charge, $first.mV, ($reads | Measure-Object ms -Average).Average) -ForegroundColor DarkGray
        }
        Test "[$kind] Okumalar tutarli (seviye farki en fazla 1, durum ayni)" {
            $lv = $reads | Measure-Object Level -Minimum -Maximum
            Assert (($lv.Maximum - $lv.Minimum) -le 1) "seviye dalgalaniyor: $($lv.Minimum)-$($lv.Maximum)"
            AssertEq @($reads.Charge | Sort-Object -Unique).Count 1 'durum bayti degisken'
        }
        Test "[$kind] Yanitlarin saglama bayti dogru (protokol dogru yorumlaniyor)" {
            foreach ($r in $reads) { Assert $r.ChecksumOk "gecersiz saglama: $($r.Raw)" }
        }
        Test "[$kind] Degerler fiziksel olarak makul (1-100, Li-ion 3.0-4.5 V)" {
            foreach ($r in $reads) {
                Assert ($r.Level -ge 1 -and $r.Level -le 100) "seviye $($r.Level)"
                Assert ($r.mV -ge 3000 -and $r.mV -le 4500) "voltaj $($r.mV) mV"
            }
        }
        if (-not $dev.Receiver) {
            Test '[kablo] Kabloyla takiliyken sarj oluyor ya da dolu gorunuyor' {
                $r = $reads[0]
                Assert ($r.Charge -eq 1 -or $r.Level -eq 100) "durum bayti $($r.Charge), seviye $($r.Level)"
            }
        }
    }
    Test 'Arka plan okumasi (ReadBatteryAsync) 3 sn icinde sonuc verir' {
        $task = [AtkHid]::ReadBatteryAsync(@($hwWired + $hwRx)[0].Id, 400, 6, 250)
        Assert ($task.Wait(3000)) 'zaman asimi'
        Assert ($null -ne $task.Result) 'sonuc null'
    }
    Test 'Olmayan cihazda okuma hatasiz null doner' {
        Assert ($null -eq [AtkHid]::ReadBattery('vid_373b&pid_ffff', 300)) 'null olmali'
    }
}

# =====================================================================
Section 'Kontrol merkezi islevleri / Control center functions'

Test 'Izleyici durumu tek-kopya kilidinden okunur' {
    AssertEq (Test-WatcherRunning) $false 'kilit yokken'
    $held = New-Object Threading.Mutex($true, $MutexName)
    try { AssertEq (Test-WatcherRunning) $true 'kilit varken' }
    finally { $held.ReleaseMutex(); $held.Dispose() }
    AssertEq (Test-WatcherRunning) $false 'kilit birakilinca'
}
Test 'Otomatik baslatma: kisayol olusur, app\baslat.vbs''i gosterir, eski adli kisayol temizlenir, kapatilinca silinir' {
    $legacy = Join-Path $StartupDir $LegacyShortcutNames[0]
    Set-Content -Path $legacy -Value 'eski'
    Set-Autostart $true
    AssertEq (Test-Autostart) $true 'acik'
    Assert (-not (Test-Path $legacy)) 'eski kisayol silinmeli'
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $StartupDir $ShortcutName))
    Assert ($lnk.TargetPath.ToLowerInvariant().EndsWith('wscript.exe')) "hedef: $($lnk.TargetPath)"
    Assert ($lnk.Arguments.Contains((Join-Path $Root 'baslat.vbs'))) "arguman: $($lnk.Arguments)"
    Set-Autostart $false
    AssertEq (Test-Autostart) $false 'kapali'
}
Test 'Indirilen dosya engeli (Zone.Identifier) kaldirilir' {
    $probe = Join-Path $Root "tests\unblock-probe-$PID.tmp"
    try {
        Set-Content -Path $probe -Value 'x'
        Set-Content -Path $probe -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
        Assert ($null -ne (Get-Item $probe -Stream Zone.Identifier -ErrorAction SilentlyContinue)) 'engel eklenemedi'
        Unblock-AppFiles
        Assert ($null -eq (Get-Item $probe -Stream Zone.Identifier -ErrorAction SilentlyContinue)) 'engel kaldirilmali'
    } finally { Remove-Item $probe -ErrorAction SilentlyContinue }
}

# =====================================================================
Section 'Program / Process'

Test 'Ikinci kopya acilmaz (tek kopya kilidi)' {
    $mutex = New-Object Threading.Mutex($false, $MutexName)
    $ownedHere = $mutex.WaitOne(0)   # calisan izleyici yoksa kilidi test icin biz tutariz
    try {
        $p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'atk-sarj.ps1')`"" -WindowStyle Hidden -PassThru
        $exited = $p.WaitForExit(15000)
        if (-not $exited) { $p.Kill() }
        Assert $exited 'ikinci kopya kapanmadi'
    } finally { if ($ownedHere) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
Test 'Baslaticilar: ana klasordeki tek dosya kontrol merkezini, app\baslat.vbs izleyiciyi gizli acar' {
    $vbs = Get-Content (Join-Path $Root 'baslat.vbs') -Raw
    Assert ($vbs.Contains('atk-sarj.ps1') -and $vbs.Contains('ayarlar.ps1')) 'baslat.vbs iki modu da desteklemeli'
    Assert ($vbs.Contains('WindowStyle Hidden')) 'gizli calismiyor'
    $main = Get-Content (Join-Path (Split-Path $Root -Parent) 'ATK Charge Animation.vbs') -Raw
    Assert ($main.Contains('\app\baslat.vbs') -and $main.Contains('ayarlar')) 'ana baslatici kontrol merkezini acmiyor'
}

Remove-Item $LogPath -ErrorAction SilentlyContinue
Remove-Item $env:ATK_STARTUP_DIR -Recurse -ErrorAction SilentlyContinue

# =====================================================================
Write-Host ''
$color = if ($script:Fail) { 'Red' } else { 'Green' }
Write-Host ("Sonuc / Result: {0} gecti/passed, {1} basarisiz/failed, {2} atlandi/skipped" -f $script:Pass, $script:Fail, $script:Skipped) -ForegroundColor $color
exit $script:Fail

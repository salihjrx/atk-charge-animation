<#
  ATK mouse sarj animasyonu ve pil bildirimleri
  - Mouse USB kabloyla takildiginda ekranda sarj animasyonu gosterir (gercek pil yuzdesiyle).
  - Kablosuz kullanirken pil %20 / %10 / %5'e dusunce sag altta kirmizi uyari balonu gosterir.
  - Kabloda sarj olurken %100'e ulasinca tema renginde "sarj tamamlandi" bildirimi gosterir.
  Pil, ATK HUB ile ayni HID protokoluyle mouse'tan okunur (bkz. AtkHid.cs); ATK HUB gerekmez. Desteklenen cihazlar: cihazlar.csv
  Kullanici her seyi kontrol merkezinden yapar: ..\ATK Charge Animation.exe -> ayarlar.ps1 (ayarlar.json). Metinler: metinler.json

  Kullanim:
    atk-sarj.ps1               -> arka planda takip eder
    atk-sarj.ps1 -Test         -> sarj animasyonunu hemen bir kez gosterir
    atk-sarj.ps1 -TestWarning  -> dusuk pil uyarisini hemen bir kez gosterir
    atk-sarj.ps1 -TestFull     -> sarj tamamlandi bildirimini hemen bir kez gosterir
    atk-sarj.ps1 -Learn        -> takilan TUM USB cihazlarini ekrana yazar (kimlik bulmak icin)
#>
param([switch]$Test, [switch]$TestWarning, [switch]$TestFull, [switch]$Learn)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'AtkHid.cs') -ReferencedAssemblies System.Windows.Forms

# --- Sabit ayarlar (kullanici ayarlari icin: kontrol merkezi) ----------------
$DisplaySeconds = 6              # sarj animasyonunun ekranda kalma suresi
$CooldownSec    = 8              # bu sure icinde tekrar takilirsa animasyon yeniden gosterilmez
$LowLevel       = 20             # animasyonda bu yuzde ve alti: sivi turuncu-kirmizi
$WarnLevels     = @(20, 10, 5)   # kablosuzken bu seviyelere dusunce uyari balonu
$CheckSeconds   = 60             # pil kontrol araligi (sn): kablosuzken dusuk pil, kabloda dolma icin
$ToastSeconds   = 5              # bildirim balonunun ekranda kalma suresi
# --------------------------------------------------------------------------

$XamlPath     = Join-Path $PSScriptRoot 'animasyon.xaml'
$ToastPath    = Join-Path $PSScriptRoot 'bildirim.xaml'
$DevicePath   = Join-Path $PSScriptRoot 'cihazlar.csv'
$TextsPath    = Join-Path $PSScriptRoot 'metinler.json'
$LogPath      = Join-Path $PSScriptRoot 'cihaz-log.txt'
$AppDir       = $PSScriptRoot
$ExePath      = Join-Path (Split-Path $PSScriptRoot -Parent) 'ATK Charge Animation.exe'   # tek giris noktasi
$DesktopDir   = if ($env:ATK_DESKTOP_DIR) { $env:ATK_DESKTOP_DIR } else { [Environment]::GetFolderPath('Desktop') }
# Testler gercek ayarlara, Baslangic klasorune ve calisan izleyiciye dokunmasin diye ortam degiskenleriyle degistirilebilir
$SettingsPath = if ($env:ATK_SETTINGS)    { $env:ATK_SETTINGS }    else { Join-Path $PSScriptRoot 'ayarlar.json' }
$StartupDir   = if ($env:ATK_STARTUP_DIR) { $env:ATK_STARTUP_DIR } else { [Environment]::GetFolderPath('Startup') }
$MutexName    = if ($env:ATK_MUTEX)       { $env:ATK_MUTEX }       else { 'Global\ATK_Charge_Animation' }
$ShortcutName = 'ATK Charge Animation.lnk'
$LegacyShortcutNames = @('ATK Sarj Animasyonu.lnk')   # eski surumlerin kisayolu

# --- Renk temalari: iki vurgu rengi (RRGGBB) --------------------------------
$Themes = [ordered]@{
    neon   = @('39FF88', '00C6FF')
    ocean  = @('4FACFE', '00F2FE')
    purple = @('C471F5', '7A5CFF')
    pink   = @('FF5FA2', 'FF9CEE')
    sunset = @('FFB347', 'FF5E62')
    gold   = @('F7E27C', 'E0A526')
    ice    = @('E0F7FF', '8FB8FF')
    red    = @('FF4D6D', 'FF8E53')
}

# Kullanici ayarlari (ayarlar.json bu varsayilanlarin ustune yazar)
$DefaultSettings = [ordered]@{
    theme        = 'neon'
    custom1      = '39FF88'
    custom2      = '00C6FF'
    language     = 'auto'      # 'auto' (sistem dili), 'tr' veya 'en'
    fullNotify   = $true       # sarj dolunca bildirim
    lowWarn      = $true       # kablosuzken dusuk pil uyarisi
    clickToClose = $true       # animasyona / balona tiklayinca hemen kapansin
    setupVersion = 0           # tek seferlik kurulum adimlarinin surumu (kontrol merkezi yonetir)
}

# --- Yardimcilar ------------------------------------------------------------
function Test-HexColor([string]$Hex) { return [regex]::IsMatch("$Hex", '^[0-9A-Fa-f]{6}$') }

# Iki rengi karistirir: $T=0 -> $Hex, $T=1 -> $Toward
function Mix-Color([string]$Hex, [string]$Toward, [double]$T) {
    $out = ''
    for ($i = 0; $i -lt 6; $i += 2) {
        $a = [Convert]::ToInt32($Hex.Substring($i, 2), 16)
        $c = [Convert]::ToInt32($Toward.Substring($i, 2), 16)
        $out += '{0:X2}' -f [int][Math]::Round($a + ($c - $a) * $T)
    }
    return $out
}

# Tema renkleri: A1/A2 vurgu, A1L acik ton (yazi), Dark1/Dark2 koyu tonlar (bildirim zemini)
function Get-Theme([string]$ThemeId, [string]$Custom1, [string]$Custom2) {
    if ($ThemeId -eq 'custom' -and (Test-HexColor $Custom1) -and (Test-HexColor $Custom2)) { $pair = @($Custom1.ToUpperInvariant(), $Custom2.ToUpperInvariant()) }
    elseif ($Themes.Contains($ThemeId)) { $pair = $Themes[$ThemeId] }
    else { $pair = $Themes['neon'] }
    @{
        A1 = $pair[0]; A2 = $pair[1]
        A1L = Mix-Color $pair[0] 'FFFFFF' 0.6
        Dark1 = Mix-Color $pair[0] '000000' 0.55
        Dark2 = Mix-Color $pair[1] '000000' 0.6
    }
}

# {{ANAHTAR}} yer tutucularini doldurur
function Expand-Template([string]$Text, [hashtable]$Values) {
    foreach ($k in $Values.Keys) { $Text = $Text.Replace('{{' + $k + '}}', [string]$Values[$k]) }
    return $Text
}

# metinler.json -> @{ tr = @{...}; en = @{...} } (anahtarlar kulturden bagimsiz, buyuk/kucuk harf duyarsiz)
function Import-Texts {
    $json = [IO.File]::ReadAllText($TextsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $all = @{}
    foreach ($lang in $json.PSObject.Properties) {
        $table = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $lang.Value.PSObject.Properties) { $table[$p.Name] = $p.Value }
        $all[$lang.Name] = $table
    }
    $all
}
$Texts = Import-Texts

# Ayarlari uygular: tema, dil ve secenek degiskenleri
function Set-AppSettings($Values) {
    $script:AppSettings = [ordered]@{}
    foreach ($k in $DefaultSettings.Keys) {
        $v = $Values[$k]
        $script:AppSettings[$k] = if ($null -ne $v) { $v } else { $DefaultSettings[$k] }
    }
    $script:ClickToClose = [bool]$script:AppSettings.clickToClose
    $script:FullNotify   = [bool]$script:AppSettings.fullNotify
    $script:LowWarn      = [bool]$script:AppSettings.lowWarn
    $lang = $script:AppSettings.language
    if ($lang -ne 'tr' -and $lang -ne 'en') { $lang = if ((Get-Culture).TwoLetterISOLanguageName -eq 'tr') { 'tr' } else { 'en' } }
    $script:Txt   = $Texts[$lang]
    $script:Theme = Get-Theme $script:AppSettings.theme $script:AppSettings.custom1 $script:AppSettings.custom2
}

# ayarlar.json'u okur (yoksa / bozuksa varsayilanlar)
function Import-Settings {
    $loaded = @{}
    try {
        if (Test-Path $SettingsPath) {
            $json = [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $loaded[$p.Name] = $p.Value }
        }
    } catch { }
    Set-AppSettings $loaded
}

function Save-Settings {
    $json = [pscustomobject]$script:AppSettings | ConvertTo-Json
    [IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding $false))
}
Import-Settings

# --- Cihaz listesi (ATK HUB'dan cikarildi, bkz. tools/extract-devices.js) ---
$Devices = New-Object 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
foreach ($row in Import-Csv $DevicePath) {
    $id = "vid_$($row.vid)&pid_$($row.pid)".ToLowerInvariant()
    $Devices[$id] = [pscustomobject]@{
        Id       = $id                        # orn. vid_373b&pid_11e7
        Name     = $row.name
        Family   = $row.family
        Receiver = ($row.receiver -eq '1')    # kablosuz alici mi
        Battery  = ($row.family -eq 'COMPX')  # pil okuma protokolu destekleniyor mu
    }
}
$WatchFilter = (@($Devices.Keys | ForEach-Object { $_.Substring(0, 8) }) | Sort-Object -Unique) -join '|'   # vid_3554|vid_373b

# Aygit yolundan (orn. \\?\USB#VID_373B&PID_11E7#...) cihaz kaydini bulur
function Get-AtkDevice([string]$Path) {
    # -match kullanilmaz: Turkce sistemde 'I'.ToLower() noktasiz i oldugundan buyuk/kucuk harf eslesmesi bozulur
    $m = [regex]::Match($Path.ToLowerInvariant(), 'vid_[0-9a-f]{4}&pid_[0-9a-f]{4}')
    if ($m.Success -and $Devices.ContainsKey($m.Value)) { return $Devices[$m.Value] }
    return $null
}

# Takili ATK cihazlari (cihaz listesindekiler)
function Get-PresentAtkDevices {
    foreach ($id in [AtkHid]::PresentDevices()) { if ($Devices.ContainsKey($id)) { $Devices[$id] } }
}

# "ATK X1 Ultimate 2.0" -> "A T K   X 1   U L T I M A T E   2 . 0" (uzun adlar oldugu gibi)
function Format-DeviceTitle([string]$Name) {
    if (-not $Name) { return 'A T K' }
    $upper = $Name.ToUpperInvariant()   # Invariant: Turkce sistemde 'i' -> 'I' (noktali I degil)
    if ($upper.Length -gt 22) { return $upper }
    return (($upper.Split(' ') | ForEach-Object { $_.ToCharArray() -join ' ' }) -join '   ')
}

function Write-Log($msg) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 256KB) { Remove-Item $LogPath }   # sinirsiz buyumesin
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Add-Content -Path $LogPath -Encoding UTF8
    } catch { }
}

# Pil okuma (arka planda Task<AtkBattery> doner). Testlerde sahte okumalarla degistirilir.
$BatteryReader = { param([string]$ReadId, [int]$ReadTries) [AtkHid]::ReadBatteryAsync($ReadId, 400, $ReadTries, 250) }

function Format-Battery($b) {
    $mode = if ($b.IsCharging) { 'sarj' } else { 'desarj' }
    '%{0} {1} {2} mV' -f $b.Level, $mode, $b.VoltageMv
}

# ---------------------------------------------------------------------------
# Sarj animasyonu. Not: olay bloklari degiskenleri cagri anindaki kapsamdan cozer;
# bu yuzden fonksiyonlar arasinda ayni yerel adlar (state, timer, ...) kullanilmamali.
function Show-ChargeAnimation {
    param(
        $Device = $null,    # cihaz kaydi (Get-AtkDevice); pil buradan okunur
        $Battery = $null    # verilirse mouse'tan okumak yerine bu kullanilir (test / onizleme)
    )

    $xaml    = Expand-Template ([IO.File]::ReadAllText($XamlPath, [Text.Encoding]::UTF8)) @{ A1 = $Theme.A1; A2 = $Theme.A2; A1L = $Theme.A1L }
    $window  = [Windows.Markup.XamlReader]::Parse($xaml)
    $root    = $window.FindName('Root')
    $liquidY = $window.FindName('LiquidY')
    $pctText = $window.FindName('PctText')
    $status  = $window.FindName('StatusText')
    $frame   = New-Object Windows.Threading.DispatcherFrame
    $window.FindName('TitleText').Text = Format-DeviceTitle $(if ($Device) { $Device.Name })
    $pctText.Text = $Txt.Charging
    $status.Text  = $Txt.Cable

    $emptyY = 124.0; $fullY = 8.0
    $state  = @{ Closing = $false; Task = $null; NextRead = [datetime]::MinValue; Reads = 0
                 Shown = $null; From = 0; Target = 0; Start = [datetime]::Now; Duration = 1600 }

    # Sivi ve yuzde, gosterilen degerden yeni degere akar (ilk okumada 0'dan)
    $showLevel = {
        param($b)
        $lvl = [Math]::Max(0, [Math]::Min(100, [int]$b.Level))
        $first = ($null -eq $state.Shown)
        $state.Duration = if ($first) { 1600 } else { 900 }
        $anim = New-Object Windows.Media.Animation.DoubleAnimation(($emptyY - ($emptyY - $fullY) * $lvl / 100), [Windows.Duration]::new([TimeSpan]::FromMilliseconds($state.Duration)))
        if ($first) { $anim.From = $emptyY }
        $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'; $anim.EasingFunction = $ease
        $liquidY.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $anim)

        $low = $lvl -le $LowLevel
        $window.FindName('LiqStop1').Color   = [Windows.Media.ColorConverter]::ConvertFromString($(if ($low) { '#FF5A5A' } else { '#' + $Theme.A1 }))
        $window.FindName('LiqStop2').Color   = [Windows.Media.ColorConverter]::ConvertFromString($(if ($low) { '#FF9F43' } else { '#' + $Theme.A2 }))
        $window.FindName('WaveBBrush').Color = [Windows.Media.ColorConverter]::ConvertFromString($(if ($low) { '#FF9F43' } else { '#' + $Theme.A2 }))
        $status.Text = if ($lvl -ge 100) { $Txt.Full } elseif ($b.IsCharging) { $Txt.Charging } else { $Txt.Cable }

        $pctText.FontSize = 50
        $state.From = if ($first) { 0 } else { $state.Shown.Level }
        $state.Target = $lvl; $state.Start = [datetime]::Now
        $state.Shown = [pscustomobject]@{ Level = $lvl; IsCharging = [bool]$b.IsCharging }
        $counter.Start()
    }
    $counter = New-Object Windows.Threading.DispatcherTimer
    $counter.Interval = [TimeSpan]::FromMilliseconds(16)
    $counter.Add_Tick({
        $progress = [Math]::Min(1.0, ([datetime]::Now - $state.Start).TotalMilliseconds / $state.Duration)
        $current = $state.From + ($state.Target - $state.From) * (1 - [Math]::Pow(1 - $progress, 3))
        $pctText.Text = $Txt.Pct -f [int][Math]::Round($current)
        if ($progress -ge 1) { $counter.Stop() }
    })

    # Pil okunamazsa: surekli dolup bosalan sus animasyonu
    $showUnknown = {
        $anim = New-Object Windows.Media.Animation.DoubleAnimation($emptyY, $fullY, [Windows.Duration]::new([TimeSpan]::FromSeconds(3.6)))
        $ease = New-Object Windows.Media.Animation.SineEase; $ease.EasingMode = 'EaseInOut'; $anim.EasingFunction = $ease
        $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $liquidY.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $anim)
    }

    # Pil, pencere acik oldukca her saniye arka planda yeniden okunur. Mouse takildiktan sonra
    # bildirdigi degeri birkac saniye icinde guncelleyebilir; ATK HUB gibi son degeri gosteririz.
    $poll = New-Object Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(100)
    $poll.Add_Tick({
        if ($state.Closing) { $poll.Stop(); return }
        if ($state.Task) {
            if (-not $state.Task.IsCompleted) { return }
            $b = $state.Task.Result
            $state.Task = $null
            $state.NextRead = [datetime]::Now.AddSeconds(1)
            if ($b) {
                if (-not $Device.Receiver) { $monitor.WiredLastLevel = $b.Level }   # "sarj doldu" takibi icin
                $changed = ($null -eq $state.Shown) -or ($b.Level -ne $state.Shown.Level) -or ([bool]$b.IsCharging -ne $state.Shown.IsCharging)
                if ($changed) {
                    Write-Log "  pil: $(Format-Battery $b)"
                    & $showLevel $b
                }
            } elseif ($state.Reads -eq 1 -and $null -eq $state.Shown) {
                Write-Log '  pil okunamadi'
                & $showUnknown
            }
            return
        }
        if ([datetime]::Now -lt $state.NextRead) { return }
        $state.Reads++
        $attempts = if ($state.Reads -eq 1) { 6 } else { 1 }   # ilk okumada cihaz hazir olana kadar dene
        $state.Task = & $BatteryReader $Device.Id $attempts
    })

    $fadeOut = {
        if ($state.Closing) { return }
        $state.Closing = $true
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(450)))
        $fade.Add_Completed({ $window.Close() })
        $root.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($DisplaySeconds)
    $timer.Add_Tick({ $timer.Stop(); & $fadeOut })

    $window.Add_Loaded({
        $timer.Start()
        if ($Battery) { & $showLevel $Battery }
        elseif ($Device -and $Device.Battery) { $poll.Start() }
        else { & $showUnknown }   # bu model icin pil protokolu yok
    })
    if ($ClickToClose) { $window.Add_MouseLeftButtonDown({ $timer.Stop(); & $fadeOut }) }
    $window.Add_Closed({ $state.Closing = $true; $counter.Stop(); $poll.Stop(); $frame.Continue = $false })

    $window.Show()   # Show + frame: odagi calmaz
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---------------------------------------------------------------------------
# Bildirim balonu (sag alt, odagi calmaz, en ustte).
#   -Kind low  : dusuk pil (kirmizi)      -Kind full : sarj tamamlandi (tema rengi)
function Show-Toast([string]$Kind, [int]$Level, [string]$DeviceName) {
    $isFull = $Kind -eq 'full'
    $colors = if ($isFull) { @{ BG1 = $Theme.Dark1; BG2 = $Theme.Dark2; BORDER = $Theme.A1L } }
              else         { @{ BG1 = 'E5484D'; BG2 = '9B1C22'; BORDER = 'FFA3A3' } }
    $toast      = [Windows.Markup.XamlReader]::Parse((Expand-Template ([IO.File]::ReadAllText($ToastPath, [Text.Encoding]::UTF8)) $colors))
    $toastRoot  = $toast.FindName('ToastRoot')
    $toastSlide = $toast.FindName('ToastSlide')
    $toastFrame = New-Object Windows.Threading.DispatcherFrame
    if ($isFull) {
        $toast.FindName('IconLow').Visibility = 'Collapsed'
        $toast.FindName('IconFull').Visibility = 'Visible'
        $toast.FindName('ToastTitle').Text = $Txt.FullTitle
        $toast.FindName('ToastBody').Text  = $Txt.FullBody
    } else {
        $toast.FindName('ToastTitle').Text = $Txt.LowTitle -f $Level
        $toast.FindName('ToastBody').Text  = if ($Level -le 5) { $Txt.CriticalBody } else { $Txt.LowBody }
    }
    $toast.FindName('ToastDevice').Text = $DeviceName

    $work = [Windows.SystemParameters]::WorkArea   # gorev cubugu haric ana ekran alani
    $toast.Left = $work.Right - $toast.Width
    $toast.Top  = $work.Bottom - $toast.Height

    $toastState = @{ Closing = $false }
    $slideOut = {
        if ($toastState.Closing) { return }
        $toastState.Closing = $true
        $out = New-Object Windows.Media.Animation.DoubleAnimation($toast.Width, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(350)))
        $out.EasingFunction = New-Object Windows.Media.Animation.CubicEase
        $out.Add_Completed({ $toast.Close() })
        $toastSlide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $out)
        $toastRoot.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(350)))))
    }
    $toastTimer = New-Object Windows.Threading.DispatcherTimer
    $toastTimer.Interval = [TimeSpan]::FromSeconds($ToastSeconds)
    $toastTimer.Add_Tick({ $toastTimer.Stop(); & $slideOut })

    $toast.Add_Loaded({
        $in = New-Object Windows.Media.Animation.DoubleAnimation($toast.Width, 0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(500)))
        $back = New-Object Windows.Media.Animation.BackEase; $back.EasingMode = 'EaseOut'; $back.Amplitude = 0.3; $in.EasingFunction = $back
        $toastSlide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $in)
        $toastRoot.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(250)))))
        $bar = New-Object Windows.Media.Animation.DoubleAnimation(1, 0, [Windows.Duration]::new([TimeSpan]::FromSeconds($ToastSeconds)))
        $toast.FindName('ToastBarScale').BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $bar)
        $toastTimer.Start()
    })
    if ($ClickToClose) { $toast.Add_MouseLeftButtonDown({ $toastTimer.Stop(); & $slideOut }) }
    $toast.Add_Closed({ $toastTimer.Stop(); $toastFrame.Continue = $false })

    $toast.Show()
    $toast.Topmost = $true   # bazi tam ekran uygulamalarin ustune cikmasi icin yeniden one al
    [Windows.Threading.Dispatcher]::PushFrame($toastFrame)
}

# ---------------------------------------------------------------------------
# Pil izleme durumu.
#   Warned        : dusuk pil esikleri. Her esik bir kez uyarilir; pil esigin 5 puan ustune cikinca
#                   (ya da sarja takilinca) yeniden kurulur, boylece 19-20 dalgalanmasi tekrar uyarmaz.
#   MouseName     : alici hangi mouse'a bagli oldugunu bildirmez; en son kabloyla gorulen mouse'un adi
#   WiredLastLevel: kablodayken son okunan seviye; <100'den 100'e geciste "sarj doldu" bildirilir
$monitor = @{ Warned = @{}; Task = $null; Device = $null; NextCheck = (Get-Date).AddSeconds(15); LastLevel = $null
              MouseName = $null; WiredLastLevel = $null; FullNotified = $false }
foreach ($w in $WarnLevels) { $monitor.Warned[$w] = $false }

# Uyari gosterilmesi gerekiyorsa $true doner
function Update-LowBatteryWarnings([int]$Level, [bool]$Charging) {
    $hit = $false
    foreach ($w in $WarnLevels) {
        if ($Charging -or $Level -ge $w + 5) { $monitor.Warned[$w] = $false }
        elseif ($Level -le $w -and -not $monitor.Warned[$w]) { $monitor.Warned[$w] = $true; $hit = $true }
    }
    return $hit
}

# Ana dongude cagrilir: pili belirli araliklarla arka planda okur
#   kabloda -> %100 olunca "sarj doldu";  kablosuz -> dusuk pil uyarilari
function Invoke-BatteryMonitor {
    if ($monitor.Task) {
        if (-not $monitor.Task.IsCompleted) { return }
        $b = $monitor.Task.Result
        $dev = $monitor.Device
        $monitor.Task = $null
        # Uyuyan / bagli olmayan mouse icin alici yanit vermeyebilir ya da 0 bildirebilir: yok sayilir
        if (-not $b -or $b.Level -le 0) { return }
        if (-not $dev.Receiver) {
            $prev = $monitor.WiredLastLevel
            $monitor.WiredLastLevel = $b.Level
            if ($b.Level -ge 100 -and $null -ne $prev -and $prev -lt 100 -and -not $monitor.FullNotified) {
                $monitor.FullNotified = $true
                Write-Log "  sarj tamamlandi ($($dev.Name))"
                Show-Toast 'full' 100 $dev.Name
            }
            return
        }
        if ($b.Level -ne $monitor.LastLevel) { Write-Log "  kablosuz pil ($($dev.Name)): $(Format-Battery $b)"; $monitor.LastLevel = $b.Level }
        if (Update-LowBatteryWarnings $b.Level ([bool]$b.IsCharging)) {
            Write-Log "  dusuk pil uyarisi: %$($b.Level)"
            Show-Toast 'low' $b.Level $(if ($monitor.MouseName) { $monitor.MouseName } else { $dev.Name })
        }
        return
    }
    if ((Get-Date) -lt $monitor.NextCheck) { return }
    $monitor.NextCheck = (Get-Date).AddSeconds($CheckSeconds)
    $present = @(Get-PresentAtkDevices | Where-Object { $_.Battery })
    $wired = @($present | Where-Object { -not $_.Receiver })
    if ($wired.Count) {   # kabloda: sarj oluyor
        $monitor.MouseName = $wired[0].Name
        [void](Update-LowBatteryWarnings 100 $true)
        if (-not $FullNotify -or $monitor.FullNotified) { return }
        $monitor.Device = $wired[0]
        $monitor.Task = & $BatteryReader $wired[0].Id 2
        return
    }
    $monitor.WiredLastLevel = $null; $monitor.FullNotified = $false   # kablo cikti
    if (-not $present -or -not $LowWarn) { return }
    $monitor.Device = $present[0]
    $monitor.Task = & $BatteryReader $present[0].Id 3   # mouse bostayken alici her sorguya cevap alamayabilir
}

# ---------------------------------------------------------------------------
$loopState = @{ LastShown = [datetime]::MinValue; SettingsCheck = [datetime]::MinValue; SettingsStamp = $null }

# Bir takma olayini isler; sarj animasyonu gosterildiyse $true doner
function Invoke-Arrival([string]$DeviceName) {
    Write-Log "takildi: $DeviceName"
    if ($DeviceName.ToLowerInvariant().Contains('&mi_')) { return $false }   # alt arayuz, ana cihaz degil
    $dev = Get-AtkDevice $DeviceName
    if (-not $dev) { Write-Log '  ATK mouse listesinde yok, atlandi'; return $false }
    if ($dev.Receiver) {
        Write-Log "  kablosuz alici: $($dev.Name)"
        $monitor.NextCheck = (Get-Date).AddSeconds(5)   # pili birazdan kontrol et
        return $false
    }
    $monitor.MouseName = $dev.Name
    if (((Get-Date) - $loopState.LastShown).TotalSeconds -lt $CooldownSec) { return $false }
    [void](Update-LowBatteryWarnings 100 $true)   # sarja takildi: uyarilar yeniden kurulur
    $monitor.WiredLastLevel = $null; $monitor.FullNotified = $false
    try { Show-ChargeAnimation -Device $dev } catch { Write-Log "animasyon hatasi: $_" }
    $loopState.LastShown = Get-Date
    return $true
}

# ayarlar.json degistiyse (ayarlar penceresinden) yeniden yukler
function Update-SettingsIfChanged {
    if ((Get-Date) -lt $loopState.SettingsCheck) { return }
    $loopState.SettingsCheck = (Get-Date).AddSeconds(1)
    $stamp = if (Test-Path $SettingsPath) { (Get-Item $SettingsPath).LastWriteTimeUtc } else { $null }
    if ($stamp -ne $loopState.SettingsStamp) {
        $loopState.SettingsStamp = $stamp
        Import-Settings
        Write-Log "ayarlar: tema=$($AppSettings.theme) dil=$($AppSettings.language) dolu=$FullNotify dusuk=$LowWarn"
    }
}

# ---------------------------------------------------------------------------
# Arka plan izleyicisinin yonetimi (kontrol merkezi kullanir)

# Izleyici calisiyor mu: calisan kopya tek-kopya kilidini (mutex) tutar
function Test-WatcherRunning {
    $existing = $null
    if ([Threading.Mutex]::TryOpenExisting($MutexName, [ref]$existing)) { $existing.Dispose(); return $true }
    return $false
}

# Izleyiciyi konsol penceresi olmadan baslatir (uygulama yoksa, gelistirme icin dogrudan PowerShell)
function Start-Watcher {
    if (Test-Path -LiteralPath $ExePath) { Start-Process -FilePath $ExePath -ArgumentList '--watcher' }
    else {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f (Join-Path $AppDir 'atk-sarj.ps1'))
    }
}

# Bu klasordeki izleyiciyi durdurur (uygulama --watcher ya da dogrudan PowerShell); en fazla 5 sn bekler
function Stop-Watcher {
    $watcherScript = (Join-Path $AppDir 'atk-sarj.ps1').ToLowerInvariant()
    $exe = $ExePath.ToLowerInvariant()
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='ATK Charge Animation.exe'" |
        Where-Object {
            $cmd = "$($_.CommandLine)".ToLowerInvariant()
            $_.ProcessId -ne $PID -and ($cmd.Contains($watcherScript) -or ($cmd.Contains($exe) -and $cmd.Contains('--watcher')))
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Test-WatcherRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
}

# Uygulamayi gosteren bir kisayol yazar (her seferinde yeniden: klasor tasindiysa yeni yeri gostersin)
function Write-AppShortcut([string]$ShortcutPath, [string]$Arguments) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $ExePath
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = Split-Path $ExePath -Parent
    $lnk.IconLocation = "$ExePath,0"
    $lnk.Description = 'ATK Charge Animation'
    $lnk.Save()
}

# Windows acilisinda otomatik baslatma (Baslangic klasorundeki kisayol -> uygulama --watcher)
function Test-Autostart { return (Test-Path -LiteralPath (Join-Path $StartupDir $ShortcutName)) }

function Set-Autostart([bool]$Enabled) {
    foreach ($old in $LegacyShortcutNames) { Remove-Item -LiteralPath (Join-Path $StartupDir $old) -ErrorAction SilentlyContinue }
    $lnkPath = Join-Path $StartupDir $ShortcutName
    if ($Enabled) { Write-AppShortcut $lnkPath '--watcher' }
    else { Remove-Item -LiteralPath $lnkPath -ErrorAction SilentlyContinue }
}

# Masaustu kisayolu (kontrol merkezini acar)
function Test-DesktopShortcut { return (Test-Path -LiteralPath (Join-Path $DesktopDir $ShortcutName)) }

function Set-DesktopShortcut([bool]$Enabled) {
    $lnkPath = Join-Path $DesktopDir $ShortcutName
    if ($Enabled) { Write-AppShortcut $lnkPath '' }
    else { Remove-Item -LiteralPath $lnkPath -ErrorAction SilentlyContinue }
}

# app klasorunu gizler: kullanici klasorde yalnizca uygulamayi gorur
function Set-AppFolderHidden([bool]$Hidden) {
    $dir = Get-Item -LiteralPath $AppDir -Force
    if ($Hidden) { $dir.Attributes = $dir.Attributes -bor [IO.FileAttributes]::Hidden }
    else { $dir.Attributes = $dir.Attributes -band (-bnot [IO.FileAttributes]::Hidden) }
}

# Internetten indirilen dosyalardaki Windows engelini (Zone.Identifier) kaldirir
function Unblock-AppFiles {
    Get-ChildItem -LiteralPath $AppDir -Recurse -File -Force -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $ExePath) { Unblock-File -LiteralPath $ExePath -ErrorAction SilentlyContinue }
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-source edilirse sadece fonksiyonlari yukle

$sampleDevice = (@(Get-PresentAtkDevices | Where-Object { -not $_.Receiver }) + $Devices['vid_373b&pid_11e7'])[0]
if ($Test)        { Show-ChargeAnimation -Device (@(Get-PresentAtkDevices | Where-Object { -not $_.Receiver }) + $null)[0]; return }
if ($TestWarning) { Show-Toast 'low' 20 $sampleDevice.Name; return }
if ($TestFull)    { Show-Toast 'full' 100 $sampleDevice.Name; return }

# Tek kopya calissin
$mutex = New-Object Threading.Mutex($false, $MutexName)
if (-not $Learn) {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }   # onceki kopya zorla kapatildiysa
    if (-not $owned) { return }
}

try {
    if ($Learn) {
        $watcher = New-Object AtkDeviceWatcher ''
        Write-Host 'Ogrenme modu: mouse kablosunu takip cikar. Cikmak icin Ctrl+C.' -ForegroundColor Cyan
    } else {
        $watcher = New-Object AtkDeviceWatcher $WatchFilter
        Write-Log "izleme basladi (PID $PID, $($Devices.Count) cihaz)"
    }

    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(200)
    $tick.Add_Tick({
        $tick.Stop()   # animasyon / balon acikken (ic ice dongu) yeniden girilmesin
        try {
            $arrived = $watcher.TakeArrival()
            if ($arrived) {
                if ($Learn) { Write-Host $arrived }
                elseif (Invoke-Arrival $arrived) { while ($watcher.TakeArrival()) { } }   # animasyon sirasinda birikenleri at
            }
            elseif (-not $Learn) { Update-SettingsIfChanged; Invoke-BatteryMonitor }
        }
        catch { Write-Log "HATA: $_" }
        finally { $tick.Start() }
    })
    $tick.Start()
    [Windows.Threading.Dispatcher]::Run()   # Windows mesajlarini pompalar (takma bildirimi buradan gelir)
} catch {
    Write-Log "HATA: $_"
    throw
}

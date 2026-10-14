<#
  Kontrol merkezi (programin tek giris noktasi: ..\ATK Charge Animation.exe).
  Arka plan izleyicisini baslatir / durdurur, Windows acilisinda baslatmayi yonetir;
  renk temasi, bildirimler, dil. Ayarlar hemen ayarlar.json'a kaydedilir ve izleyici 1 sn icinde uygular.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'atk-sarj.ps1')   # fonksiyonlar, temalar, metinler, kayitli ayarlar

$SettingsXamlPath = Join-Path $PSScriptRoot 'ayarlar.xaml'
$TestMode = [bool]$env:ATK_TEST   # testlerde gercek sisteme (Baslangic, calisan izleyici) dokunulmaz

# Kurulum. Ilk acilista otomatik baslatma acilir ve izleyici baslar; kullanicinin sonraki secimlerine dokunulmaz.
# setupVersion: tek seferlik adimlar (masaustu kisayolu, app klasorunu gizleme) eski surumden gelenlere de bir kez uygulanir.
$SetupVersion = 2
$firstRun = -not (Test-Path $SettingsPath)
if (-not $TestMode) {
    Unblock-AppFiles   # ZIP'ten cikan dosyalardaki "internetten indirildi" engeli
    # Var olan kisayollar uygulamayi gostersin (klasor tasindiysa ya da eski surumden kaldiysa)
    if (Test-Autostart) { Set-Autostart $true }
    if (Test-DesktopShortcut) { Set-DesktopShortcut $true }
    if ([int]$AppSettings.setupVersion -lt $SetupVersion) {
        if ($firstRun) { Set-Autostart $true }
        Set-DesktopShortcut $true
        Set-AppFolderHidden $true
        $AppSettings['setupVersion'] = $SetupVersion
        Save-Settings
        if ((Test-Autostart) -and -not (Test-WatcherRunning)) { Start-Watcher }   # ilk acilis ya da eski surumden guncelleme
    }
}

# {{t:anahtar}} -> metin (XML icin kacisli), {{A1}} / {{A2}} -> tema renkleri
$settingsXaml = [IO.File]::ReadAllText($SettingsXamlPath, [Text.Encoding]::UTF8)
$settingsXaml = [regex]::Replace($settingsXaml, '\{\{t:(\w+)\}\}', { param($m) [Security.SecurityElement]::Escape([string]$Txt[$m.Groups[1].Value]) })
$win = [Windows.Markup.XamlReader]::Parse((Expand-Template $settingsXaml @{ A1 = $Theme.A1; A2 = $Theme.A2 }))
function Get-Ui([string]$Name) { $win.FindName($Name) }

function ConvertTo-Color([string]$Hex, [int]$Alpha = 255) {
    [Windows.Media.Color]::FromArgb($Alpha, [Convert]::ToByte($Hex.Substring(0, 2), 16), [Convert]::ToByte($Hex.Substring(2, 2), 16), [Convert]::ToByte($Hex.Substring(4, 2), 16))
}
function New-Brush([string]$Hex, [int]$Alpha = 255) { New-Object Windows.Media.SolidColorBrush (ConvertTo-Color $Hex $Alpha) }
function New-GradientBrush([string]$Hex1, [string]$Hex2) { New-Object Windows.Media.LinearGradientBrush((ConvertTo-Color $Hex1), (ConvertTo-Color $Hex2), 45.0) }

# Pencerenin vurgu renkleri ve tema secimi gorunumu
$swatchRings = @{}
function Update-SettingsView {
    # [Brush] donusumu: kaynak sozlugu her nesneyi kabul ettiginden PowerShell sarmalayicisi (PSObject) saklanmasin
    $win.Resources['Accent']         = [Windows.Media.Brush](New-Brush $Theme.A1)
    $win.Resources['AccentSoft']     = [Windows.Media.Brush](New-Brush $Theme.A1 0x26)
    $win.Resources['AccentGradient'] = [Windows.Media.Brush](New-GradientBrush $Theme.A1 $Theme.A2)
    foreach ($ringKey in $swatchRings.Keys) { $swatchRings[$ringKey].Opacity = if ($ringKey -eq $AppSettings.theme) { 1 } else { 0 } }
    (Get-Ui 'CustomPanel').Visibility = if ($AppSettings.theme -eq 'custom') { 'Visible' } else { 'Collapsed' }
}

# Bir ayari degistirir, kaydeder ve gorunumu gunceller
function Set-Option([string]$Key, $Value) {
    $AppSettings[$Key] = $Value
    Set-AppSettings $AppSettings
    Save-Settings
    Update-SettingsView
}

# --- Tema ornekleri -----------------------------------------------------------
$customDot = $null
foreach ($themeKey in @($Themes.Keys) + 'custom') {
    $pair = if ($themeKey -eq 'custom') { @($AppSettings.custom1, $AppSettings.custom2) } else { $Themes[$themeKey] }
    if (-not (Test-HexColor $pair[0]) -or -not (Test-HexColor $pair[1])) { $pair = $Themes['neon'] }

    $circle = New-Object Windows.Controls.Grid
    $circle.Width = 46; $circle.Height = 46
    $ring = New-Object Windows.Shapes.Ellipse
    $ring.Stroke = New-Brush 'FFFFFF'; $ring.StrokeThickness = 2; $ring.Opacity = 0
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 34; $dot.Height = 34; $dot.Fill = New-GradientBrush $pair[0] $pair[1]
    [void]$circle.Children.Add($ring); [void]$circle.Children.Add($dot)
    if ($themeKey -eq 'custom') { $customDot = $dot }

    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Txt["theme_$themeKey"]; $label.FontSize = 12; $label.Margin = '0,6,0,0'
    $label.HorizontalAlignment = 'Center'; $label.Foreground = New-Brush 'E8EDF2'

    $content = New-Object Windows.Controls.StackPanel
    [void]$content.Children.Add($circle); [void]$content.Children.Add($label)

    $swatch = New-Object Windows.Controls.Button
    $swatch.Style = $win.FindResource('Swatch'); $swatch.Content = $content; $swatch.Tag = $themeKey
    $swatch.ToolTip = $label.Text
    $swatch.Add_Click({ Set-Option 'theme' $this.Tag })
    [void](Get-Ui 'ThemePanel').Children.Add($swatch)
    $swatchRings[$themeKey] = $ring
}

# --- Ozel renkler -------------------------------------------------------------
function Update-CustomColor([string]$Key, $Box, $Preview) {
    $typed = $Box.Text.Trim().TrimStart('#')
    if (Test-HexColor $typed) {
        $Box.BorderBrush = New-Brush '26313D'; $Box.ToolTip = $null
        $Preview.Background = New-Brush $typed
        Set-Option $Key $typed.ToUpperInvariant()
        $customDot.Fill = New-GradientBrush $AppSettings.custom1 $AppSettings.custom2
    } else {
        $Box.BorderBrush = New-Brush 'E5484D'; $Box.ToolTip = $Txt.invalidColor
    }
}
foreach ($n in 1, 2) {
    $hexBox = Get-Ui "Custom${n}Box"
    $hexBox.Text = '#' + $AppSettings["custom$n"]
    (Get-Ui "Custom${n}Preview").Background = New-Brush $(if (Test-HexColor $AppSettings["custom$n"]) { $AppSettings["custom$n"] } else { '39FF88' })
    $hexBox.Tag = $n
    $hexBox.Add_TextChanged({ Update-CustomColor "custom$($this.Tag)" $this (Get-Ui "Custom$($this.Tag)Preview") })
}

# --- Bildirim secenekleri -------------------------------------------------------
$options = @{ FullNotifyBox = 'fullNotify'; LowWarnBox = 'lowWarn'; ClickBox = 'clickToClose' }
foreach ($boxName in $options.Keys) {
    $check = Get-Ui $boxName
    $check.IsChecked = [bool]$AppSettings[$options[$boxName]]
    $check.Tag = $options[$boxName]
    $check.Add_Click({ Set-Option $this.Tag ([bool]$this.IsChecked) })
}

# --- Dil ----------------------------------------------------------------------
$langs = @{ LangAuto = 'auto'; LangTr = 'tr'; LangEn = 'en' }
foreach ($radioName in $langs.Keys) {
    $radio = Get-Ui $radioName
    $radio.IsChecked = ($AppSettings.language -eq $langs[$radioName])
    $radio.Tag = $langs[$radioName]
    $radio.Add_Checked({ Set-Option 'language' $this.Tag })
}

# --- Dene dugmeleri -------------------------------------------------------------
function Get-SampleMouse {
    (@(Get-PresentAtkDevices | Where-Object { -not $_.Receiver }) + $Devices['vid_373b&pid_11e7'])[0]
}
(Get-Ui 'TryCharge').Add_Click({
    $mouse = @(Get-PresentAtkDevices | Where-Object { -not $_.Receiver -and $_.Battery })
    if ($mouse.Count) { Show-ChargeAnimation -Device $mouse[0] }   # takili mouse: gercek pil
    else { Show-ChargeAnimation -Device (Get-SampleMouse) -Battery ([pscustomobject]@{ Level = 65; IsCharging = $true }) }
})
(Get-Ui 'TryLow').Add_Click({ Show-Toast 'low' 18 (Get-SampleMouse).Name })
(Get-Ui 'TryFull').Add_Click({ Show-Toast 'full' 100 (Get-SampleMouse).Name })

# --- Durum: arka plan izleyicisi ----------------------------------------------------
function Update-StatusView {
    $running = Test-WatcherRunning
    (Get-Ui 'StatusDot').Fill    = [Windows.Media.Brush](New-Brush $(if ($running) { '39D98A' } else { '5A6573' }))
    (Get-Ui 'StatusText').Text   = if ($running) { $Txt.statusRunning } else { $Txt.statusStopped }
    (Get-Ui 'StatusSub').Text    = if ($running) { $Txt.statusRunningSub } else { $Txt.statusStoppedSub }
    (Get-Ui 'ServiceButton').Content = if ($running) { $Txt.btnStop } else { $Txt.btnStart }
    (Get-Ui 'ServiceButton').Tag = $running
}
(Get-Ui 'ServiceButton').Add_Click({
    if ($this.Tag) { Stop-Watcher } else { Start-Watcher }
    Update-StatusView   # baslarken kilidin alinmasi bir an surebilir; zamanlayici birazdan yeniler
})
$statusTimer = New-Object Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(1)
$statusTimer.Add_Tick({ Update-StatusView })

# --- Genel: Windows acilisinda baslat ------------------------------------------------
$autoBox = Get-Ui 'AutostartBox'
$autoBox.IsChecked = Test-Autostart
$autoBox.Add_Click({ Set-Autostart ([bool]$this.IsChecked); $this.IsChecked = Test-Autostart })

# --- Kayit dosyasi ve kaldirma -------------------------------------------------------
(Get-Ui 'OpenLogButton').Add_Click({
    if (Test-Path $LogPath) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $LogPath) }
    else { [void][Windows.MessageBox]::Show($win, $Txt.noLog, $Txt.settingsTitle) }
})
(Get-Ui 'UninstallButton').Add_Click({
    $answer = [Windows.MessageBox]::Show($win, $Txt.uninstallConfirm, $Txt.settingsTitle, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Set-Autostart $false
    Set-DesktopShortcut $false
    Stop-Watcher
    Set-AppFolderHidden $false   # silinecek klasorun tamami gorunsun
    Remove-Item -LiteralPath $SettingsPath -ErrorAction SilentlyContinue   # tekrar acilirsa ilk kurulum gibi davransin
    [void][Windows.MessageBox]::Show($win, $Txt.uninstallDone, $Txt.settingsTitle, 'OK', 'Information')
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Split-Path $AppDir -Parent))   # silinecek klasoru goster
    $win.Close()
})

# --- Pencere ------------------------------------------------------------------
$iconPath = Join-Path $AppDir 'icon.png'
if (Test-Path $iconPath) { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) }
(Get-Ui 'TitleBar').Add_MouseLeftButtonDown({ $win.DragMove() })
(Get-Ui 'CloseButton').Add_Click({ $win.Close() })
$win.Add_KeyDown({ if ($_.Key -eq 'Escape') { $win.Close() } })
$win.Add_Closed({ $statusTimer.Stop() })

Update-SettingsView
Update-StatusView
$statusTimer.Start()
[void]$win.ShowDialog()

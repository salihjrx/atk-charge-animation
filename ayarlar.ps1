<#
  Ayarlar penceresi: renk temasi, bildirimler, dil.
  Degisiklikler hemen ayarlar.json'a kaydedilir; arka planda calisan izleyici 1 sn icinde uygular.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'atk-sarj.ps1')   # fonksiyonlar, temalar, metinler, kayitli ayarlar

$SettingsXamlPath = Join-Path $PSScriptRoot 'ayarlar.xaml'

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

# --- Pencere ------------------------------------------------------------------
(Get-Ui 'TitleBar').Add_MouseLeftButtonDown({ $win.DragMove() })
(Get-Ui 'CloseButton').Add_Click({ $win.Close() })
$win.Add_KeyDown({ if ($_.Key -eq 'Escape') { $win.Close() } })

Update-SettingsView
[void]$win.ShowDialog()

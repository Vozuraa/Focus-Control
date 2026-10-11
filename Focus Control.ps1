$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'FocusTelemetry.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'FocusAudio.cs')

$script:SettingsPath = Join-Path $PSScriptRoot 'focus-settings.json'
$script:Config = [ordered]@{
    ShowSeconds = $false
    Translucency = $false
    Opacity = 0.86
    OverlayTranslucency = $true
    OverlayBackgroundOpacity = 0.46
    PinClock = $false
    OverlayPosition = 'TopLeft'
    ReducedMotion = $false
    TimerDurationMinutes = 25
    TimerRemainingSeconds = 0
    OverlayWidgets = @('clock', 'fps', 'gpu', 'ram', 'cpu', 'temp')
    DashboardGauges = @('cpu', 'gpu', 'ram')
    AccentTheme = 'Lilac'
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $loaded = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:Config.Keys)) {
            $property = $loaded.PSObject.Properties[$key]
            if ($null -ne $property -and $null -ne $property.Value) {
                $script:Config[$key] = $property.Value
            }
        }
    }
    catch {
        # Keep safe defaults if a previous settings file is damaged.
    }
}

$script:WidgetDefinitions = [ordered]@{
    clock = @{ Name = 'Heure'; Detail = 'Heure locale' }
    fps = @{ Name = 'FPS'; Detail = 'Jeu au premier plan' }
    gpu = @{ Name = 'GPU'; Detail = 'Utilisation graphique' }
    ram = @{ Name = 'RAM'; Detail = 'Mémoire consommée' }
    cpu = @{ Name = 'CPU'; Detail = 'Charge du processeur' }
    temp = @{ Name = 'Température GPU'; Detail = 'Capteur NVIDIA' }
}
$script:AllWidgetIds = @($script:WidgetDefinitions.Keys)
$script:ActiveWidgets = [System.Collections.ArrayList]::new()
foreach ($id in @($script:Config.OverlayWidgets)) {
    $id = [string]$id
    if ($script:WidgetDefinitions.Contains($id) -and -not $script:ActiveWidgets.Contains($id)) {
        [void]$script:ActiveWidgets.Add($id)
    }
}
$script:TimerDurationMinutes = [Math]::Max(1, [Math]::Min(999, [int]$script:Config.TimerDurationMinutes))
$script:TimerRemainingSeconds = [Math]::Max(0, [Math]::Min(59940, [int]$script:Config.TimerRemainingSeconds))
$script:TimerRunning = $false
$script:TimerPanelOpen = ($script:TimerRemainingSeconds -gt 0)
$script:TimerWasOpen = $false
$script:TimerDeadline = [DateTime]::UtcNow
$script:FpsCapture = [FocusFpsCapture]::new()
$script:FpsAttempted = $false
$script:TrackedProcessId = 0
$script:TrackedProcessName = ''
$script:LatestFps = -1
$script:LatestSample = [FocusSensors]::Read()
$script:TargetValues = @{ cpu = -1.0; gpu = -1.0; ram = -1.0 }
$script:DisplayedValues = @{ cpu = 0.0; gpu = 0.0; ram = 0.0 }
$script:PreviewValues = @{}
$script:OverlayValues = @{}
$script:DragWidgetId = $null
$script:DragStart = [System.Windows.Point]::new(0, 0)
$script:CurrentPage = 'dashboard'
$script:CustomizeSection = 'overlay'
$script:LastNavTop = $null
$script:LastSliderMotion = @{}
$script:MicroWindow = $null
$script:MicroTimer = $null
$script:MicroMeter = $null
$script:MicroUi = @{}
$script:MicroBars = [System.Collections.ArrayList]::new()
$script:BrushConverter = [System.Windows.Media.BrushConverter]::new()

function Get-Brush([string]$color) {
    return $script:BrushConverter.ConvertFromString($color)
}

function Load-XamlWindow([string]$path) {
    $source = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$source)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

try {
    $script:MainWindow = Load-XamlWindow (Join-Path $PSScriptRoot 'Focus Control.xaml')
    $script:OverlayWindow = Load-XamlWindow (Join-Path $PSScriptRoot 'Focus Overlay.xaml')
}
catch {
    [System.Windows.MessageBox]::Show("Focus Control n'a pas pu charger son interface :`n$($_.Exception.Message)", 'Focus Control') | Out-Null
    throw
}

$names = @(
    'NavDashboard', 'NavCustomize', 'NavSettings', 'NavLicense', 'NavIndicatorCanvas', 'NavIndicator',
    'DashboardPage', 'CustomizePage', 'SettingsPage', 'LicensePage',
    'MinimizeButton', 'CloseButton', 'DragHandle', 'SidebarStatus',
    'AppSurface', 'SidebarSurface', 'ClockSurface', 'OverlayCustomizeSurface',
    'DashboardCustomizeSurface', 'DisplaySettingsSurface', 'OverlaySettingsSurface',
    'ClockLabel', 'HourTens', 'HourOnes', 'MinuteTens', 'MinuteOnes', 'SecondTens', 'SecondOnes', 'SecondsPanel',
    'TimerOpenButton', 'TimerSurface',
    'DashboardGaugePanel', 'DashboardEmptyHint', 'CpuCard', 'GpuCard', 'RamCard',
    'CpuArc', 'GpuArc', 'RamArc', 'CpuPercentText', 'GpuPercentText', 'RamPercentText',
    'CpuDetail', 'GpuDetail', 'RamDetail', 'GpuTempInGauge',
    'TimerSetupPanel', 'TimerActivePanel', 'TimerMinutesBox', 'TimerTimeText',
    'TimerStartButton', 'TimerPauseButton', 'TimerStopButton', 'TimerRemoveButton',
    'CustomizeSubtitle', 'CustomizeHint', 'CustomizeOverlayButton', 'CustomizeDashboardButton',
    'OverlayCustomizePanel', 'DashboardCustomizePanel',
    'DashboardCpuToggle', 'DashboardGpuToggle', 'DashboardRamToggle',
    'AccentIce', 'AccentLilac', 'AccentSteel',
    'PreviewCpuCard', 'PreviewGpuCard', 'PreviewRamCard',
    'PreviewClock', 'PreviewCpuRing', 'PreviewGpuRing', 'PreviewRamRing',
    'PreviewSurface', 'PreviewWidgetHost', 'ActiveWidgetPanel', 'InactiveWidgetPanel',
    'ActiveDropZone', 'InactiveDropZone',
    'SecondsToggle', 'TransparencyToggle', 'OpacitySlider', 'MotionToggle',
    'PinToggle', 'PositionTopLeft', 'PositionTopRight', 'PositionBottomLeft', 'PositionBottomRight',
    'OverlayTranslucencyToggle', 'OverlayOpacitySlider'
)
$script:Ui = @{}
foreach ($name in $names) {
    $element = $script:MainWindow.FindName($name)
    if ($null -eq $element) { throw "Élément d'interface introuvable : $name" }
    $script:Ui[$name] = $element
}
$script:OverlayHost = $script:OverlayWindow.FindName('OverlayWidgetHost')
$script:OverlaySurface = $script:OverlayWindow.FindName('OverlaySurface')
$script:PositionChoices = @(
    $script:Ui.PositionTopLeft,
    $script:Ui.PositionTopRight,
    $script:Ui.PositionBottomLeft,
    $script:Ui.PositionBottomRight
)

$script:Ui.SecondsToggle.IsChecked = [bool]$script:Config.ShowSeconds
$script:Ui.TransparencyToggle.IsChecked = [bool]$script:Config.Translucency
$script:Ui.MotionToggle.IsChecked = [bool]$script:Config.ReducedMotion
$script:Ui.PinToggle.IsChecked = [bool]$script:Config.PinClock
$script:Ui.OverlayTranslucencyToggle.IsChecked = [bool]$script:Config.OverlayTranslucency
$script:Ui.OverlayOpacitySlider.Value = [Math]::Max(0.12, [Math]::Min(0.92, [double]$script:Config.OverlayBackgroundOpacity))
$script:Ui.OverlayOpacitySlider.IsEnabled = [bool]$script:Config.OverlayTranslucency
$script:Ui.OpacitySlider.Value = [Math]::Max(0.62, [Math]::Min(0.98, [double]$script:Config.Opacity))
$script:Ui.OpacitySlider.IsEnabled = [bool]$script:Config.Translucency
$script:MainWindow.Opacity = 1.0
$script:Ui.TimerMinutesBox.Text = [string]$script:TimerDurationMinutes
$script:Ui.DashboardCpuToggle.IsChecked = @($script:Config.DashboardGauges) -contains 'cpu'
$script:Ui.DashboardGpuToggle.IsChecked = @($script:Config.DashboardGauges) -contains 'gpu'
$script:Ui.DashboardRamToggle.IsChecked = @($script:Config.DashboardGauges) -contains 'ram'
foreach ($name in @('AccentIce','AccentLilac','AccentSteel')) {
    if ($script:Ui[$name].Tag -eq [string]$script:Config.AccentTheme) { $script:Ui[$name].IsChecked = $true }
}
if (-not (@($script:Ui.AccentIce,$script:Ui.AccentLilac,$script:Ui.AccentSteel) | Where-Object IsChecked)) {
    $script:Ui.AccentLilac.IsChecked = $true
}
foreach ($choice in $script:PositionChoices) {
    if ($choice.Tag -eq [string]$script:Config.OverlayPosition) { $choice.IsChecked = $true }
}
if (-not ($script:PositionChoices | Where-Object { $_.IsChecked })) {
    $script:PositionChoices[0].IsChecked = $true
}

function Get-SelectedPosition {
    foreach ($choice in $script:PositionChoices) {
        if ($choice.IsChecked) { return [string]$choice.Tag }
    }
    return 'TopLeft'
}

function Get-DashboardGauges {
    $visible = @()
    if ($script:Ui.DashboardCpuToggle.IsChecked) { $visible += 'cpu' }
    if ($script:Ui.DashboardGpuToggle.IsChecked) { $visible += 'gpu' }
    if ($script:Ui.DashboardRamToggle.IsChecked) { $visible += 'ram' }
    return $visible
}

function Get-AccentTheme {
    foreach ($choice in @($script:Ui.AccentIce,$script:Ui.AccentLilac,$script:Ui.AccentSteel)) {
        if ($choice.IsChecked) { return [string]$choice.Tag }
    }
    return 'Lilac'
}

function Apply-AccentTheme {
    $theme = Get-AccentTheme
    $accent = switch ($theme) {
        'Ice' { '#FFE3EBF4' }
        'Steel' { '#FF9DAFC4' }
        default { '#FFD3A4FF' }
    }
    $ring = switch ($theme) {
        'Ice' { '#FFFFFFFF' }
        'Steel' { '#FFD6E0EB' }
        default { '#FFF2E8FC' }
    }
    $script:Ui.NavIndicator.Background = Get-Brush $accent
    $script:Ui.TimerOpenButton.BorderBrush = Get-Brush $accent
    $script:Ui.ClockLabel.Foreground = Get-Brush $accent
    $script:Ui.PreviewClock.Foreground = Get-Brush $accent
    foreach ($name in @('PreviewCpuRing','PreviewGpuRing','PreviewRamRing')) {
        $script:Ui[$name].Stroke = Get-Brush $accent
    }
    $ringBrush = $script:MainWindow.Resources['RingBrush']
    if (-not $ringBrush.IsFrozen) {
        $ringBrush.GradientStops[0].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($accent)
        $ringBrush.GradientStops[1].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($ring)
        $ringBrush.GradientStops[2].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($accent)
    }
}

function Apply-DashboardGauges {
    $gauges = @(Get-DashboardGauges)
    foreach ($id in @('cpu','gpu','ram')) {
        $name = $id.Substring(0,1).ToUpper() + $id.Substring(1)
        $shown = $gauges -contains $id
        $script:Ui[($name + 'Card')].Visibility = if ($shown) { 'Visible' } else { 'Collapsed' }
        $script:Ui[('Preview' + $name + 'Card')].Opacity = if ($shown) { 1.0 } else { 0.23 }
    }
    $script:Ui.DashboardGaugePanel.Columns = [Math]::Max(1, $gauges.Count)
    $script:Ui.DashboardGaugePanel.Visibility = if ($gauges.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $script:Ui.DashboardEmptyHint.Visibility = if ($gauges.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    if ($null -ne $script:GaugeTick) {
        if ($script:CurrentPage -eq 'dashboard' -and $gauges.Count -gt 0) { $script:GaugeTick.Start() }
        else { $script:GaugeTick.Stop() }
    }
}

function Apply-OverlayAppearance {
    $translucent = [bool]$script:Ui.OverlayTranslucencyToggle.IsChecked
    $opacity = if ($translucent) { [double]$script:Ui.OverlayOpacitySlider.Value } else { 0.88 }
    $alpha = [byte][Math]::Round($opacity * 255)
    $color = [System.Windows.Media.Color]::FromArgb($alpha, [byte]18, [byte]22, [byte]28)
    $brush = [System.Windows.Media.SolidColorBrush]::new($color)
    $script:OverlaySurface.Background = $brush
    $script:Ui.PreviewSurface.Background = $brush
    $script:Ui.OverlayOpacitySlider.IsEnabled = $translucent
}

function Apply-MainOpacity {
    $opacity = if ($script:Ui.TransparencyToggle.IsChecked) { [double]$script:Ui.OpacitySlider.Value } else { 1.0 }
    $surfaces = @{
        AppSurface = @(13,15,19); SidebarSurface = @(21,24,29); DragHandle = @(17,20,25)
        ClockSurface = @(23,27,33); CpuCard = @(24,28,34); GpuCard = @(24,28,34)
        RamCard = @(24,28,34); TimerSurface = @(23,27,32)
        OverlayCustomizeSurface = @(23,27,32); DashboardCustomizeSurface = @(23,27,32)
        DisplaySettingsSurface = @(23,27,33); OverlaySettingsSurface = @(23,27,33)
        ActiveDropZone = @(29,34,41); InactiveDropZone = @(22,26,31)
    }
    foreach ($name in $surfaces.Keys) {
        $rgb = $surfaces[$name]
        $alpha = [byte][Math]::Round(255 * $opacity)
        $script:Ui[$name].Background = [System.Windows.Media.SolidColorBrush]::new(
            [System.Windows.Media.Color]::FromArgb($alpha, [byte]$rgb[0], [byte]$rgb[1], [byte]$rgb[2]))
    }
}

function Animate-SliderThumb($slider, [double]$oldValue, [double]$newValue) {
    if ($script:Ui.MotionToggle.IsChecked -or $oldValue -eq $newValue) { return }
    try {
        [void]$slider.ApplyTemplate()
        $track = $slider.Template.FindName('PART_Track', $slider)
        if ($null -eq $track -or $null -eq $track.Thumb) { return }
        $thumb = $track.Thumb
        [void]$thumb.ApplyTemplate()
        $knob = $thumb.Template.FindName('Knob', $thumb)
        if ($null -ne $knob) {
            $knob.RenderTransformOrigin = [System.Windows.Point]::new($(if ($newValue -gt $oldValue) { 0 } else { 1 }), 0.5)
            $now = [DateTime]::UtcNow.Ticks
            $key = $slider.Name
            if ($script:LastSliderMotion.ContainsKey($key) -and
                ($now - $script:LastSliderMotion[$key]) -lt [TimeSpan]::FromMilliseconds(100).Ticks) { return }
            $script:LastSliderMotion[$key] = $now
            $transform = $knob.RenderTransform
            if ($transform.IsFrozen) {
                $transform = [System.Windows.Media.ScaleTransform]::new(1, 1)
                $knob.RenderTransform = $transform
            }
            $action = [Action]{
                try {
                    $pulse = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
                    Add-NavKeyframe $pulse 1.0 0
                    Add-NavKeyframe $pulse 1.22 75
                    Add-NavKeyframe $pulse 1.0 190
                    $transform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
                }
                catch { }
            }.GetNewClosure()
            [void]$slider.Dispatcher.BeginInvoke($action, [System.Windows.Threading.DispatcherPriority]::Background)
        }
    }
    catch { }
}

function Get-TimerRemaining {
    if ($script:TimerRunning) {
        return [Math]::Max(0, [int][Math]::Ceiling(($script:TimerDeadline - [DateTime]::UtcNow).TotalSeconds))
    }
    return [int]$script:TimerRemainingSeconds
}

function Save-FocusSettings {
    $minutes = $script:TimerDurationMinutes
    $parsedMinutes = 0
    if ([int]::TryParse($script:Ui.TimerMinutesBox.Text, [ref]$parsedMinutes)) {
        $minutes = [Math]::Max(1, [Math]::Min(999, $parsedMinutes))
    }
    $saved = [ordered]@{
        ShowSeconds = [bool]$script:Ui.SecondsToggle.IsChecked
        Translucency = [bool]$script:Ui.TransparencyToggle.IsChecked
        Opacity = [Math]::Round([double]$script:Ui.OpacitySlider.Value, 2)
        OverlayTranslucency = [bool]$script:Ui.OverlayTranslucencyToggle.IsChecked
        OverlayBackgroundOpacity = [Math]::Round([double]$script:Ui.OverlayOpacitySlider.Value, 2)
        PinClock = [bool]$script:Ui.PinToggle.IsChecked
        OverlayPosition = Get-SelectedPosition
        ReducedMotion = [bool]$script:Ui.MotionToggle.IsChecked
        TimerDurationMinutes = [int]$minutes
        TimerRemainingSeconds = Get-TimerRemaining
        OverlayWidgets = @($script:ActiveWidgets.ToArray())
        DashboardGauges = @(Get-DashboardGauges)
        AccentTheme = Get-AccentTheme
    }
    try {
        $json = $saved | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        $script:Ui.SidebarStatus.Text = 'Réglages non enregistrés'
    }
}

$script:SettingsSaveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:SettingsSaveTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:SettingsSaveTimer.Add_Tick({
    $script:SettingsSaveTimer.Stop()
    Save-FocusSettings
})
function Queue-SettingsSave {
    $script:SettingsSaveTimer.Stop()
    $script:SettingsSaveTimer.Start()
}

function Set-ClockDigit([string]$name, [string]$digit, [bool]$seconds) {
    $element = $script:Ui[$name]
    if ($element.Text -eq $digit) { return }
    $element.Text = $digit
    if (-not $script:MainWindow.IsLoaded -or $script:Ui.MotionToggle.IsChecked) { return }
    $duration = if ($seconds) { 135 } else { 190 }
    $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(0.66, 1.0,
        [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($duration)))
    $slide = [System.Windows.Media.Animation.DoubleAnimation]::new(2.0, 0.0,
        [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($duration)))
    $element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $transform = $element.RenderTransform
    if ($transform.IsFrozen) {
        $transform = [System.Windows.Media.TranslateTransform]::new()
        $element.RenderTransform = $transform
    }
    $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Update-Clock {
    $now = [DateTime]::Now
    $digits = $now.ToString('HHmmss')
    $names = @('HourTens','HourOnes','MinuteTens','MinuteOnes','SecondTens','SecondOnes')
    for ($index = 0; $index -lt $names.Count; $index++) {
        Set-ClockDigit $names[$index] ([string]$digits[$index]) ($index -ge 4)
    }
    $visibility = if ($script:Ui.SecondsToggle.IsChecked) { 'Visible' } else { 'Collapsed' }
    if ([string]$script:Ui.SecondsPanel.Visibility -ne $visibility) {
        $script:Ui.SecondsPanel.Visibility = $visibility
    }
}

function Format-Timer([int]$seconds) {
    $minutes = [Math]::Floor($seconds / 60)
    return ('{0:00}:{1:00}' -f $minutes, ($seconds % 60))
}

function Update-TimerView {
    $remaining = Get-TimerRemaining
    $script:Ui.TimerTimeText.Text = Format-Timer $remaining
    if ($script:TimerPanelOpen -ne $script:TimerWasOpen) {
        $surface = $script:Ui.TimerSurface
        $opening = [bool]$script:TimerPanelOpen
        $script:TimerWasOpen = $opening
        if ($opening) { $surface.Visibility = 'Visible' }
        $script:Ui.TimerOpenButton.Background = Get-Brush $(if ($opening) { '#FF3A3442' } else { '#FF262B32' })
        if ($script:MainWindow.IsLoaded -and -not $script:Ui.MotionToggle.IsChecked) {
            $height = [System.Windows.Media.Animation.DoubleAnimation]::new(
                $(if ($opening) { 0.0 } else { 55.0 }), $(if ($opening) { 55.0 } else { 0.0 }),
                [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
            $height.EasingFunction = [System.Windows.Media.Animation.CubicEase]::new()
            $height.EasingFunction.EasingMode = 'EaseOut'
            $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(
                $(if ($opening) { 0.0 } else { 1.0 }), $(if ($opening) { 1.0 } else { 0.0 }),
                [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
            if (-not $opening) {
                $height.Add_Completed({
                    if (-not $script:TimerPanelOpen) {
                        $script:Ui.TimerSurface.Visibility = 'Collapsed'
                        $script:Ui.TimerSurface.Height = 0
                        $script:Ui.TimerSurface.Opacity = 0
                    }
                })
            }
            $surface.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $height)
            $surface.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        }
        else {
            $surface.Height = if ($opening) { 55 } else { 0 }
            $surface.Opacity = if ($opening) { 1 } else { 0 }
            if (-not $opening) { $surface.Visibility = 'Collapsed' }
        }
    }
    if ($remaining -gt 0) {
        $script:Ui.TimerSetupPanel.Visibility = 'Collapsed'
        $script:Ui.TimerActivePanel.Visibility = 'Visible'
        $script:Ui.TimerPauseButton.Content = if ($script:TimerRunning) { 'Pause' } else { 'Reprendre' }
        $script:Ui.TimerPauseButton.IsEnabled = $true
    }
    else {
        $script:Ui.TimerSetupPanel.Visibility = 'Visible'
        $script:Ui.TimerActivePanel.Visibility = 'Collapsed'
    }
}

function Add-NavKeyframe($animation, [double]$value, [int]$milliseconds) {
    $frame = [System.Windows.Media.Animation.EasingDoubleKeyFrame]::new()
    $frame.Value = $value
    $frame.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($milliseconds))
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = 'EaseInOut'
    $frame.EasingFunction = $ease
    [void]$animation.KeyFrames.Add($frame)
}

function Move-NavIndicator([string]$page, [bool]$animate) {
    $nav = @{dashboard=$script:Ui.NavDashboard; customize=$script:Ui.NavCustomize; settings=$script:Ui.NavSettings; license=$script:Ui.NavLicense}[$page]
    if (-not $script:MainWindow.IsLoaded -or $nav.ActualHeight -le 0) { return }
    $point = $nav.TranslatePoint([System.Windows.Point]::new(0,0), $script:Ui.NavIndicatorCanvas)
    $target = $point.Y + ($nav.ActualHeight - 23.0) / 2.0
    $indicator = $script:Ui.NavIndicator
    if ($null -eq $script:LastNavTop -or -not $animate -or $script:Ui.MotionToggle.IsChecked) {
        $indicator.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $null)
        $indicator.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
        [System.Windows.Controls.Canvas]::SetTop($indicator, $target)
        $indicator.Height = 23
    }
    else {
        $from = [System.Windows.Controls.Canvas]::GetTop($indicator)
        if ([Math]::Abs($target - $from) -lt 1) { return }
        $distance = $target - $from
        $stretch = [Math]::Min(13, [Math]::Abs($distance) * 0.18)
        $midTop = if ($distance -gt 0) { $from + $distance * 0.48 } else { $from + $distance * 0.48 - $stretch }
        $midHeight = 23 + $stretch
        $topAnimation = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
        Add-NavKeyframe $topAnimation $from 0
        Add-NavKeyframe $topAnimation $midTop 105
        Add-NavKeyframe $topAnimation $target 235
        $heightAnimation = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
        Add-NavKeyframe $heightAnimation 23 0
        Add-NavKeyframe $heightAnimation $midHeight 105
        Add-NavKeyframe $heightAnimation 23 235
        $indicator.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $topAnimation)
        $indicator.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $heightAnimation)
    }
    $script:LastNavTop = $target
}

function New-ArcGeometry([double]$value) {
    if ($value -le 0.1) { return [System.Windows.Media.Geometry]::Empty }
    $amount = [Math]::Min(99.999, [Math]::Max(0.0, $value))
    $angle = (-90.0 + 360.0 * $amount / 100.0) * [Math]::PI / 180.0
    $end = [System.Windows.Point]::new(
        78.0 + 68.0 * [Math]::Cos($angle),
        78.0 + 68.0 * [Math]::Sin($angle)
    )
    $figure = [System.Windows.Media.PathFigure]::new()
    $figure.StartPoint = [System.Windows.Point]::new(78, 10)
    $figure.IsClosed = $false
    $figure.IsFilled = $false
    $segment = [System.Windows.Media.ArcSegment]::new()
    $segment.Point = $end
    $segment.Size = [System.Windows.Size]::new(68, 68)
    $segment.IsLargeArc = ($amount -gt 50)
    $segment.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    [void]$figure.Segments.Add($segment)
    $geometry = [System.Windows.Media.PathGeometry]::new()
    [void]$geometry.Figures.Add($figure)
    return $geometry
}

function Set-GaugeTarget([string]$id, [double]$value) {
    $script:TargetValues[$id] = $value
}

function Render-Gauge([string]$id, [string]$pathName, [string]$textName) {
    $target = [double]$script:TargetValues[$id]
    if ($target -lt 0) {
        if ($script:Ui[$textName].Text -ne '--') {
            $script:Ui[$pathName].Data = [System.Windows.Media.Geometry]::Empty
            $script:Ui[$textName].Text = '--'
        }
        return
    }
    $current = [double]$script:DisplayedValues[$id]
    if ($current -eq $target) { return }
    if ($script:Ui.MotionToggle.IsChecked) {
        $current = $target
    }
    else {
        $current += ($target - $current) * 0.5
        if ([Math]::Abs($target - $current) -lt 0.2) { $current = $target }
    }
    $script:DisplayedValues[$id] = $current
    $script:Ui[$pathName].Data = New-ArcGeometry $current
    $script:Ui[$textName].Text = ('{0:0}%' -f [Math]::Round($current))
}

function Apply-SensorSample {
    $sample = $script:LatestSample
    Set-GaugeTarget 'cpu' $sample.CpuPercent
    Set-GaugeTarget 'gpu' $sample.GpuPercent
    Set-GaugeTarget 'ram' $sample.RamPercent
    $script:Ui.GpuDetail.Text = $sample.GpuName
    if ($sample.GpuTemperatureC -ge 0) {
        $script:Ui.GpuTempInGauge.Text = ('{0:0} °C' -f $sample.GpuTemperatureC)
    }
    else { $script:Ui.GpuTempInGauge.Text = '-- °C' }
    if ($sample.RamTotalGiB -gt 0) {
        $script:Ui.RamDetail.Text = ('{0:N1} / {1:N1} Go' -f $sample.RamUsedGiB, $sample.RamTotalGiB)
    }
    $script:Ui.CpuDetail.Text = 'Charge globale'
}

function Get-WidgetValue([string]$id) {
    $sample = $script:LatestSample
    switch ($id) {
        'clock' { return [DateTime]::Now.ToString('HH:mm') }
        'fps' {
            if ($script:FpsCapture.IsRunning -and $script:FpsCapture.TargetProcessId -gt 0 -and $script:LatestFps -ge 0) {
                return ('{0} FPS' -f $script:LatestFps)
            }
            return '—'
        }
        'gpu' { if ($sample.GpuPercent -ge 0) { return ('{0:0} %' -f $sample.GpuPercent) }; return '—' }
        'ram' {
            if ($sample.RamPercent -ge 0) { return ('{0:N1} Go · {1:0} %' -f $sample.RamUsedGiB, $sample.RamPercent) }
            return '—'
        }
        'cpu' { if ($sample.CpuPercent -ge 0) { return ('{0:0} %' -f $sample.CpuPercent) }; return '—' }
        'temp' { if ($sample.GpuTemperatureC -ge 0) { return ('{0:0} °C' -f $sample.GpuTemperatureC) }; return '—' }
    }
    return '—'
}

function New-WidgetVisual([string]$id, [hashtable]$store) {
    if ($id -eq 'clock') {
        $time = [System.Windows.Controls.TextBlock]::new()
        $time.Text = Get-WidgetValue $id
        $time.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
        $time.FontSize = 30
        $time.FontWeight = [System.Windows.FontWeights]::SemiBold
        $time.Foreground = Get-Brush '#FFF4F7FA'
        $time.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        $store[$id] = $time
        return $time
    }
    $labels = @{ fps = 'FPS'; gpu = 'GPU'; ram = 'RAM'; cpu = 'CPU'; temp = 'TEMP GPU' }
    $row = [System.Windows.Controls.Grid]::new()
    $row.Height = 25
    $row.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
    $leftColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $leftColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $rightColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $rightColumn.Width = [System.Windows.GridLength]::Auto
    [void]$row.ColumnDefinitions.Add($leftColumn)
    [void]$row.ColumnDefinitions.Add($rightColumn)
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.Text = $labels[$id]
    $label.FontSize = 10
    $label.FontWeight = [System.Windows.FontWeights]::Bold
    $label.Foreground = Get-Brush '#FF9DA8B5'
    $label.VerticalAlignment = 'Center'
    $value = [System.Windows.Controls.TextBlock]::new()
    $value.Text = Get-WidgetValue $id
    $value.FontSize = 12
    $value.FontWeight = [System.Windows.FontWeights]::SemiBold
    $value.Foreground = Get-Brush '#FFF1F5F8'
    $value.HorizontalAlignment = 'Right'
    $value.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($value, 1)
    [void]$row.Children.Add($label)
    [void]$row.Children.Add($value)
    $store[$id] = $value
    return $row
}

function Refresh-WidgetValues {
    foreach ($id in @($script:ActiveWidgets)) {
        $value = Get-WidgetValue $id
        if ($script:PreviewValues.ContainsKey($id)) { $script:PreviewValues[$id].Text = $value }
        if ($script:OverlayValues.ContainsKey($id)) { $script:OverlayValues[$id].Text = $value }
    }
}

function Update-OverlayPosition {
    $work = [System.Windows.SystemParameters]::WorkArea
    $gap = 18
    $position = Get-SelectedPosition
    if ($position -eq 'TopRight' -or $position -eq 'BottomRight') {
        $script:OverlayWindow.Left = $work.Right - $script:OverlayWindow.Width - $gap
    }
    else { $script:OverlayWindow.Left = $work.Left + $gap }
    if ($position -eq 'BottomLeft' -or $position -eq 'BottomRight') {
        $script:OverlayWindow.Top = $work.Bottom - $script:OverlayWindow.Height - $gap
    }
    else { $script:OverlayWindow.Top = $work.Top + $gap }
}

function Rebuild-WidgetViews {
    $script:Ui.PreviewWidgetHost.Children.Clear()
    $script:OverlayHost.Children.Clear()
    $script:PreviewValues = @{}
    $script:OverlayValues = @{}
    $height = 24
    foreach ($id in @($script:ActiveWidgets)) {
        [void]$script:Ui.PreviewWidgetHost.Children.Add((New-WidgetVisual $id $script:PreviewValues))
        [void]$script:OverlayHost.Children.Add((New-WidgetVisual $id $script:OverlayValues))
        if ($id -eq 'clock') { $height += 52 } else { $height += 27 }
    }
    if ($script:ActiveWidgets.Count -eq 0) {
        $hint = [System.Windows.Controls.TextBlock]::new()
        $hint.Text = 'Glissez une carte ici.'
        $hint.Foreground = Get-Brush '#FF9AA5B1'
        $hint.TextWrapping = 'Wrap'
        [void]$script:Ui.PreviewWidgetHost.Children.Add($hint)
    }
    $script:OverlayWindow.Height = [Math]::Max(56, $height)
    Update-OverlayPosition
    Refresh-WidgetValues
}

function Apply-Pin {
    $pinned = [bool]$script:Ui.PinToggle.IsChecked -and $script:ActiveWidgets.Count -gt 0
    if ($pinned) {
        Update-OverlayPosition
        if (-not $script:OverlayWindow.IsVisible) { $script:OverlayWindow.Show() }
    }
    elseif ($script:OverlayWindow.IsVisible) {
        $script:OverlayWindow.Hide()
    }
}

function Set-CustomizeSection([string]$section) {
    $script:CustomizeSection = $section
    $overlay = $section -eq 'overlay'
    $script:Ui.OverlayCustomizePanel.Visibility = if ($overlay) { 'Visible' } else { 'Collapsed' }
    $script:Ui.DashboardCustomizePanel.Visibility = if ($overlay) { 'Collapsed' } else { 'Visible' }
    $script:Ui.CustomizeOverlayButton.Background = Get-Brush $(if ($overlay) { '#FF3B3547' } else { '#FF262B32' })
    $script:Ui.CustomizeDashboardButton.Background = Get-Brush $(if ($overlay) { '#FF262B32' } else { '#FF3B3547' })
    $script:Ui.CustomizeSubtitle.Text = if ($overlay) { 'Composez votre assistant flottant' } else { "Composez votre vue d'ensemble" }
    $script:Ui.CustomizeHint.Text = if ($overlay) {
        "Glissez une carte entre les zones ou utilisez son bouton. Glissez dans la liste pour changer l'ordre."
    }
    else { 'Choisissez les jauges à garder sur la page principale.' }
}

function Set-Page([string]$page) {
    $script:CurrentPage = $page
    $pages = @{ dashboard = $script:Ui.DashboardPage; customize = $script:Ui.CustomizePage; settings = $script:Ui.SettingsPage; license = $script:Ui.LicensePage }
    $navigation = @{ dashboard = $script:Ui.NavDashboard; customize = $script:Ui.NavCustomize; settings = $script:Ui.NavSettings; license = $script:Ui.NavLicense }
    foreach ($key in $pages.Keys) {
        $pages[$key].Visibility = if ($key -eq $page) { 'Visible' } else { 'Collapsed' }
        $navigation[$key].Tag = if ($key -eq $page) { 'Active' } else { '' }
        $navigation[$key].Background = if ($key -eq $page) { Get-Brush '#FF303944' } else { Get-Brush 'Transparent' }
        $navigation[$key].Foreground = if ($key -eq $page) { Get-Brush '#FFF3F6F9' } else { Get-Brush '#FFC4CAD2' }
    }
    Move-NavIndicator $page $true
    if ($null -ne $script:GaugeTick) {
        if ($page -eq 'dashboard' -and @(Get-DashboardGauges).Count -gt 0) { $script:GaugeTick.Start() }
        else { $script:GaugeTick.Stop() }
    }
    if (-not $script:Ui.MotionToggle.IsChecked) {
        $target = $pages[$page]
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new()
        $fade.From = 0.4
        $fade.To = 1.0
        $fade.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(170))
        $target.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    }
}

function Resolve-FpsTarget {
    $processId = 0
    $foregroundId = [FocusWindows]::ForegroundProcessId()
    if ($foregroundId -gt 0 -and $foregroundId -ne $PID) {
        try {
            $foreground = [System.Diagnostics.Process]::GetProcessById($foregroundId)
            if ($foreground.ProcessName -notin @('explorer', 'dwm', 'SearchHost', 'ShellExperienceHost',
                    'ChatGPT', 'Codex', 'powershell', 'pwsh', 'WindowsTerminal', 'ApplicationFrameHost')) {
                $script:TrackedProcessId = $foregroundId
                $script:TrackedProcessName = $foreground.ProcessName
            }
        }
        catch { }
    }
    if ($script:TrackedProcessId -gt 0) {
        try { [void][System.Diagnostics.Process]::GetProcessById($script:TrackedProcessId); $processId = $script:TrackedProcessId }
        catch { $script:TrackedProcessId = 0; $script:TrackedProcessName = '' }
    }
    $script:FpsCapture.SetTargetProcessId($processId)
}

function Update-FpsStatus {
    if (-not $script:ActiveWidgets.Contains('fps')) {
        $status = 'Ajoutez FPS dans Personnaliser pour activer la capture.'
    }
    elseif (-not $script:Ui.PinToggle.IsChecked) {
        $status = 'Épinglez la superposition pour lancer la capture FPS.'
    }
    elseif ($script:FpsCapture.IsRunning) {
        if ($script:FpsCapture.TargetProcessId -gt 0) {
            $status = 'Capture active : ' + $script:TrackedProcessName
        }
        else { $status = 'Capture active. Ouvrez un jeu.' }
    }
    elseif ($script:FpsAttempted) {
        if (-not [FocusWindows]::IsAdministrator()) {
            $status = 'Accès FPS refusé. Lancez Focus Control en administrateur.'
        }
        else {
            $status = 'Capture FPS indisponible : ' + $script:FpsCapture.LastError
        }
    }
    else { $status = 'Capture prête à démarrer.' }
    $script:FpsStatus = $status
}

function Sync-FpsCapture {
    $wanted = [bool]$script:Ui.PinToggle.IsChecked -and $script:ActiveWidgets.Contains('fps')
    if (-not $wanted) {
        if ($script:FpsCapture.IsRunning) { $script:FpsCapture.Stop() }
        $script:FpsAttempted = $false
        $script:LatestFps = -1
    }
    elseif (-not $script:FpsAttempted) {
        $script:FpsAttempted = $true
        $binary = Join-Path $PSScriptRoot 'tools\PresentMon-2.3.1-x64.exe'
        if (Test-Path -LiteralPath $binary) {
            $script:FpsCapture.Start($binary)
        }
    }
    Update-FpsStatus
}

function Stop-MicroTest {
    if ($null -ne $script:MicroTimer) { $script:MicroTimer.Stop() }
    if ($null -ne $script:MicroMeter) {
        $script:MicroMeter.Dispose()
        $script:MicroMeter = $null
    }
    if ($script:MicroUi.ContainsKey('MicroTestButton')) {
        $script:MicroUi.MicroTestButton.Content = 'Démarrer le test'
    }
}

function Open-MicroTest {
    if ($null -ne $script:MicroWindow -and $script:MicroWindow.IsVisible) {
        $script:MicroWindow.Activate() | Out-Null
        return
    }
    try { $script:MicroWindow = Load-XamlWindow (Join-Path $PSScriptRoot 'Focus Micro.xaml') }
    catch {
        [System.Windows.MessageBox]::Show("Le test micro n'a pas pu s'ouvrir :`n$($_.Exception.Message)", 'Focus Control') | Out-Null
        return
    }
    $script:MicroWindow.Owner = $script:MainWindow
    $script:MicroUi = @{}
    foreach ($name in @('MicroCloseButton','MicroDeviceList','MicroPeakText','MicroStatusText','MicroBarHost','MicroTestButton')) {
        $script:MicroUi[$name] = $script:MicroWindow.FindName($name)
    }
    $script:MicroBars.Clear()
    foreach ($index in 0..27) {
        $bar = [System.Windows.Controls.Border]::new()
        $bar.Width = 7
        $bar.Height = 4
        $bar.CornerRadius = [System.Windows.CornerRadius]::new(3)
        $bar.Background = Get-Brush '#FFC5A8DD'
        $bar.Margin = [System.Windows.Thickness]::new(2,0,2,0)
        $bar.VerticalAlignment = 'Bottom'
        [void]$script:MicroUi.MicroBarHost.Children.Add($bar)
        [void]$script:MicroBars.Add($bar)
    }
    $devices = [FocusMicrophoneMeter]::ListDevices()
    foreach ($device in $devices) { [void]$script:MicroUi.MicroDeviceList.Items.Add($device) }
    if ($devices.Count -gt 0) {
        $preferred = @($devices | Where-Object IsDefault | Select-Object -First 1)
        $script:MicroUi.MicroDeviceList.SelectedItem = if ($preferred.Count -gt 0) { $preferred[0] } else { $devices[0] }
    }
    else {
        $script:MicroUi.MicroStatusText.Text = 'Aucun microphone actif trouvé.'
        $script:MicroUi.MicroTestButton.IsEnabled = $false
    }
    $script:MicroTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:MicroTimer.Interval = [TimeSpan]::FromMilliseconds(110)
    $script:MicroTimer.Add_Tick({
        if ($null -eq $script:MicroMeter) { return }
        $peak = $script:MicroMeter.ReadPeak()
        if ($peak -lt 0) {
            Stop-MicroTest
            $script:MicroUi.MicroStatusText.Text = 'Le microphone ne répond plus.'
            return
        }
        for ($index = 0; $index -lt $script:MicroBars.Count - 1; $index++) {
            $script:MicroBars[$index].Height = $script:MicroBars[$index + 1].Height
        }
        $visualPeak = [Math]::Min(1.0, [Math]::Sqrt($peak) * 1.25)
        $script:MicroBars[$script:MicroBars.Count - 1].Height = 4 + [Math]::Round(62 * $visualPeak)
        $script:MicroUi.MicroPeakText.Text = ('{0:0} %' -f (100 * $peak))
    })
    $script:MicroUi.MicroDeviceList.Add_SelectionChanged({
        if ($null -ne $script:MicroMeter) {
            Stop-MicroTest
            $script:MicroUi.MicroStatusText.Text = 'Microphone modifié. Relancez le test.'
        }
    })
    $script:MicroUi.MicroTestButton.Add_Click({
        if ($null -ne $script:MicroMeter) {
            Stop-MicroTest
            $script:MicroUi.MicroStatusText.Text = 'Test arrêté. Aucun son enregistré.'
            return
        }
        $selected = $script:MicroUi.MicroDeviceList.SelectedItem
        if ($null -eq $selected) { return }
        $script:MicroMeter = [FocusMicrophoneMeter]::new()
        if (-not $script:MicroMeter.Select($selected.Id)) {
            Stop-MicroTest
            $script:MicroUi.MicroStatusText.Text = "Impossible d'ouvrir ce microphone."
            return
        }
        $script:MicroUi.MicroTestButton.Content = 'Arrêter le test'
        $script:MicroUi.MicroStatusText.Text = 'Parlez : les barres montrent le niveau en direct.'
        $script:MicroTimer.Start()
    })
    $script:MicroUi.MicroCloseButton.Add_Click({ $script:MicroWindow.Close() })
    $script:MicroWindow.Add_Closing({ Stop-MicroTest })
    $script:MicroWindow.Show()
}

function Move-Widget([string]$id, [string]$destination, [string]$beforeId) {
    if (-not $script:WidgetDefinitions.Contains($id)) { return }
    if ($destination -ne 'active' -and $destination -ne 'inactive') { return }
    if ($destination -eq 'active' -and $id -eq $beforeId) { return }
    [void]$script:ActiveWidgets.Remove($id)
    if ($destination -eq 'active') {
        $index = if ($beforeId) { $script:ActiveWidgets.IndexOf($beforeId) } else { -1 }
        if ($index -ge 0) { $script:ActiveWidgets.Insert($index, $id) }
        else { [void]$script:ActiveWidgets.Add($id) }
    }
    Rebuild-WidgetTiles
    Rebuild-WidgetViews
    Apply-Pin
    Sync-FpsCapture
    Save-FocusSettings
}

function New-WidgetTile([string]$id, [string]$zone) {
    $tile = [System.Windows.Controls.Border]::new()
    $tile.Tag = "$zone|$id"
    $tile.Height = 51
    $tile.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $tile.Padding = [System.Windows.Thickness]::new(9, 3, 7, 3)
    $tile.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $tile.Background = Get-Brush $(if ($zone -eq 'active') { '#FF2C333C' } else { '#FF242930' })
    $tile.BorderBrush = Get-Brush '#39FFFFFF'
    $tile.BorderThickness = [System.Windows.Thickness]::new(1)
    $tile.AllowDrop = $true

    $grid = [System.Windows.Controls.Grid]::new()
    $handleColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $handleColumn.Width = [System.Windows.GridLength]::new(29)
    $textColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $textColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $actionColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $actionColumn.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($handleColumn)
    [void]$grid.ColumnDefinitions.Add($textColumn)
    [void]$grid.ColumnDefinitions.Add($actionColumn)

    $handle = [System.Windows.Controls.Border]::new()
    $handle.Tag = $id
    $handle.Background = Get-Brush 'Transparent'
    $handle.Cursor = [System.Windows.Input.Cursors]::SizeAll
    $dots = [System.Windows.Controls.TextBlock]::new()
    $dots.Text = '⋮⋮'
    $dots.FontSize = 16
    $dots.Foreground = Get-Brush '#FF9FAAB6'
    $dots.VerticalAlignment = 'Center'
    $dots.HorizontalAlignment = 'Center'
    $handle.Child = $dots

    $description = [System.Windows.Controls.StackPanel]::new()
    $description.VerticalAlignment = 'Center'
    $nameText = [System.Windows.Controls.TextBlock]::new()
    $nameText.Text = $script:WidgetDefinitions[$id].Name
    $nameText.FontSize = 12
    $nameText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $nameText.Foreground = Get-Brush '#FFEAF0F6'
    $detailText = [System.Windows.Controls.TextBlock]::new()
    $detailText.Text = $script:WidgetDefinitions[$id].Detail
    $detailText.FontSize = 10
    $detailText.Foreground = Get-Brush '#FF94A0AC'
    [void]$description.Children.Add($nameText)
    [void]$description.Children.Add($detailText)
    [System.Windows.Controls.Grid]::SetColumn($description, 1)

    $action = [System.Windows.Controls.Button]::new()
    $action.Tag = "$zone|$id"
    $action.Content = if ($zone -eq 'active') { 'Retirer' } else { 'Ajouter' }
    $action.Style = $script:MainWindow.Resources['ActionButton']
    $action.Padding = [System.Windows.Thickness]::new(9, 5, 9, 5)
    $action.FontSize = 10
    $action.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($action, 2)

    [void]$grid.Children.Add($handle)
    [void]$grid.Children.Add($description)
    [void]$grid.Children.Add($action)
    $tile.Child = $grid

    $handle.Add_PreviewMouseLeftButtonDown({
        param($sender, $eventArgs)
        $script:DragWidgetId = [string]$sender.Tag
        $script:DragStart = $eventArgs.GetPosition($script:MainWindow)
    })
    $handle.Add_MouseMove({
        param($sender, $eventArgs)
        if ($eventArgs.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        if ($script:DragWidgetId -ne [string]$sender.Tag) { return }
        $point = $eventArgs.GetPosition($script:MainWindow)
        if ([Math]::Abs($point.X - $script:DragStart.X) -lt 5 -and
            [Math]::Abs($point.Y - $script:DragStart.Y) -lt 5) { return }
        $data = [System.Windows.DataObject]::new('FocusWidget', [string]$sender.Tag)
        [void][System.Windows.DragDrop]::DoDragDrop($sender, $data, [System.Windows.DragDropEffects]::Move)
        $script:DragWidgetId = $null
    })
    $action.Add_Click({
        param($sender, $eventArgs)
        $parts = ([string]$sender.Tag).Split('|')
        $destination = if ($parts[0] -eq 'active') { 'inactive' } else { 'active' }
        Move-Widget $parts[1] $destination ''
    })
    $tile.Add_DragOver({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent('FocusWidget')) {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::Move
            $eventArgs.Handled = $true
        }
    })
    $tile.Add_Drop({
        param($sender, $eventArgs)
        if (-not $eventArgs.Data.GetDataPresent('FocusWidget')) { return }
        $parts = ([string]$sender.Tag).Split('|')
        $dragged = [string]$eventArgs.Data.GetData('FocusWidget')
        Move-Widget $dragged $parts[0] $parts[1]
        $eventArgs.Handled = $true
    })
    return $tile
}

function Rebuild-WidgetTiles {
    $script:Ui.ActiveWidgetPanel.Children.Clear()
    $script:Ui.InactiveWidgetPanel.Children.Clear()
    foreach ($id in @($script:ActiveWidgets)) {
        [void]$script:Ui.ActiveWidgetPanel.Children.Add((New-WidgetTile $id 'active'))
    }
    foreach ($id in $script:AllWidgetIds) {
        if (-not $script:ActiveWidgets.Contains($id)) {
            [void]$script:Ui.InactiveWidgetPanel.Children.Add((New-WidgetTile $id 'inactive'))
        }
    }
    if ($script:Ui.ActiveWidgetPanel.Children.Count -eq 0) {
        $hint = [System.Windows.Controls.TextBlock]::new()
        $hint.Text = 'Glissez ici les éléments à afficher.'
        $hint.Foreground = Get-Brush '#FF9BA6B2'
        $hint.Margin = [System.Windows.Thickness]::new(7)
        [void]$script:Ui.ActiveWidgetPanel.Children.Add($hint)
    }
    if ($script:Ui.InactiveWidgetPanel.Children.Count -eq 0) {
        $hint = [System.Windows.Controls.TextBlock]::new()
        $hint.Text = 'Tous les éléments sont affichés.'
        $hint.Foreground = Get-Brush '#FF9BA6B2'
        $hint.Margin = [System.Windows.Thickness]::new(7)
        [void]$script:Ui.InactiveWidgetPanel.Children.Add($hint)
    }
}

foreach ($zone in @($script:Ui.ActiveDropZone, $script:Ui.InactiveDropZone)) {
    $zone.Tag = if ($zone -eq $script:Ui.ActiveDropZone) { 'active' } else { 'inactive' }
    $zone.Add_DragEnter({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent('FocusWidget')) {
            $sender.BorderBrush = Get-Brush '#FFD7E2EE'
        }
    })
    $zone.Add_DragLeave({
        param($sender, $eventArgs)
        $sender.BorderBrush = Get-Brush $(if ($sender.Tag -eq 'active') { '#45FFFFFF' } else { '#30FFFFFF' })
    })
    $zone.Add_DragOver({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent('FocusWidget')) {
            $eventArgs.Effects = [System.Windows.DragDropEffects]::Move
            $eventArgs.Handled = $true
        }
    })
    $zone.Add_Drop({
        param($sender, $eventArgs)
        if (-not $eventArgs.Data.GetDataPresent('FocusWidget')) { return }
        $dragged = [string]$eventArgs.Data.GetData('FocusWidget')
        Move-Widget $dragged ([string]$sender.Tag) ''
        $sender.BorderBrush = Get-Brush $(if ($sender.Tag -eq 'active') { '#45FFFFFF' } else { '#30FFFFFF' })
        $eventArgs.Handled = $true
    })
}

$script:OverlayWindow.Add_SourceInitialized({
    $interop = [System.Windows.Interop.WindowInteropHelper]::new($script:OverlayWindow)
    [FocusWindows]::MakeClickThrough($interop.Handle)
})

$script:Ui.DragHandle.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        $script:MainWindow.DragMove()
    }
})
$script:Ui.MinimizeButton.Add_Click({ $script:MainWindow.WindowState = 'Minimized' })
$script:Ui.CloseButton.Add_Click({ $script:MainWindow.Close() })
$script:Ui.NavDashboard.Add_Click({ Set-Page 'dashboard' })
$script:Ui.NavCustomize.Add_Click({ Set-Page 'customize' })
$script:Ui.NavSettings.Add_Click({ Set-Page 'settings' })
$script:Ui.NavLicense.Add_Click({ Set-Page 'license' })
$script:Ui.CustomizeOverlayButton.Add_Click({ Set-CustomizeSection 'overlay' })
$script:Ui.CustomizeDashboardButton.Add_Click({ Set-CustomizeSection 'dashboard' })
foreach ($toggle in @($script:Ui.DashboardCpuToggle,$script:Ui.DashboardGpuToggle,$script:Ui.DashboardRamToggle)) {
    $toggle.Add_Checked({ Apply-DashboardGauges; Save-FocusSettings })
    $toggle.Add_Unchecked({ Apply-DashboardGauges; Save-FocusSettings })
}
foreach ($accent in @($script:Ui.AccentIce,$script:Ui.AccentLilac,$script:Ui.AccentSteel)) {
    $accent.Add_Checked({ Apply-AccentTheme; Save-FocusSettings })
}

$script:Ui.SecondsToggle.Add_Click({
    Update-Clock
    Save-FocusSettings
})
$script:Ui.TransparencyToggle.Add_Click({
    $script:Ui.OpacitySlider.IsEnabled = [bool]$script:Ui.TransparencyToggle.IsChecked
    Apply-MainOpacity
    Save-FocusSettings
})
$script:Ui.OpacitySlider.Add_ValueChanged({
    param($sender, $eventArgs)
    Animate-SliderThumb $sender $eventArgs.OldValue $eventArgs.NewValue
    if ($script:Ui.TransparencyToggle.IsChecked) {
        Apply-MainOpacity
        Queue-SettingsSave
    }
})
$script:Ui.OverlayTranslucencyToggle.Add_Checked({
    Apply-OverlayAppearance
    Save-FocusSettings
})
$script:Ui.OverlayTranslucencyToggle.Add_Unchecked({
    Apply-OverlayAppearance
    Save-FocusSettings
})
$script:Ui.OverlayOpacitySlider.Add_ValueChanged({
    param($sender, $eventArgs)
    Animate-SliderThumb $sender $eventArgs.OldValue $eventArgs.NewValue
    Apply-OverlayAppearance
    Queue-SettingsSave
})
$script:Ui.MotionToggle.Add_Click({ Save-FocusSettings })
$script:Ui.PinToggle.Add_Click({
    Apply-Pin
    Sync-FpsCapture
    Save-FocusSettings
})
foreach ($choice in $script:PositionChoices) {
    $choice.Add_Checked({
        Update-OverlayPosition
        Save-FocusSettings
    })
}
$script:Ui.TimerOpenButton.Add_Click({
    $script:TimerPanelOpen = -not $script:TimerPanelOpen
    Update-TimerView
})

$script:Ui.TimerStartButton.Add_Click({
    $minutes = $script:TimerDurationMinutes
    $parsed = 0
    if ([int]::TryParse($script:Ui.TimerMinutesBox.Text, [ref]$parsed)) {
        $minutes = [Math]::Max(1, [Math]::Min(999, $parsed))
    }
    $script:TimerDurationMinutes = $minutes
    $script:Ui.TimerMinutesBox.Text = [string]$minutes
    $script:TimerRemainingSeconds = $minutes * 60
    $script:TimerDeadline = [DateTime]::UtcNow.AddSeconds($script:TimerRemainingSeconds)
    $script:TimerRunning = $true
    $script:TimerPanelOpen = $true
    Update-TimerView
    $script:TimerTick.Start()
    Save-FocusSettings
})
$script:Ui.TimerPauseButton.Add_Click({
    if ($script:TimerRunning) {
        $script:TimerRemainingSeconds = Get-TimerRemaining
        $script:TimerRunning = $false
        $script:TimerTick.Stop()
    }
    elseif ($script:TimerRemainingSeconds -gt 0) {
        $script:TimerDeadline = [DateTime]::UtcNow.AddSeconds($script:TimerRemainingSeconds)
        $script:TimerRunning = $true
        $script:TimerTick.Start()
    }
    Update-TimerView
    Save-FocusSettings
})
$script:Ui.TimerStopButton.Add_Click({
    $script:TimerTick.Stop()
    $script:TimerRunning = $false
    $script:TimerRemainingSeconds = $script:TimerDurationMinutes * 60
    Update-TimerView
    Save-FocusSettings
})
$script:Ui.TimerRemoveButton.Add_Click({
    $script:TimerTick.Stop()
    $script:TimerRunning = $false
    $script:TimerRemainingSeconds = 0
    $script:TimerPanelOpen = $false
    Update-TimerView
    Save-FocusSettings
})

$script:ClockTick = [System.Windows.Threading.DispatcherTimer]::new()
$script:ClockTick.Interval = [TimeSpan]::FromMilliseconds(500)
$script:ClockTick.Add_Tick({
    Update-Clock
    $time = [DateTime]::Now.ToString('HH:mm')
    if ($script:OverlayValues.ContainsKey('clock')) {
        if ($script:OverlayValues['clock'].Text -ne $time) { $script:OverlayValues['clock'].Text = $time }
    }
    if ($script:PreviewValues.ContainsKey('clock')) {
        if ($script:PreviewValues['clock'].Text -ne $time) { $script:PreviewValues['clock'].Text = $time }
    }
})
$script:SensorTick = [System.Windows.Threading.DispatcherTimer]::new()
$script:SensorTick.Interval = [TimeSpan]::FromSeconds(2)
$script:SensorTick.Add_Tick({
    $script:LatestSample = [FocusSensors]::Read()
    Apply-SensorSample
    if ($script:FpsCapture.IsRunning) {
        Resolve-FpsTarget
        $script:LatestFps = $script:FpsCapture.GetFps()
    }
    else { $script:LatestFps = -1 }
    Refresh-WidgetValues
    Update-FpsStatus
})
$script:GaugeTick = [System.Windows.Threading.DispatcherTimer]::new()
$script:GaugeTick.Interval = [TimeSpan]::FromMilliseconds(120)
$script:GaugeTick.Add_Tick({
    if ($script:Ui.DashboardPage.Visibility -eq 'Visible') {
        Render-Gauge 'cpu' 'CpuArc' 'CpuPercentText'
        Render-Gauge 'gpu' 'GpuArc' 'GpuPercentText'
        Render-Gauge 'ram' 'RamArc' 'RamPercentText'
    }
})
$script:TimerTick = [System.Windows.Threading.DispatcherTimer]::new()
$script:TimerTick.Interval = [TimeSpan]::FromMilliseconds(500)
$script:TimerTick.Add_Tick({
    if (-not $script:TimerRunning) { return }
    $remaining = Get-TimerRemaining
    if ($remaining -le 0) {
        $script:TimerRunning = $false
        $script:TimerRemainingSeconds = 0
        $script:TimerTick.Stop()
        Save-FocusSettings
    }
    Update-TimerView
})

Update-Clock
Update-TimerView
Apply-MainOpacity
Apply-OverlayAppearance
Apply-DashboardGauges
Apply-AccentTheme
Apply-SensorSample
Rebuild-WidgetTiles
Rebuild-WidgetViews
Set-CustomizeSection 'overlay'
Set-Page 'dashboard'
Update-FpsStatus

$script:MainWindow.Add_Loaded({
    $script:ClockTick.Start()
    $script:SensorTick.Start()
    Move-NavIndicator $script:CurrentPage $false
    if ($script:CurrentPage -eq 'dashboard' -and @(Get-DashboardGauges).Count -gt 0) { $script:GaugeTick.Start() }
    Apply-Pin
    Sync-FpsCapture
})
$script:MainWindow.Add_Closing({
    $script:SettingsSaveTimer.Stop()
    Save-FocusSettings
    if ($null -ne $script:MicroWindow -and $script:MicroWindow.IsVisible) { $script:MicroWindow.Close() }
    $script:ClockTick.Stop()
    $script:SensorTick.Stop()
    $script:GaugeTick.Stop()
    $script:TimerTick.Stop()
    $script:FpsCapture.Dispose()
    [FocusSensors]::Shutdown()
    $script:OverlayWindow.Close()
})

$app = [System.Windows.Application]::new()
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
try {
    [void]$app.Run($script:MainWindow)
}
catch {
    [System.Windows.MessageBox]::Show("Focus Control a rencontré une erreur :`n$($_.Exception.Message)", 'Focus Control') | Out-Null
    throw
}

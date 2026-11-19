$script:UpdateWorker = $null
$script:AvailableUpdate = $null
$script:UpdatePromptPending = $false
$script:UpdateManual = $false
$script:UpdatePreferences = Get-UpdatePreferences
$script:UpdateFrequencies = @('Always', 'Weekly', 'Monthly', 'Never')
$script:UpdateFrequencyLabels = @('每次启动都提醒', '每周提醒一次', '每月提醒一次', '永不提醒')

function New-UpdateBar {
    $bar = New-Control 'FlowLayoutPanel' 'UpdateBar'
    $bar.WrapContents = $false
    $button = New-Control 'Button' 'UpdateSettings' '更新 / 设置'
    $button.AutoSize = $true
    $bar.Controls.Add($button)
    $label = New-Control 'Label' 'UpdateStatus' ("当前版本 $(Get-UpdateVersion)")
    $label.AutoSize = $true
    $bar.Controls.Add($label)
    return $bar
}

function New-UpdateFrequencyCombo {
    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Dock = 'Fill'
    $combo.Items.AddRange([object[]]$script:UpdateFrequencyLabels)
    $combo.SelectedIndex = [array]::IndexOf($script:UpdateFrequencies, $script:UpdatePreferences.Frequency)
    return $combo
}

function New-UpdateChoiceButtons {
    param($Dialog, [switch]$Settings)
    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Fill'
    $entries = @(@('更新', 'Yes'), @('取消', 'Cancel'), @('跳过此版本', 'Ignore'))
    if ($Settings) { $entries = @(@('检查更新', 'Yes'), @('保存', 'OK'), @('取消', 'Cancel')) }
    foreach ($entry in $entries) {
        $button = New-Object Windows.Forms.Button
        $button.Text = $entry[0]
        $button.AutoSize = $true
        $button.DialogResult = $entry[1]
        $bar.Controls.Add($button)
        if ($entry[1] -eq 'Cancel') { $Dialog.CancelButton = $button }
    }
    return $bar
}

function New-UpdateDialog {
    param([switch]$Settings)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'P4 自动合并 — 版本更新'
    $dialog.Size = New-Object Drawing.Size(760, 600)
    $dialog.MinimumSize = New-Object Drawing.Size(620, 440)
    $dialog.Font = $script:Controls.Main.Font
    $dialog.Icon = $script:Controls.Main.Icon
    $dialog.StartPosition = 'CenterParent'
    $grid = New-Object Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Fill'; $grid.Padding = New-Object Windows.Forms.Padding(12)
    $grid.RowCount = 5; $grid.ColumnCount = 1
    foreach ($height in @(65, 0, 28, 34, 42)) {
        $style = New-Object Windows.Forms.RowStyle('Absolute', $height)
        if ($height -eq 0) { $style.SizeType = 'Percent'; $style.Height = 100 }
        [void]$grid.RowStyles.Add($style)
    }
    $title = New-Object Windows.Forms.Label
    $title.Dock = 'Fill'
    $title.Text = "当前版本 $(Get-UpdateVersion)。每次启动都会检查，提醒频率仅控制自动弹窗。"
    $notes = New-Object Windows.Forms.TextBox
    $notes.Multiline = $true; $notes.ReadOnly = $true; $notes.ScrollBars = 'Vertical'; $notes.Dock = 'Fill'
    if ($script:AvailableUpdate) {
        $title.Text += "`r`n发现新版 $($script:AvailableUpdate.Version)。"
        $notes.Text = "更新日志：`r`n" + $script:AvailableUpdate.Notes
    }
    if (-not $env:P4AM_UPDATE_REQUEST) { $title.Text += "`r`n源码启动：点击更新打开下载页。" }
    elseif (-not (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($env:P4AM_EXECUTABLE)) 'unins000.exe'))) {
        $title.Text += "`r`n便携版：更新将安装新版，保留当前便携文件。"
    }
    $label = New-Object Windows.Forms.Label
    $label.Text = '提醒更新频率：'; $label.Dock = 'Fill'
    $combo = New-UpdateFrequencyCombo
    $grid.Controls.Add($title, 0, 0); $grid.Controls.Add($notes, 0, 1)
    $grid.Controls.Add($label, 0, 2); $grid.Controls.Add($combo, 0, 3)
    $grid.Controls.Add((New-UpdateChoiceButtons $dialog -Settings:$Settings), 0, 4)
    $dialog.Controls.Add($grid)
    return [pscustomobject]@{ Form = $dialog; Frequency = $combo }
}

function Show-UpdateSettings {
    $dialog = New-UpdateDialog -Settings
    try {
        $choice = $dialog.Form.ShowDialog($script:Controls.Main)
        if ($choice -eq 'Cancel') { return }
        $script:UpdatePreferences.Frequency = $script:UpdateFrequencies[$dialog.Frequency.SelectedIndex]
        Save-UpdatePreferences $script:UpdatePreferences
        if ($choice -eq 'Yes') { Start-UpdateOperation 'Check' -Manual }
    }
    catch { Set-UpdateError $_.Exception.Message }
    finally { $dialog.Form.Dispose() }
}

function Set-UpdateError {
    param([string]$Message)
    $script:Controls.UpdateStatus.Text = '更新未完成：' + $Message
    $script:Controls.Log.AppendText("`r`n[更新] $Message`r`n")
}

function Start-UpdateOperation {
    param([string]$Action, [switch]$Manual)
    if ($script:UpdateWorker) { return }
    if ($Action -eq 'Download' -and -not (Test-UpdateCanInstall ([bool]$script:Worker) $script:Session)) {
        Set-UpdateError '请先完成或结束当前合并队列，再更新。'; return
    }
    $shell = [PowerShell]::Create()
    $body = {
        param($modulePath, $actionName, $releaseJson)
        $ErrorActionPreference = 'Stop'
        Import-Module $modulePath -Force
        if ($actionName -eq 'Check') { Get-LatestUpdate }
        else { Save-UpdateInstaller ($releaseJson | ConvertFrom-Json) }
    }
    try {
        [void]$shell.AddScript($body.ToString()).AddArgument((Join-Path $PSScriptRoot 'P4AutoMerge.Update.psm1'))
        [void]$shell.AddArgument($Action).AddArgument(($script:AvailableUpdate | ConvertTo-Json -Depth 5))
        $script:UpdateWorker = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke(); Action = $Action; Manual = [bool]$Manual }
        $script:Controls.UpdateStatus.Text = $(if ($Action -eq 'Check') { '正在检查更新…' } else { '正在下载并校验更新…' })
    }
    catch { $shell.Dispose(); Set-UpdateError $_.Exception.Message }
}

function Complete-UpdateOperation {
    $worker = $script:UpdateWorker
    $script:UpdateWorker = $null
    try {
        $result = @($worker.Shell.EndInvoke($worker.Handle))
        if ($worker.Shell.Streams.Error.Count) { throw ($worker.Shell.Streams.Error | Out-String) }
        if ($worker.Action -eq 'Download') { Complete-UpdateDownload $result[0]; return }
        $script:AvailableUpdate = $null
        if ($result.Count) { $script:AvailableUpdate = $result[0] }
        $script:UpdateManual = $worker.Manual
        $script:UpdatePromptPending = [bool]$script:AvailableUpdate
        $script:Controls.UpdateStatus.Text = "当前版本 $(Get-UpdateVersion)，没有更新的正式版。"
        if ($script:AvailableUpdate) { $script:Controls.UpdateStatus.Text = "发现新版 $($script:AvailableUpdate.Version)，可在更新 / 设置中查看。" }
    }
    catch { Set-UpdateError $_.Exception.Message }
    finally { $worker.Shell.Dispose() }
}

function Complete-UpdateDownload {
    param($Installer)
    if (-not (Test-UpdateCanInstall ([bool]$script:Worker) $script:Session)) {
        Set-UpdateError '下载已完成，但当前合并任务尚未结束。请完成后重新点击更新。'; return
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($env:P4AM_UPDATE_REQUEST))
    [IO.File]::WriteAllText($env:P4AM_UPDATE_REQUEST, ($Installer | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $script:Controls.Main.Close()
}

function Show-AvailableUpdate {
    $script:UpdatePromptPending = $false
    if (-not (Test-UpdateReminder $script:UpdatePreferences $script:AvailableUpdate.Version -Manual:$script:UpdateManual)) { return }
    $dialog = New-UpdateDialog
    try {
        $choice = $dialog.Form.ShowDialog($script:Controls.Main)
        Save-UpdateChoice $choice $dialog.Frequency.SelectedIndex
        if ($choice -ne 'Yes') { return }
        if (-not $env:P4AM_UPDATE_REQUEST) { Start-Process $script:AvailableUpdate.Page; return }
        Start-UpdateOperation 'Download'
    }
    catch { Set-UpdateError $_.Exception.Message }
    finally { $dialog.Form.Dispose() }
}

function Save-UpdateChoice {
    param([string]$Choice, [int]$FrequencyIndex)
    $script:UpdatePreferences.Frequency = $script:UpdateFrequencies[$FrequencyIndex]
    $script:UpdatePreferences.LastPromptUtc = [datetime]::UtcNow.ToString('o')
    if ($Choice -eq 'Ignore') { $script:UpdatePreferences.SkippedVersion = $script:AvailableUpdate.Version }
    Save-UpdatePreferences $script:UpdatePreferences
}

function Update-UpdateWorker {
    if ($script:UpdateWorker -and $script:UpdateWorker.Handle.IsCompleted) { Complete-UpdateOperation }
    if ($script:UpdatePromptPending -and (Test-UpdateCanInstall ([bool]$script:Worker) $script:Session)) { Show-AvailableUpdate }
}

function Stop-UpdateWorker {
    if (-not $script:UpdateWorker) { return }
    $worker = $script:UpdateWorker
    $script:UpdateWorker = $null
    $worker.Shell.Stop(); $worker.Shell.Dispose()
}

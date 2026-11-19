param([switch]$SmokeTest, [switch]$HeadlessTest, [switch]$ReadOnlyStartupTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'P4AutoMerge.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'P4AutoMerge.Update.psm1') -Force
. (Join-Path $PSScriptRoot 'P4AutoMerge.UpdateUi.ps1')
[Windows.Forms.Application]::EnableVisualStyles()
$script:Controls = @{}
$script:Clients = @()
$script:Streams = @()
$script:Worker = $null
$script:Preview = $null
$script:Session = $null
$script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:DetailLimit = 2000
$script:LogLimit = 500000
$script:SourceChanges = @()
$script:SelectedChanges = New-Object 'System.Collections.Generic.HashSet[int]'
$script:UpdatingChanges = $false
$script:LastOperationError = ''
$script:ChangeCache = @()
$script:DescriptionDisplayLimit = 200
$script:PreviewMessageLimit = 50
$script:PreviewMessageLength = 1000
$script:SelectedPreviewLimit = 1000
$script:SelectedDescriptionLimit = 500
$script:SelectedPreviewDirty = $true
$script:ChangeDetails = @{}
$script:SelectedPreviewBuildCount = 0
$script:ResolveModes = @(Get-ResolveModes)
$script:UpdatingResolveModes = $false

function New-Control {
    param([string]$Type, [string]$Name, [string]$Text = '')
    $control = New-Object ("System.Windows.Forms.$Type")
    $control.Name = $Name
    $control.Text = $Text
    $control.Dock = 'Fill'
    $control.Margin = New-Object Windows.Forms.Padding(4)
    $script:Controls[$Name] = $control
    return $control
}

function Add-FormRow {
    param($Grid, [int]$Row, [string]$Label, $Control)
    $caption = New-Object Windows.Forms.Label
    $caption.Text = $Label
    $caption.TextAlign = 'MiddleLeft'
    $caption.AutoSize = $true
    $caption.Dock = 'Fill'
    $Grid.Controls.Add($caption, 0, $Row)
    $Grid.Controls.Add($Control, 1, $Row)
}

function New-SettingsPanel {
    $grid = New-Control 'TableLayoutPanel' 'Settings'
    $grid.ColumnCount = 2
    $grid.RowCount = 10
    $grid.AutoSize = $true
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 125)))
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    Add-FormRow $grid 0 'P4 服务器' (New-Control 'TextBox' 'Server' '192.168.60.201:1666')
    Add-FormRow $grid 1 'P4 用户' (New-Control 'TextBox' 'User')
    Add-FormRow $grid 2 '目标 workspace' (New-Control 'ComboBox' 'Client')
    Add-FormRow $grid 3 '本地目录 / 分支' (New-Control 'TextBox' 'WorkspaceInfo')
    $script:Controls.WorkspaceInfo.ReadOnly = $true
    Add-FormRow $grid 4 '从来源分支' (New-Control 'ComboBox' 'Source')
    Add-FormRow $grid 5 '合并到目标分支' (New-Control 'ComboBox' 'Target')
    $cross = New-Control 'CheckBox' 'AllowCrossBranch' '允许跨分支合并（默认仅父子目标；勾选显示其他目标）'
    $cross.AutoSize = $true
    $cross.Enabled = $false
    Add-FormRow $grid 6 '合并范围' $cross
    $reintegrate = New-Control 'CheckBox' 'ForceReintegrate' '强制重新合并（忽略本次全部所选 CL 的合并历史）'
    $reintegrate.AutoSize = $true
    $reintegrate.Enabled = $false
    Add-FormRow $grid 7 '已合并的 CL' $reintegrate
    $resolve = New-Control 'ComboBox' 'ResolveMode'
    $resolve.DropDownStyle = 'DropDownList'
    $resolve.Items.AddRange([object[]]@($script:ResolveModes | ForEach-Object { $_.Label }))
    $resolve.SelectedIndex = 0
    Add-FormRow $grid 8 '合并 / Resolve 方式' $resolve
    $notice = New-Control 'Label' 'Notice' '合并结果保留在 pending CL，请检查后自行提交。'
    $notice.AutoSize = $true
    $grid.Controls.Add($notice, 0, 9)
    $grid.SetColumnSpan($notice, 2)
    foreach ($name in @('Client', 'Source', 'Target')) {
        $script:Controls[$name].DropDownStyle = 'DropDownList'
    }
    $script:Controls.Target.Enabled = $false
    return $grid
}

function New-SelectionPanel {
    $grid = New-Control 'TableLayoutPanel' 'Selection'
    $grid.RowCount = 4
    $grid.ColumnCount = 1
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 33)))
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 33)))
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 60)))
    $grid.Controls.Add((New-ListToolbar), 0, 0)
    $grid.Controls.Add((New-SearchToolbar), 0, 1)
    $list = New-Control 'ListView' 'Changes'
    $list.View = 'Details'
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.ShowItemToolTips = $true
    foreach ($column in @(@('源 CL', 85), @('提交人', 110), @('日期', 145), @('说明', 650))) {
        [void]$list.Columns.Add($column[0], $column[1])
    }
    $grid.Controls.Add($list, 0, 2)
    $manual = New-Control 'TextBox' 'ManualChanges'
    $manual.Multiline = $true
    $manual.ScrollBars = 'Vertical'
    $manual.AccessibleName = '额外 CL 编号，使用空格、逗号或换行分隔；与勾选 CL 合并去重'
    $grid.Controls.Add($manual, 0, 3)
    return $grid
}

function New-SearchToolbar {
    $bar = New-Control 'FlowLayoutPanel' 'SearchToolbar'
    $bar.WrapContents = $false
    $label = New-Control 'Label' 'SearchLabel' '搜索 CL / 提交人 / 描述：'
    $label.AutoSize = $true
    $bar.Controls.Add($label)
    $search = New-Control 'TextBox' 'ChangeSearch'
    $search.Width = 270
    $search.AccessibleName = '在已加载的来源 CL 中搜索编号、提交人和完整描述'
    $bar.Controls.Add($search)
    $clear = New-Control 'Button' 'ClearSearch' '清除搜索'
    $clear.AutoSize = $true
    $bar.Controls.Add($clear)
    $count = New-Control 'Label' 'SearchCount' '尚未加载来源 CL'
    $count.AutoSize = $true
    $bar.Controls.Add($count)
    return $bar
}

function New-ListToolbar {
    $bar = New-Control 'FlowLayoutPanel' 'ListToolbar'
    $bar.WrapContents = $false
    foreach ($entry in @(@('Connect', '连接 / 刷新 workspace'), @('Fetch', '加载来源 CL'))) {
        $button = New-Control 'Button' $entry[0] $entry[1]
        $button.AutoSize = $true
        $bar.Controls.Add($button)
    }
    $caption = New-Control 'Label' 'LimitLabel' '最近条数：'
    $caption.AutoSize = $true
    $bar.Controls.Add($caption)
    $limit = New-Control 'NumericUpDown' 'Limit'
    $limit.Minimum = 1
    $limit.Maximum = 1000
    $limit.Value = 1000
    $limit.Width = 70
    $bar.Controls.Add($limit)
    $hint = New-Control 'Label' 'ManualHint' '下方可额外输入 CL 编号（逗号 / 空格 / 换行分隔）'
    $hint.AutoSize = $true
    $bar.Controls.Add($hint)
    return $bar
}

function New-ActionPanel {
    $bar = New-Control 'FlowLayoutPanel' 'Actions'
    $bar.AutoSize = $true
    foreach ($entry in @(@('Preview', '1. 预览'), @('Start', '2. 执行合并'),
        @('Load', '恢复该 workspace 队列'), @('Resume', '检查并继续'),
        @('P4V', '在 P4V 打开 workspace'), @('Finish', '结束队列（保留 CL）'))) {
        $button = New-Control 'Button' $entry[0] $entry[1]
        $button.AutoSize = $true
        $bar.Controls.Add($button)
    }
    $script:Controls.Start.Enabled = $false
    $script:Controls.Resume.Enabled = $false
    $script:Controls.P4V.Enabled = $false
    $script:Controls.Finish.Enabled = $false
    return $bar
}

function New-OutputPanel {
    $tabs = New-Control 'TabControl' 'Output'
    foreach ($entry in @(@('Details', '预览 / 待手工处理'), @('Log', '运行日志'))) {
        $page = New-Object Windows.Forms.TabPage
        $page.Text = $entry[1]
        $text = New-Control 'TextBox' $entry[0]
        $text.Multiline = $true
        $text.ReadOnly = $true
        $text.WordWrap = $false
        $text.ScrollBars = 'Both'
        $page.Controls.Add($text)
        $tabs.TabPages.Add($page)
    }
    return $tabs
}

function New-MainForm {
    $form = New-Control 'Form' 'Main' 'P4 自动合并 — 默认安全 Resolve / 手动处理冲突'
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $form.Size = New-Object Drawing.Size(1220, 995)
    $form.MinimumSize = New-Object Drawing.Size(1020, 875)
    $form.StartPosition = 'CenterScreen'
    $layout = New-Control 'TableLayoutPanel' 'Layout'
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 300)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 45)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 35)))
    $layout.Controls.Add((New-SettingsPanel), 0, 0)
    $layout.Controls.Add((New-ResizableContent), 0, 1)
    $status = New-Control 'Label' 'Status' '请连接 P4，选择 workspace、来源分支和 CL。'
    $status.AutoSize = $true
    $layout.Controls.Add($status, 0, 2)
    $layout.Controls.Add((New-UpdateBar), 0, 3)
    $form.Controls.Add($layout)
    New-SelectedWindow
    Update-ResolveLabels
    return $form
}

function Update-ResolveLabels {
    $combo = $script:Controls.ResolveMode
    $index = [Math]::Max(0, $combo.SelectedIndex)
    $script:UpdatingResolveModes = $true
    $combo.BeginUpdate()
    try {
        $combo.Items.Clear()
        foreach ($mode in $script:ResolveModes) {
            $request = [pscustomobject]@{ ResolveMode=$mode.Value; Source=$script:Controls.Source.Text; Target=$script:Controls.Target.Text }
            [void]$combo.Items.Add((Get-ResolveLabel $request))
        }
        $combo.SelectedIndex = $index
    }
    finally { $combo.EndUpdate(); $script:UpdatingResolveModes = $false }
}

function New-SelectedWindow {
    $window = New-Control 'Form' 'SelectedWindow' '已选择的 CL — 自动刷新'
    $window.Size = New-Object Drawing.Size(660, 540)
    $window.MinimumSize = New-Object Drawing.Size(420, 260)
    $window.Font = $script:Controls.Main.Font
    $window.StartPosition = 'WindowsDefaultLocation'
    $text = New-Control 'TextBox' 'SelectedDetails'
    $text.Multiline = $true; $text.ReadOnly = $true
    $text.ScrollBars = 'Both'; $text.WordWrap = $false
    $window.Controls.Add($text)
    $window.Add_FormClosing({
        if ($_.CloseReason -eq 'UserClosing' -and -not $script:Controls.Main.IsDisposed) {
            $_.Cancel = $true
            $this.WindowState = 'Minimized'
        }
    })
}

function New-ResizableContent {
    $split = New-Control 'SplitContainer' 'ContentSplit'
    $split.Orientation = 'Horizontal'
    $split.Size = New-Object Drawing.Size(1100, 550)
    $split.SplitterWidth = 6
    $split.Panel1MinSize = 300
    $split.Panel2MinSize = 110
    $split.SplitterDistance = 350
    $split.BackColor = [Drawing.SystemColors]::ControlDark
    $split.AccessibleName = '上下拖动分隔条，调整来源 CL 列表和下方预览的高度'
    $hostPanel = New-Control 'TableLayoutPanel' 'SelectionHost'
    $hostPanel.ColumnCount = 1
    $hostPanel.RowCount = 2
    [void]$hostPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$hostPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 75)))
    $hostPanel.Controls.Add((New-SelectionPanel), 0, 0)
    $hostPanel.Controls.Add((New-ActionPanel), 0, 1)
    $split.Panel1.Controls.Add($hostPanel)
    $split.Panel2.Controls.Add((New-OutputPanel))
    return $split
}

function Get-UiRequest {
    $checked = @($script:SelectedChanges | Sort-Object | ForEach-Object { [string]$_ })
    $text = (($checked + @($script:Controls.ManualChanges.Text)) -join ' ')
    return [pscustomobject]@{
        Context = [pscustomobject]@{
            Server = $script:Controls.Server.Text.Trim(); User = $script:Controls.User.Text.Trim()
            Client = $script:Controls.Client.Text
        }
        Source = $script:Controls.Source.Text; Target = $script:Controls.Target.Text
        AllowCrossBranch = $script:Controls.AllowCrossBranch.Checked
        ForceReintegrate = $script:Controls.ForceReintegrate.Checked
        ResolveMode = $script:ResolveModes[$script:Controls.ResolveMode.SelectedIndex].Value
        ChangeText = $text; Limit = [int]$script:Controls.Limit.Value
    }
}

function Reset-Preview {
    $script:Preview = $null
    $script:Controls.Start.Enabled = $false
    Invalidate-SelectedPreview
}

function Invalidate-SelectedPreview {
    $script:SelectedPreviewDirty = $true
    Update-SelectedPreview
}

function Get-SelectedPreviewSnapshot {
    $request = Get-UiRequest
    $active = $script:Session -and $script:Session.Phase -notin @('Complete', 'Abandoned')
    if ($active) { $request = $script:Session.Request }
    $numbers = @()
    $problem = ''
    if (-not [string]::IsNullOrWhiteSpace($request.ChangeText)) {
        try { $numbers = @(ConvertTo-ChangeNumbers $request.ChangeText) }
        catch {
            $problem = $_.Exception.Message
            $numbers = @($script:SelectedChanges | Sort-Object)
        }
    }
    return [pscustomobject]@{Request=$request; Numbers=$numbers; Problem=$problem; Active=$active}
}

function Update-SelectedPreview {
    if (-not $script:SelectedPreviewDirty) { return }
    if ($HeadlessTest) { $script:SelectedPreviewBuildCount++ }
    $snapshot = Get-SelectedPreviewSnapshot
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $request = $snapshot.Request
    $lines.Add("已选 CL：$(@($snapshot.Numbers).Count) 个；以下为去重后由小到大的合并顺序。")
    $lines.Add("方向：$($request.Source) → $($request.Target)")
    $lines.Add("允许跨分支：$(Get-CrossBranchMode $request)；强制重新合并：$(Get-ReintegrateMode $request)")
    $lines.Add("合并方式：$(Get-ResolveLabel $request)")
    if ($snapshot.Active) { $lines.Add('显示当前活动队列保存的 CL，队列模式已锁定。') }
    if ($snapshot.Problem) { $lines.Add("手动输入有误：$($snapshot.Problem)；以下仅列出有效勾选项。") }
    $position = 0
    foreach ($number in @($snapshot.Numbers | Select-Object -First $script:SelectedPreviewLimit)) {
        $position++
        Add-SelectedChangeDetails $lines ([int]$number) $position
    }
    if ($snapshot.Numbers.Count -gt $position) { $lines.Add("界面仅显示前 $position 个 CL；实际已选编号和执行请求不截断。") }
    if ($position -eq 0) { $lines.Add('尚未选择 CL，可在来源列表中勾选或手动输入编号。') }
    $script:Controls.SelectedDetails.Lines = $lines.ToArray()
    $script:SelectedPreviewDirty = $false
}

function Add-SelectedChangeDetails {
    param($Lines, [int]$Number, [int]$Position)
    $Lines.Add('')
    if (-not $script:ChangeDetails.ContainsKey($Number)) {
        $Lines.Add("$Position. CL $Number（未加载提交人和说明）")
        $Lines.Add('   编号已纳入选择；点击“1. 预览”时会检查提交状态和来源分支。')
        return
    }
    $change = $script:ChangeDetails[$Number]
    $description = ([string]$change.desc -replace '\s+', ' ').Trim()
    if ($description.Length -gt $script:SelectedDescriptionLimit) {
        $description = $description.Substring(0, $script:SelectedDescriptionLimit) + '…（说明已缩短）'
    }
    $Lines.Add("$Position. CL $Number | 提交人：$($change.user)")
    $Lines.Add("   $description")
}

function Set-BusyState {
    param([bool]$Busy)
    foreach ($name in @('Settings', 'Selection', 'Actions')) {
        $script:Controls[$name].Enabled = -not $Busy
    }
    if ($Busy) { $script:Controls.Status.Text = '正在执行 P4 命令，请等待；运行日志会持续更新。' }
}

function Start-UiOperation {
    param([string]$Action)
    if ($script:Worker) { return }
    $script:LastOperationError = ''
    $request = Get-UiRequest
    Assert-UiRequest $Action $request
    if ($Action -eq 'Start' -and -not (Confirm-Start $request)) { return }
    if ($Action -eq 'Finish' -and -not (Confirm-Finish)) { return }
    if ($Action -eq 'Resume' -and -not (Confirm-Review)) { return }
    $shell = [PowerShell]::Create()
    $body = {
        param($modulePath, $actionName, $requestJson, $queue)
        $ErrorActionPreference = 'Stop'
        Import-Module $modulePath -Force
        $requestObject = $requestJson | ConvertFrom-Json
        Invoke-MergeAction $actionName $requestObject $queue
    }
    [void]$shell.AddScript($body.ToString()).AddArgument((Join-Path $PSScriptRoot 'P4AutoMerge.Core.psm1'))
    [void]$shell.AddArgument($Action).AddArgument(($request | ConvertTo-Json -Depth 8)).AddArgument($script:Queue)
    Set-BusyState $true
    $script:Worker = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke(); Action = $Action }
}

function Assert-UiRequest {
    param([string]$Action, $Request)
    if ($Action -notin @('Changes', 'Preview', 'Start')) { return }
    if (-not $Request.Source) { throw '请先选择来源分支。' }
    if ($Action -eq 'Changes') { return }
    if (-not $Request.Target) { throw '请先选择目标分支。' }
    $allowed = @(Get-AllowedTargetStreams $Request.Source $script:Streams (Get-CrossBranchMode $Request))
    if (@($allowed | Where-Object { $_.Stream -ceq $Request.Target }).Count -eq 0) {
        throw '当前目标不在可选范围内，请重新选择目标，或明确勾选允许跨分支合并。'
    }
    $clients = @($script:Clients | Where-Object { $_.client -ceq $Request.Context.Client })
    if ($clients.Count -ne 1) { throw '请先选择目标 workspace。' }
    $stream = ''
    if ($clients[0].PSObject.Properties['Stream']) { $stream = $clients[0].Stream }
    if ($stream -cne $Request.Target) {
        throw "目标是 '$($Request.Target)'，但当前 workspace 属于 '$stream'。请选择绑定到目标分支的 workspace。"
    }
}

function Confirm-Start {
    param($Request)
    if (-not $script:Preview) { throw '请先预览。' }
    $numbers = @(ConvertTo-ChangeNumbers $Request.ChangeText)
    $message = "workspace：$($Request.Context.Client)`n$($Request.Source) → $($Request.Target)"
    $mode = '普通父子合并'
    if (Get-CrossBranchMode $Request) { $mode = '跨分支合并（允许其他同仓库目标）' }
    $message += "`n合并范围：$mode"
    if (Get-ReintegrateMode $Request) {
        $message += "`n强制重新合并：已开启，将忽略本次全部所选 CL 的合并历史，已撤销的修改也会重新进入 Resolve。"
    }
    $message += "`n源 CL：$($numbers -join ', ')`n合并方式：$(Get-ResolveLabel $Request)`n$(Get-ResolveNotice $Request)"
    $message += "`n`n将新建 pending CL，执行合并和所选 Resolve。是否开始？"
    return [Windows.Forms.MessageBox]::Show($script:Controls.Main, $message, '执行合并', 'YesNo', 'Question') -eq 'Yes'
}

function Confirm-Finish {
    $message = '结束工具对当前队列的跟踪，保留 P4 中的文件及 pending CL。之后请在 P4V 自行检查、解决和提交，或自行放弃。确定结束？'
    return [Windows.Forms.MessageBox]::Show($script:Controls.Main, $message, '结束队列', 'YesNo', 'Question') -eq 'Yes'
}

function Confirm-Review {
    if (-not $script:Session -or (Get-ResolveMode $script:Session.Request) -ne '-af') { return $true }
    $message = '强制合并可能已把包含冲突标记的文件标为已解决。请确认已逐个检查本次 CL 的结果、处理所有冲突标记，再继续后续 CL。确认已检查？'
    return [Windows.Forms.MessageBox]::Show($script:Controls.Main, $message, '确认强制合并结果', 'YesNo', 'Warning') -eq 'Yes'
}

function Set-ClientSelection {
    Reset-Preview
    $script:Session = $null
    Set-SessionButtons
    $selected = @($script:Clients | Where-Object { $_.client -ceq $script:Controls.Client.Text })
    if ($selected.Count -eq 0) { $script:Controls.WorkspaceInfo.Clear(); Update-TargetStreams; return }
    $client = $selected[0]
    $stream = ''
    if ($client.PSObject.Properties['Stream']) { $stream = $client.Stream }
    $script:Controls.WorkspaceInfo.Text = "$($client.Root)  |  $stream"
    Update-TargetStreams $stream
}

function Update-TargetStreams {
    param([string]$PreferredTarget = '')
    Reset-Preview
    $oldTarget = $script:Controls.Target.Text
    $target = $script:Controls.Target
    $target.Items.Clear()
    $target.SelectedIndex = -1
    $target.Text = ''
    $allowed = @(Get-AllowedTargetStreams $script:Controls.Source.Text $script:Streams $script:Controls.AllowCrossBranch.Checked)
    foreach ($stream in @($allowed | Sort-Object Stream)) { [void]$target.Items.Add($stream.Stream) }
    if ($PreferredTarget -and $target.Items.Contains($PreferredTarget)) { $target.SelectedItem = $PreferredTarget }
    elseif ($oldTarget -and $target.Items.Contains($oldTarget)) { $target.SelectedItem = $oldTarget }
    else { Select-WorkspaceTarget }
    Set-SessionButtons
}

function Select-WorkspaceTarget {
    $clients = @($script:Clients | Where-Object { $_.client -ceq $script:Controls.Client.Text })
    if ($clients.Count -ne 1 -or -not $clients[0].PSObject.Properties['Stream']) { return }
    $stream = $clients[0].Stream
    if ($script:Controls.Target.Items.Contains($stream)) { $script:Controls.Target.SelectedItem = $stream }
}

function Show-Catalog {
    param($Catalog)
    $previous = $script:Controls.Client.Text
    $script:Session = $null
    Set-SessionButtons
    $script:Controls.User.Text = $Catalog.Context.User
    $script:Clients = @($Catalog.Clients)
    $script:Streams = @($Catalog.Streams)
    $script:Controls.Client.Items.Clear()
    foreach ($client in $script:Clients) { [void]$script:Controls.Client.Items.Add($client.client) }
    $script:Controls.Source.Items.Clear()
    $script:Controls.Target.Items.Clear()
    foreach ($stream in @($Catalog.Streams | Sort-Object Stream)) {
        [void]$script:Controls.Source.Items.Add($stream.Stream)
    }
    if (-not $previous) { $previous = $Catalog.Info.clientName }
    $script:Controls.Client.SelectedItem = $previous
    if ($script:Controls.Client.SelectedIndex -lt 0 -and $script:Clients.Count -gt 0) {
        $script:Controls.Client.SelectedIndex = 0
    }
    $script:Controls.Status.Text = '已连接。请选择来源分支；目标分支必须与 workspace 一致。'
}

function Show-ChangeList {
    param($Changes)
    $script:SourceChanges = @($Changes)
    $cache = New-Object 'System.Collections.Generic.List[object]'
    $script:ChangeDetails = @{}
    foreach ($change in $script:SourceChanges) {
        $script:ChangeDetails[[int]$change.change] = $change
        $cache.Add([pscustomobject]@{
            SearchText = "$($change.change) $($change.user) $($change.desc)"
            Item = New-ChangeListItem $change
        })
    }
    $script:ChangeCache = $cache.ToArray()
    Reset-Preview
    Update-FilteredChanges
    $script:Controls.Status.Text = "已加载 $($script:SourceChanges.Count) 个来源 CL。搜索仅针对已加载条目，上限 1000；更多已知 CL 可在下方手动输入编号。"
}

function Update-FilteredChanges {
    $query = $script:Controls.ChangeSearch.Text.Trim()
    $script:UpdatingChanges = $true
    $list = $script:Controls.Changes
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $items = New-Object 'System.Collections.Generic.List[System.Windows.Forms.ListViewItem]'
        foreach ($entry in $script:ChangeCache) {
            if ($query -and $entry.SearchText.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $entry.Item.Checked = $script:SelectedChanges.Contains([int]$entry.Item.Text)
            $items.Add($entry.Item)
        }
        $list.Items.AddRange($items.ToArray())
    }
    finally {
        $list.EndUpdate()
        $script:UpdatingChanges = $false
    }
    Update-SearchCount
}

function New-ChangeListItem {
    param($Change)
    $item = New-Object Windows.Forms.ListViewItem([string]$Change.change)
    [void]$item.SubItems.Add($Change.user)
    $time = [DateTimeOffset]::FromUnixTimeSeconds([long]$Change.time).LocalDateTime
    [void]$item.SubItems.Add($time.ToString('yyyy-MM-dd HH:mm'))
    $description = $Change.desc -replace '\s+', ' '
    if ($description.Length -gt $script:DescriptionDisplayLimit) {
        $description = $description.Substring(0, $script:DescriptionDisplayLimit) + '…'
    }
    [void]$item.SubItems.Add($description)
    $item.ToolTipText = $Change.desc
    $item.Checked = $script:SelectedChanges.Contains([int]$Change.change)
    return $item
}

function Update-SearchCount {
    $script:Controls.SearchCount.Text = "显示 $($script:Controls.Changes.Items.Count) / 已加载 $($script:SourceChanges.Count)，已勾选 $($script:SelectedChanges.Count)"
}

function Update-ChangeSelection {
    param($Item)
    if ($script:UpdatingChanges) { return }
    $number = [int]$Item.Text
    if ($Item.Checked) { [void]$script:SelectedChanges.Add($number) }
    else { [void]$script:SelectedChanges.Remove($number) }
    Reset-Preview
    Update-SearchCount
}

function Clear-SourceChanges {
    $script:SourceChanges = @()
    $script:ChangeCache = @()
    $script:ChangeDetails = @{}
    $script:SelectedChanges.Clear()
    $script:Controls.ChangeSearch.Clear()
    Update-FilteredChanges
    Reset-Preview
}

function Show-Preview {
    param($Preview)
    $script:Preview = $Preview
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]]@("workspace：$($Preview.Request.Context.Client)", "目录：$($Preview.Root)",
        "方向：$($Preview.Request.Source) → $($Preview.Request.Target)",
        "允许跨分支：$(Get-CrossBranchMode $Preview.Request)",
        "强制重新合并：$(Get-ReintegrateMode $Preview.Request)（作用于本次全部所选 CL）",
        '以下各 CL 独立预览；后续 CL 的实际处理结果会受到前面 CL 和手工处理的影响。', ''))
    $count = 0
    $shown = 0
    $messageBudget = @{ Shown = 0; Omitted = 0 }
    foreach ($item in $Preview.Items) {
        $lines.Add("源 CL $($item.Change)：$(@($item.Files).Count) 个文件")
        Add-PreviewMessages $lines $item $messageBudget
        $count += @($item.Files).Count
        $remaining = $script:DetailLimit - $shown
        foreach ($file in @($item.Files | Select-Object -First $remaining)) {
            $lines.Add("  $($file.action)  $($file.depotFile)")
            $shown++
        }
    }
    if ($count -gt $shown) { $lines.Add("界面仅显示前 $shown 个文件，共 $count 个；实际操作不截断。") }
    if ($messageBudget.Omitted -gt 0) { $lines.Add("已省略 $($messageBudget.Omitted) 条 P4 消息，请查看运行日志；文件及队列数据不截断。") }
    $script:Controls.Details.Lines = $lines.ToArray()
    $script:Controls.Output.SelectedTab = $script:Controls.Details.Parent
    $script:Controls.Start.Enabled = $count -gt 0
    $script:Controls.Status.Text = "预览完成：$($Preview.Changes.Count) 个 CL，$count 个文件操作（同一文件可重复出现）。"
}

function Add-PreviewMessages {
    param($Lines, $Item, $Budget)
    if (-not $Item.PSObject.Properties['Messages']) { return }
    $messages = @($Item.Messages | Where-Object { $_.PSObject.Properties['data'] -and $_.data })
    $remaining = [Math]::Max(0, $script:PreviewMessageLimit - $Budget.Shown)
    $selected = @($messages | Select-Object -First $remaining)
    foreach ($message in $selected) {
        $text = ([string]$message.data -replace '\s+', ' ').Trim()
        if ($text.Length -gt $script:PreviewMessageLength) { $text = $text.Substring(0, $script:PreviewMessageLength) + '…' }
        $Lines.Add("  P4：$text")
    }
    $Budget.Shown += $selected.Count
    $Budget.Omitted += $messages.Count - $selected.Count
}

function Set-SessionButtons {
    $active = $null -ne $script:Session
    $script:Controls.P4V.Enabled = $active
    $script:Controls.Finish.Enabled = $active -and $script:Session.Phase -notin @('Complete', 'Abandoned')
    $script:Controls.Resume.Enabled = $active -and $script:Session.Phase -in @('Waiting', 'Ready', 'Resolving', 'ReviewRequired')
    $locked = $active -and $script:Session.Phase -notin @('Complete', 'Abandoned')
    foreach ($name in @('Source', 'Changes', 'Fetch', 'Preview', 'SearchToolbar')) {
        $script:Controls[$name].Enabled = -not $locked
    }
    $script:Controls.Target.Enabled = -not $locked -and
        -not [string]::IsNullOrWhiteSpace($script:Controls.Source.Text) -and
        $script:Controls.Target.Items.Count -gt 0
    $script:Controls.AllowCrossBranch.Enabled = -not $locked -and
        -not [string]::IsNullOrWhiteSpace($script:Controls.Source.Text)
    $script:Controls.ForceReintegrate.Enabled = $script:Controls.AllowCrossBranch.Enabled
    $script:Controls.ManualChanges.ReadOnly = $locked
    $script:Controls.ResolveMode.Enabled = -not $locked
}

function Show-Session {
    param($State)
    Reset-Preview
    $script:Session = $State
    Invalidate-SelectedPreview
    if ($State) {
        $script:Controls.Source.SelectedItem = $State.Request.Source
        $script:Controls.AllowCrossBranch.Checked = Get-CrossBranchMode $State.Request
        $script:Controls.ForceReintegrate.Checked = Get-ReintegrateMode $State.Request
        $script:Controls.ResolveMode.SelectedIndex = [array]::IndexOf(@($script:ResolveModes | ForEach-Object { $_.Value }), (Get-ResolveMode $State.Request))
        Update-TargetStreams
        $script:Controls.Target.SelectedItem = $State.Request.Target
    }
    Set-SessionButtons
    if (-not $State) { $script:Controls.Status.Text = '此 workspace 没有保存的队列。'; return }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]]@("pending CL：$($State.Pending)", "workspace：$($State.Request.Context.Client)",
        "方向：$($State.Request.Source) → $($State.Request.Target)",
        "源 CL：$($State.Changes -join ', ')", "已完成：$($State.Index) / $(@($State.Changes).Count)",
        "状态：$($State.Phase)", "允许跨分支：$(Get-CrossBranchMode $State.Request)",
        "强制重新合并：$(Get-ReintegrateMode $State.Request)", "合并方式：$(Get-ResolveLabel $State.Request)",
        "待手工处理项目：$(@($State.Unresolved).Count)", ''))
    foreach ($record in @($State.Unresolved | Select-Object -First $script:DetailLimit)) {
        $lines.Add((Get-ResolveDisplay $record))
    }
    if (@($State.Unresolved).Count -gt $script:DetailLimit) { $lines.Add('界面仅显示前 2000 项，请在 P4V 查看全部文件。') }
    if ($State.LastError) { $lines.Add("错误：$($State.LastError)") }
    $script:Controls.Details.Lines = $lines.ToArray()
    $script:Controls.Output.SelectedTab = $script:Controls.Details.Parent
    $script:Controls.Status.Text = Get-SessionStatus $State
}

function Get-ResolveDisplay {
    param($Record)
    $target = '（目标路径见 P4V）'
    $source = ''
    if ($Record.PSObject.Properties['clientFile']) { $target = $Record.clientFile }
    if ($Record.PSObject.Properties['fromFile']) { $source = $Record.fromFile }
    return "目标：$target    来源：$source"
}

function Get-SessionStatus {
    param($State)
    switch ($State.Phase) {
        'ReviewRequired' { return "pending CL $($State.Pending)：强制合并后请检查冲突标记，确认后点击检查并继续。" }
        'Waiting' { return "pending CL $($State.Pending)：请在 P4V 手动 Resolve 剩余文件，之后点击检查并继续。" }
        'Complete' { return "全部处理完成。请在 P4V 检查 pending CL $($State.Pending) 后自行提交。" }
        'Abandoned' { return "队列跟踪已结束。pending CL $($State.Pending) 及文件保留，请在 P4V 自行处理。" }
        default { return "队列状态 $($State.Phase)，pending CL $($State.Pending)。结果不确定时先在 P4V 核对，勿重复 merge。" }
    }
}

function Complete-UiOperation {
    if (-not $script:Worker) { return }
    $worker = $script:Worker
    $script:Worker = $null
    try {
        $result = @($worker.Shell.EndInvoke($worker.Handle))
        if ($worker.Shell.Streams.Error.Count -gt 0) { throw ($worker.Shell.Streams.Error | Out-String) }
        switch ($worker.Action) {
            'Catalog' { Show-Catalog $result[0] }
            'Changes' { Show-ChangeList $result }
            'Preview' { Show-Preview $result[0] }
            default { Show-Session $result[0] }
        }
    }
    catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        $message = $failure.Message
        $script:LastOperationError = $message
        try {
            $saved = Invoke-MergeAction 'Load' (Get-UiRequest) $null
            if ($saved -and $saved.Phase -notin @('Complete', 'Abandoned')) { Show-Session $saved }
        }
        catch { $message += "`n本地队列记录读取失败：$($_.Exception.Message)" }
        Show-UiError $message
    }
    finally {
        try { $worker.Shell.Dispose() }
        finally { Set-BusyState $false }
    }
}

function Show-UiError {
    param([string]$Message)
    $script:LastOperationError = $Message
    $script:Controls.Status.Text = '操作停止：' + $Message
    $script:Controls.Log.AppendText("`r`n[错误] $Message`r`n")
    $script:Controls.Output.SelectedTab = $script:Controls.Log.Parent
    Reset-Preview
}

function Update-UiWorker {
    $line = ''
    $drained = 0
    $buffer = New-Object Text.StringBuilder
    while ($drained -lt 250 -and $script:Queue.TryDequeue([ref]$line)) {
        [void]$buffer.AppendLine($line)
        $drained++
    }
    if ($script:Controls.Log.TextLength -gt $script:LogLimit) {
        $script:Controls.Log.Text = $script:Controls.Log.Text.Substring($script:Controls.Log.TextLength - 250000)
    }
    if ($buffer.Length -gt 0) { $script:Controls.Log.AppendText($buffer.ToString()) }
    if ($script:Worker -and $script:Worker.Handle.IsCompleted) { Complete-UiOperation }
}

function Open-SessionInP4V {
    if (-not $script:Session) { return }
    Open-P4VWorkspace $script:Session.Request.Context
}

function Register-UiEvents {
    foreach ($name in @('Connect', 'Fetch', 'Preview', 'Start', 'Load', 'Resume', 'Finish')) {
        $script:Controls[$name].Add_Click({
            try {
                $action = $this.Name
                if ($action -eq 'Connect') { $action = 'Catalog' }
                if ($action -eq 'Fetch') { $action = 'Changes' }
                Start-UiOperation $action
            }
            catch { Show-UiError $_.Exception.Message }
        })
    }
    $script:Controls.P4V.Add_Click({
        try { Open-SessionInP4V }
        catch { Show-UiError $_.Exception.Message }
    })
    $script:Controls.Client.Add_SelectedIndexChanged({ Set-ClientSelection })
    $script:Controls.Source.Add_SelectedIndexChanged({ Clear-SourceChanges; Update-TargetStreams; Update-ResolveLabels })
    $script:Controls.AllowCrossBranch.Add_CheckedChanged({ Update-TargetStreams })
    $script:Controls.ForceReintegrate.Add_CheckedChanged({ Reset-Preview })
    $script:Controls.ResolveMode.Add_SelectedIndexChanged({
        if ($script:UpdatingResolveModes) { return }
        Reset-Preview
    })
    $script:Controls.Target.Add_SelectedIndexChanged({ Update-ResolveLabels; Reset-Preview })
    $script:Controls.Changes.Add_ItemChecked({ Update-ChangeSelection $_.Item })
    $script:Controls.ChangeSearch.Add_TextChanged({ Update-FilteredChanges })
    $script:Controls.ClearSearch.Add_Click({ $script:Controls.ChangeSearch.Clear() })
    $script:Controls.UpdateSettings.Add_Click({ Show-UpdateSettings })
    $script:Controls.ManualChanges.Add_TextChanged({ Reset-Preview })
    foreach ($name in @('Server', 'User')) {
        $script:Controls[$name].Add_TextChanged({ Reset-Catalog })
    }
    $script:Controls.Main.Add_FormClosing({
        if ($script:Worker) {
            $_.Cancel = $true
            [void][Windows.Forms.MessageBox]::Show('P4 命令正在运行，请等待完成后关闭。队列进度会自动保存。', '请等待')
        }
    })
    $script:Controls.Main.Add_Shown({
        if (-not ($SmokeTest -or $HeadlessTest -or $ReadOnlyStartupTest)) {
            Update-SelectedPreview
            $script:Controls.SelectedWindow.Show($script:Controls.Main)
            Start-InitialConnection
            Start-UpdateOperation 'Check'
        }
    })
}

function Start-InitialConnection {
    try { Start-UiOperation 'Catalog' }
    catch { Show-UiError ('自动连接失败，请点击连接 / 刷新 workspace：' + $_.Exception.Message) }
}

function Reset-Catalog {
    Reset-Preview
    $script:Session = $null
    $script:Clients = @()
    $script:Streams = @()
    $script:Controls.AllowCrossBranch.Checked = $false
    $script:Controls.ForceReintegrate.Checked = $false
    Set-SessionButtons
    foreach ($name in @('Client', 'Source', 'Target')) { $script:Controls[$name].Items.Clear() }
    Clear-SourceChanges
    $script:Controls.WorkspaceInfo.Clear()
    $script:Controls.Status.Text = '连接信息已改变，请重新连接 / 刷新 workspace。'
}

function Start-MergeUi {
    $form = New-MainForm
    Register-UiEvents
    $defaults = Get-P4Defaults
    $script:Controls.User.Text = $defaults.User
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({ Update-UiWorker; Update-UpdateWorker })
    $timer.Start()
    try {
        if ($HeadlessTest) { Test-UiLayout $form -Headless; Test-UiState; return }
        if ($ReadOnlyStartupTest) { Test-UiLayout $form -Headless; Test-StartupConnection; return }
        if ($SmokeTest) { Test-UiLayout $form; return }
        [Windows.Forms.Application]::Run($form)
    }
    finally {
        $timer.Stop(); $timer.Dispose(); Stop-UpdateWorker
        $script:Controls.SelectedWindow.Dispose(); $form.Dispose()
    }
}

function Test-UiLayout {
    param($Form, [switch]$Headless)
    if ($Headless) { $Form.CreateControl(); $Form.PerformLayout() }
    else { $Form.Show() }
    [Windows.Forms.Application]::DoEvents()
    foreach ($name in @('Client', 'Source', 'Target', 'Changes', 'Preview', 'Start', 'Details')) {
        $control = $script:Controls[$name]
        if ((-not $Headless -and -not $control.Visible) -or $control.Width -le 0 -or $control.Height -le 0) {
            throw "界面控件不可见或尺寸无效：$name"
        }
    }
    Write-Output "UI smoke test passed: $($script:Controls.Count) controls."
    if ($Headless) { Test-ResizableContent }
    if (-not $Headless) { $Form.Close() }
}

function Test-ResizableContent {
    if ($script:Controls.Limit.Value -ne 1000) { throw 'Default source CL count is not 1000' }
    $split = $script:Controls.ContentSplit
    $original = $split.SplitterDistance
    $form = $script:Controls.Main
    $originalSize = $form.Size
    try {
        foreach ($size in @($originalSize, $form.MinimumSize)) {
            $form.Size = $size
            $form.PerformLayout()
            Test-SplitterRange $split
        }
    }
    finally {
        $form.Size = $originalSize
        $form.PerformLayout()
        $split.SplitterDistance = $original
    }
    Write-Output 'Resizable preview passed: default 1000 CLs, movable divider and a complete CL row at minimum window/split size.'
}

function Test-SplitterRange {
    param($Split)
    $minimum = $Split.Panel1MinSize
    $maximum = [Math]::Min($Split.Height - $Split.SplitterWidth - $Split.Panel2MinSize, $minimum + 80)
    if ($Split.IsSplitterFixed -or $Split.Orientation -ne 'Horizontal' -or $maximum -le $minimum) {
        throw 'Vertical preview resizing is not available'
    }
    $Split.SplitterDistance = $minimum
    $Split.PerformLayout()
    $larger = $Split.Panel2.Height
    Test-MinimumClRow
    $Split.SplitterDistance = $maximum
    $Split.PerformLayout()
    if ($Split.Panel2.Height -ge $larger) { throw 'Preview height did not follow splitter position' }
}

function Test-MinimumClRow {
    $list = $script:Controls.Changes
    $wasUpdating = $script:UpdatingChanges
    $script:UpdatingChanges = $true
    try {
        [void]$list.Handle
        [void]$list.Items.Add('1')
        $bounds = $list.GetItemRect(0)
        if ($bounds.Height -le 0 -or $bounds.Top -lt 0 -or $bounds.Bottom -gt $list.ClientRectangle.Bottom) {
            throw 'Minimum layout does not show a complete selectable CL row below the header'
        }
    }
    finally { $list.Items.Clear(); $script:UpdatingChanges = $wasUpdating }
}

function Test-UiState {
    $source = '//Depot/Source'
    $target = '//Depot/Target'
    $context = [pscustomobject]@{ User = 'tester'; Client = 'test-client'; Server = 'test:1666' }
    $client = [pscustomobject]@{ client = 'test-client'; Root = $env:TEMP; Stream = $target }
    $catalog = [pscustomobject]@{
        Context = $context; Info = [pscustomobject]@{ clientName = 'test-client' }
        Clients = @($client); Streams = @(
            [pscustomobject]@{ Stream = $source; Type = 'release'; Parent = $target; Options = 'toparent nofromparent mergedown'; firmerThanParent = 'true' },
            [pscustomobject]@{ Stream = $target; Type = 'mainline'; Parent = 'none'; Options = 'notoparent nofromparent mergedown'; firmerThanParent = 'n/a' }
        )
    }
    Show-Catalog $catalog
    if ($script:Controls.Target.Items.Count -ne 0) { throw 'Target list populated before choosing source' }
    if ($script:Controls.Target.Enabled) { throw 'Target enabled before choosing source' }
    Test-UiRequestValidation $context $source
    Test-TargetScope
    Test-ReintegrateControl
    Test-ResolveControls
    Test-UpdateControls
    Test-UpdateHandoff
    $request = [pscustomobject]@{ Source = $source; Target = $target; Context = $context; AllowCrossBranch = $false; ChangeText = '101 102' }
    $state = [pscustomobject]@{
        Request = $request; Pending = 900; Phase = 'Waiting'; Index = 0
        Changes = @(101); Unresolved = @(); LastError = ''
    }
    Show-Session $state
    Test-SavedSelectedPreview
    if ($script:Controls.Source.Enabled -or -not $script:Controls.Resume.Enabled) { throw 'Active queue controls are inconsistent' }
    if ($script:Controls.Source.Text -cne $source) { throw 'Active queue source not synchronized' }
    $request.AllowCrossBranch = $true
    $request | Add-Member NoteProperty ForceReintegrate $true
    Show-Session $state
    if (-not $script:Controls.AllowCrossBranch.Checked -or $script:Controls.AllowCrossBranch.Enabled) { throw 'Saved cross mode not restored/locked' }
    if (-not $script:Controls.ForceReintegrate.Checked -or $script:Controls.ForceReintegrate.Enabled) { throw 'Saved reintegration not restored/locked' }
    $request.AllowCrossBranch = $false
    $request.PSObject.Properties.Remove('ForceReintegrate')
    Show-Session $state
    if ($script:Controls.ForceReintegrate.Checked) { throw 'Old session enabled reintegration' }
    Show-Session $null
    if (-not $script:Controls.Target.Enabled) { throw 'Target remained disabled with a selected source' }
    Test-ChangeSearch
    Test-LargePreview $request
    Test-PreviewMessages $request
    $script:Controls.User.Text = 'another-user'
    if ($script:Controls.Client.Items.Count -ne 0 -or $script:Controls.Start.Enabled) { throw 'Changing identity retained old catalog/preview' }
    Test-WorkerCompletion
    Write-Output 'UI state tests passed: workspace target, queue controls, CL search/selection, large preview, connection invalidation. No mouse/keyboard input.'
}

function Test-ResolveControls {
    $combo = $script:Controls.ResolveMode
    if ($combo.Items.Count -ne 5 -or (Get-UiRequest).ResolveMode -ne '-as') { throw 'Resolve mode defaults differ from P4 options' }
    if (-not $combo.Items[3].Contains($script:Controls.Source.Text) -or
        -not $combo.Items[4].Contains($script:Controls.Target.Text)) { throw 'Source/target stream is absent from resolve labels' }
    $script:Preview = [pscustomobject]@{}
    $script:Controls.Start.Enabled = $true
    $combo.SelectedIndex = 1
    if ((Get-UiRequest).ResolveMode -ne '-am' -or $script:Controls.Start.Enabled -or $script:Preview) { throw 'Resolve mode change retained preview' }
    $state = [pscustomobject]@{ Request=(Get-UiRequest); Phase='ReviewRequired'; Pending=900; Changes=@(101); Index=0; Unresolved=@(); LastError='' }
    Show-Session $state
    if ($combo.Enabled -or -not $script:Controls.Resume.Enabled) { throw 'Saved resolve mode not locked or force review cannot continue' }
    Show-Session $null
    $combo.SelectedIndex = 0
    if ($script:Controls.ContainsKey('SelectedView') -or $script:Controls.Output.TabPages.Count -ne 2 -or
        $script:Controls.SelectedDetails.Parent -ne $script:Controls.SelectedWindow) { throw 'Selected CL overview is not a separate window' }
    Write-Output 'Resolve controls passed: P4 labels with streams, safe default, invalidation, saved mode lock and independent selected CL window.'
}

function Test-UpdateControls {
    $savedRelease=$script:AvailableUpdate; $savedPreferences=$script:UpdatePreferences
    $module=Get-Module P4AutoMerge.Update
    $oldPath=& $module { $script:PreferencesPath }
    $path=Join-Path $env:TEMP ('P4AutoMerge-UpdateUiTest-' + [guid]::NewGuid().ToString('N') + '/settings.json')
    & $module { param($p) $script:PreferencesPath=$p } $path
    $script:AvailableUpdate=[pscustomobject]@{Version='9.0.0'; Notes='Test update log'; Page='https://github.com/rexyizhouhu/p4-auto-merge/releases/tag/v9.0.0'}
    $script:UpdatePreferences=[pscustomobject]@{Frequency='Always'; SkippedVersion=''; LastPromptUtc=''}
    $dialog=New-UpdateDialog
    try {
        $dialog.Form.CreateControl(); $dialog.Form.PerformLayout()
        $grid=$dialog.Form.Controls[0]
        $buttons=@($grid.Controls[4].Controls | ForEach-Object { $_.Text })
        if (($buttons -join ',') -ne '更新,取消,跳过此版本' -or $dialog.Frequency.Items.Count -ne 4 -or
            -not $grid.Controls[1].Text.Contains('Test update log')) { throw 'Update dialog choices, frequency or notes missing' }
        Save-UpdateChoice 'Ignore' 1
        $saved=Get-UpdatePreferences
        if ($saved.Frequency -ne 'Weekly' -or $saved.SkippedVersion -ne '9.0.0') { throw 'Skip did not save frequency and version' }
        Save-UpdateChoice 'Cancel' 2
        if ((Get-UpdatePreferences).Frequency -ne 'Monthly') { throw 'Cancel did not save reminder frequency' }
    }
    finally {
        $dialog.Form.Dispose(); $script:AvailableUpdate=$savedRelease; $script:UpdatePreferences=$savedPreferences
        & $module { param($p) $script:PreferencesPath=$p } $oldPath
    }
    Write-Output 'Update dialog passed hidden checks: release notes, update/cancel/skip, four frequencies, settings persisted on skip/cancel. No dialog displayed.'
}

function Test-UpdateHandoff {
    $savedForm=$script:Controls.Main; $savedWorker=$script:Worker; $savedSession=$script:Session
    $savedRequest=$env:P4AM_UPDATE_REQUEST
    $env:P4AM_UPDATE_REQUEST=Join-Path $env:TEMP ('P4AutoMerge-HandoffTest-' + [guid]::NewGuid().ToString('N') + '/request.json')
    $mock=[pscustomobject]@{ Closed=$false }
    $mock | Add-Member ScriptMethod Close { $this.Closed=$true }
    $script:Controls.Main=$mock
    $installer=[pscustomobject]@{Path='C:\test\P4AutoMerge-9.0.0-Setup-x64.exe'; SHA256=('0'*64); Version='9.0.0'}
    try {
        $script:Worker=$null; $script:Session=[pscustomobject]@{Phase='Waiting'}
        Complete-UpdateDownload $installer
        if ($mock.Closed -or (Test-Path -LiteralPath $env:P4AM_UPDATE_REQUEST)) { throw 'Update closed an active merge queue' }
        $script:Session=$null
        Complete-UpdateDownload $installer
        $request=Get-Content -LiteralPath $env:P4AM_UPDATE_REQUEST -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $mock.Closed -or $request.Path -cne $installer.Path -or $request.SHA256 -cne $installer.SHA256) {
            throw 'Verified download handoff did not close cleanly or retain hash/path'
        }
    }
    finally {
        $script:Controls.Main=$savedForm; $script:Worker=$savedWorker; $script:Session=$savedSession
        $env:P4AM_UPDATE_REQUEST=$savedRequest
    }
    Write-Output 'Update handoff passed: active queue blocks close/install, idle handoff preserves verified path/hash. No installer executed.'
}

function Test-UiRequestValidation {
    param($Context, [string]$Source)
    $request = [pscustomobject]@{ Context = $Context; Source = $Source; Target = $Source }
    try { Assert-UiRequest 'Preview' $request; throw 'MISMATCH_ACCEPTED' }
    catch { if ($_.Exception.Message -notmatch '目标|workspace') { throw } }
    $request.Source = ''
    try { Assert-UiRequest 'Preview' $request; throw 'EMPTY_SOURCE_ACCEPTED' }
    catch { if ($_.Exception.Message -notmatch '来源') { throw } }
    if ($script:Worker) { throw 'Invalid target created a background worker' }
    Write-Output 'Request validation passed: missing source and mismatching workspace rejected before worker creation.'
}

function Test-WorkerCompletion {
    $script:TestCompletionCount = 0
    $script:TestDisposeCount = 0
    $shell = [pscustomobject]@{}
    $shell | Add-Member ScriptMethod EndInvoke {
        param($Handle)
        $script:TestCompletionCount++
        if ($script:TestCompletionCount -eq 1) { Update-UiWorker }
        throw 'Simulated workspace mismatch'
    }
    $shell | Add-Member ScriptMethod Dispose { $script:TestDisposeCount++ }
    $script:Worker = [pscustomobject]@{
        Shell = $shell; Handle = [pscustomobject]@{ IsCompleted = $true }; Action = 'Preview'
    }
    Set-BusyState $true
    Update-UiWorker
    Update-UiWorker
    if ($script:Worker -or $script:TestCompletionCount -ne 1 -or $script:TestDisposeCount -ne 1) {
        throw 'Failed worker was completed repeatedly'
    }
    if ($script:LastOperationError -notmatch 'Simulated workspace mismatch' -or -not $script:Controls.Settings.Enabled) {
        throw 'Failed worker did not restore UI or show inline error'
    }
    if ($script:Controls.Output.SelectedTab -ne $script:Controls.Log.Parent) { throw 'Runtime error did not select the log tab' }
    Write-Output 'Worker error regression passed: nested timer updates complete/dispose once, inline error, no popup.'
}

function Test-ChangeSearch {
    [void]$script:Controls.Changes.Handle
    $records = @(
        [pscustomobject]@{ change = '101'; user = 'Alice'; time = '1700000000'; desc = '修复开门 [x]' },
        [pscustomobject]@{ change = '102'; user = 'Bob'; time = '1700000001'; desc = 'Update movement' },
        [pscustomobject]@{ change = '103'; user = 'Alice'; time = '1700000002'; desc = ('x' * 260) + '尾部标记' }
    )
    Show-ChangeList $records
    $script:Controls.Changes.Items[0].Checked = $true
    if (-not $script:SelectedChanges.Contains(101)) { throw 'Checked-item event did not record selection' }
    foreach ($entry in @(@('102', 1), @('ALICE', 2), @('开门', 1), @('[x]', 1), @('尾部标记', 1), @('missing', 0))) {
        $script:Controls.ChangeSearch.Text = $entry[0]
        if ($script:Controls.Changes.Items.Count -ne $entry[1]) { throw "Search failed: $($entry[0])" }
    }
    $script:Controls.ChangeSearch.Text = 'Bob'
    $script:Controls.Changes.Items[0].Checked = $true
    $selected = @(ConvertTo-ChangeNumbers (Get-UiRequest).ChangeText)
    if (($selected -join ',') -ne '101,102') { throw 'Filtering lost a hidden selection' }
    Test-SelectedOverview
    $script:Controls.Changes.Items[0].Checked = $false
    $script:Controls.ChangeSearch.Clear()
    if (-not $script:Controls.Changes.Items[0].Checked -or $script:SelectedChanges.Count -ne 1) { throw 'Clearing search lost selection state' }
    $script:Controls.Source.SelectedItem = '//Depot/Target'
    if ($script:SelectedChanges.Count -ne 0 -or $script:Controls.Changes.Items.Count -ne 0) { throw 'Source change retained old CL selections' }
}

function Test-SelectedOverview {
    $script:Controls.ManualChanges.Text = '103, 104 101'
    Update-SelectedPreview
    $text = $script:Controls.SelectedDetails.Text
    foreach ($expected in @('已选 CL：4 个', 'CL 101', 'CL 102', 'CL 103', 'CL 104', 'Alice', 'Bob', '未加载提交人和说明')) {
        if (-not $text.Contains($expected)) { throw "Selected overview missing: $expected" }
    }
    if ($text.IndexOf('CL 101') -ge $text.IndexOf('CL 102') -or $text.IndexOf('CL 102') -ge $text.IndexOf('CL 103')) {
        throw 'Selected CL overview is not sorted'
    }
    $builds = $script:SelectedPreviewBuildCount
    $script:Controls.ChangeSearch.Text = 'Alice'
    if ($script:SelectedPreviewBuildCount -ne $builds) { throw 'Search rebuilt the unchanged selected overview' }
    $script:Controls.ChangeSearch.Text = 'Bob'
    $builds = $script:SelectedPreviewBuildCount
    $script:Controls.Changes.Items[0].Checked = $false
    if ($script:SelectedPreviewBuildCount -ne $builds + 1) { throw 'A selection change rebuilt the overview more than once' }
    $script:Controls.Changes.Items[0].Checked = $true
    $script:Controls.ManualChanges.Text = '101-103'
    if (-not $script:Controls.SelectedDetails.Text.Contains('手动输入有误')) { throw 'Invalid manual CL was not explained inline' }
    if ($script:Controls.Start.Enabled) { throw 'Changing selection retained an executable preview' }
    $script:Controls.ManualChanges.Clear()
    Test-SelectedOverviewBounds
    $script:Controls.Output.SelectedTab = $script:Controls.Details.Parent
    Test-TerminalRecovery
    Write-Output 'Selected CL overview passed: hidden checks, manual union/dedup, author/description, order and invalid input.'
}

function Test-TerminalRecovery {
    $module = Get-Module P4AutoMerge.Core
    $originalDirectory = & $module { $script:StateDirectory }
    $temporary = Join-Path $env:TEMP ('P4AutoMerge-RecoveryTest-' + [guid]::NewGuid().ToString('N'))
    $request = Get-UiRequest
    $originalSource = $request.Source
    $otherSource = @($script:Controls.Source.Items | Where-Object { $_ -cne $originalSource })[0]
    & $module {param($path) $script:StateDirectory=$path} $temporary
    try {
        foreach ($phase in @('Complete', 'Abandoned')) {
            $oldRequest = $request | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $oldRequest.Source = $otherSource
            $state = [pscustomobject]@{Request=$oldRequest; Phase=$phase; Pending=900; Changes=@(901); Index=1; Unresolved=@(); LastError=''}
            & $module {param($state) Save-MergeSession $state} $state
            $before = @($script:SelectedChanges | Sort-Object) -join ','
            $shell = [pscustomobject]@{}
            $shell | Add-Member ScriptMethod EndInvoke {param($handle) throw 'terminal recovery regression'}
            $shell | Add-Member ScriptMethod Dispose {}
            $script:Worker = [pscustomobject]@{Shell=$shell; Handle=[pscustomobject]@{IsCompleted=$true}; Action='Preview'}
            Update-UiWorker
            if ($script:Controls.Source.Text -cne $originalSource -or (@($script:SelectedChanges | Sort-Object) -join ',') -cne $before) {
                throw 'An old terminal queue replaced the current source or selections after preview failure'
            }
        }
    }
    finally { & $module {param($path) $script:StateDirectory=$path} $originalDirectory }
}

function Test-SelectedOverviewBounds {
    $savedNumbers = @($script:SelectedChanges)
    $savedDetails = $script:ChangeDetails
    try {
        $script:SelectedChanges.Clear()
        foreach ($number in 1001..2005) { [void]$script:SelectedChanges.Add($number) }
        $script:ChangeDetails = @{1001=[pscustomobject]@{user='tester'; desc=('long description ' * 1000)}}
        Invalidate-SelectedPreview
        Update-SelectedPreview
        $text = $script:Controls.SelectedDetails.Text
        if (-not $text.Contains('1005 个') -or -not $text.Contains('仅显示前 1000 个 CL') -or -not $text.Contains('说明已缩短')) {
            throw 'Selected overview did not limit visible entries/description'
        }
        if (@(ConvertTo-ChangeNumbers (Get-UiRequest).ChangeText).Count -ne 1005) { throw 'Selected overview truncated the actual request' }
    }
    finally {
        $script:SelectedChanges.Clear()
        foreach ($number in $savedNumbers) { [void]$script:SelectedChanges.Add($number) }
        $script:ChangeDetails = $savedDetails
        Invalidate-SelectedPreview
    }
}

function Test-SavedSelectedPreview {
    Update-SelectedPreview
    $text = $script:Controls.SelectedDetails.Text
    if (-not $text.Contains('已选 CL：2 个') -or -not $text.Contains('活动队列保存')) {
        throw 'Active queue selected overview did not use saved CLs'
    }
    $script:Controls.Output.SelectedTab = $script:Controls.Details.Parent
}

function Test-StartupConnection {
    Start-InitialConnection
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($script:Worker -and $watch.Elapsed.TotalSeconds -lt 30) {
        Update-UiWorker
        [Threading.Thread]::Sleep(20)
    }
    if ($script:Worker) { throw 'Startup connection did not complete within 30 seconds' }
    if ($script:LastOperationError) { throw $script:LastOperationError }
    if ($script:Controls.Client.Items.Count -eq 0 -or -not $script:Controls.Client.Text) { throw 'Startup did not populate/select a workspace' }
    if ($script:Controls.Target.Enabled -or $script:Controls.Target.Items.Count -gt 0) { throw 'Target enabled/populated before source selected' }
    Write-Output "READ-ONLY STARTUP OK: $($script:Controls.Client.Items.Count) workspaces; selected $($script:Controls.Client.Text); target empty/disabled before source. No window or mouse/keyboard input."
}

function Test-TargetScope {
    $script:Streams += @(
        [pscustomobject]@{ Stream = '//Depot/Dev'; Type = 'development'; Parent = '//Depot/Target'; Options = 'toparent fromparent mergedown'; firmerThanParent = 'false' },
        [pscustomobject]@{ Stream = '//Depot/Other'; Type = 'mainline'; Parent = 'none'; Options = ''; firmerThanParent = 'n/a' },
        [pscustomobject]@{ Stream = '//Depot/Virtual'; Type = 'virtual'; Parent = '//Depot/Target'; Options = ''; firmerThanParent = 'n/a' },
        [pscustomobject]@{ Stream = '//Other/External'; Type = 'mainline'; Parent = 'none'; Options = ''; firmerThanParent = 'n/a' }
    )
    $script:Controls.Source.SelectedItem = '//Depot/Source'
    if ($script:Controls.Target.Items.Count -ne 1 -or $script:Controls.Target.Text -ne '//Depot/Target') { throw 'Normal release targets incorrect' }
    $script:Controls.AllowCrossBranch.Checked = $true
    if ($script:Controls.Target.Items.Count -ne 3 -or -not (Get-CrossBranchMode (Get-UiRequest))) { throw 'Cross mode targets/request incorrect' }
    $script:Controls.Target.SelectedItem = '//Depot/Other'
    $script:Controls.Start.Enabled = $true
    $script:Controls.AllowCrossBranch.Checked = $false
    if ($script:Controls.Target.Items.Count -ne 1 -or $script:Controls.Target.Text -eq '//Depot/Other' -or $script:Controls.Start.Enabled) { throw 'Disabling cross mode retained invalid target/preview' }
    $script:Controls.Source.SelectedItem = '//Depot/Target'
    if ($script:Controls.Target.Items.Count -ne 1 -or -not $script:Controls.Target.Items.Contains('//Depot/Dev')) { throw 'Main targets ignore normal merge flow' }
    $script:Controls.AllowCrossBranch.Checked = $true
    $script:Controls.Target.SelectedItem = '//Depot/Source'
    $script:Controls.AllowCrossBranch.Checked = $false
    if ($script:Controls.Target.Text) { throw 'Disabling cross mode retained an unsupported target' }
    $script:Controls.Source.SelectedIndex = -1
    if ($script:Controls.Target.Enabled -or $script:Controls.Target.Items.Count -gt 0 -or $script:Controls.AllowCrossBranch.Enabled) { throw 'No-source target/mode controls are active' }
    $script:Controls.Source.SelectedItem = '//Depot/Source'
    Write-Output 'Target scope tests passed: normal/cross candidates, stale target clearing, disabled without source, persisted request mode.'
}

function Test-LargePreview {
    param($Request)
    $files = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt 2100; $index++) {
        $files.Add([pscustomobject]@{ action = 'integrate'; depotFile = "//Depot/Target/$index.txt" })
    }
    $preview = [pscustomobject]@{
        Request = $Request; Root = $env:TEMP; Changes = @(101)
        Items = @([pscustomobject]@{ Change = 101; Files = $files.ToArray() })
    }
    Show-Preview $preview
    if ($script:Controls.Details.Lines.Count -gt 2010 -or -not $script:Controls.Start.Enabled) {
        throw 'Preview display was not limited or start disabled'
    }
}

function Test-ReintegrateControl {
    $target = $script:Controls.Target.Text
    $targetCount = $script:Controls.Target.Items.Count
    $script:Preview = [pscustomobject]@{}
    $script:Controls.Start.Enabled = $true
    $script:Controls.ForceReintegrate.Checked = $true
    if ($script:Preview -or $script:Controls.Start.Enabled) { throw 'Reintegration change retained old preview' }
    if (-not (Get-ReintegrateMode (Get-UiRequest))) { throw 'Reintegration request missing mode' }
    if ($script:Controls.Target.Text -cne $target -or $script:Controls.Target.Items.Count -ne $targetCount) {
        throw 'Reintegration expanded or changed target candidates'
    }
    $script:Controls.ForceReintegrate.Checked = $false
    if (Get-ReintegrateMode (Get-UiRequest)) { throw 'Reintegration stayed enabled' }
    Write-Output 'Reintegration UI passed: explicit mode, preview invalidation, independent target scope.'
}

function Test-PreviewMessages {
    param($Request)
    $messages = @(for ($index = 0; $index -lt 5000; $index++) { [pscustomobject]@{ data = "message $index" } })
    $messages[0].data = ("long`nmessage " * 1000)
    $preview = [pscustomobject]@{
        Request=$Request; Root=$env:TEMP; Changes=@(101,102)
        Items=@(
            [pscustomobject]@{Change=101; Files=@(); Messages=$messages},
            [pscustomobject]@{Change=102; Files=@(); Messages=$messages}
        )
    }
    Show-Preview $preview
    $lines = @($script:Controls.Details.Lines)
    $displayed = @($lines | Where-Object { $_.StartsWith('  P4：') })
    if ($displayed.Count -ne $script:PreviewMessageLimit) { throw 'P4 messages were not bounded across CLs' }
    if ($displayed[0].Length -gt $script:PreviewMessageLength + 8) { throw 'Long P4 message was not truncated' }
    if (($lines -join ' ') -notmatch '9950' -or $script:Controls.Start.Enabled) { throw 'Omitted P4 messages or zero-file start state incorrect' }
    Write-Output 'Preview messages passed: global 50-message cap, long/multiline truncation, omitted count, no zero-file execution.'
}

Start-MergeUi
if ($env:P4AM_UPDATE_REQUEST -and (Test-Path -LiteralPath $env:P4AM_UPDATE_REQUEST)) { exit 42 }

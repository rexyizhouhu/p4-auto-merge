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
$script:SearchAuthor = ''
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
# 配色参考 VS Code 主题：底色区分区域，输入区接近白色或编辑器底色，强调色只用于按钮，文字和边框保持中性色。
$script:UiThemes = [ordered]@{
    Blue = @{ Label = '柔和蓝（默认）'; Dark = $false; Colors = @{
        Background = '#E3EFFB'; Field = '#FFFFFF'; Button = '#5A7DA3'; ButtonHover = '#4D6D90'; ButtonPressed = '#42607F'
        ButtonDisabled = '#D3DAE2'; Border = '#BFC9D4'; Divider = '#C9D5E2'; Text = '#2E3440'; DisabledText = '#8A94A0'; Hover = '#D6E4F2' } }
    LightModern = @{ Label = 'VS Code 浅色 (Light Modern)'; Dark = $false; Colors = @{
        Background = '#F8F8F8'; Field = '#FFFFFF'; Button = '#005FB8'; ButtonHover = '#0258A8'; ButtonPressed = '#024C91'
        ButtonDisabled = '#E1E1E1'; Border = '#CECECE'; Divider = '#E0E0E0'; Text = '#3B3B3B'; DisabledText = '#9A9A9A'; Hover = '#E8E8E8' } }
    QuietLight = @{ Label = 'VS Code 安静浅色 (Quiet Light)'; Dark = $false; Colors = @{
        Background = '#F3F3F3'; Field = '#FFFFFF'; Button = '#705697'; ButtonHover = '#634C86'; ButtonPressed = '#554174'
        ButtonDisabled = '#E0DCE6'; Border = '#C9C9C9'; Divider = '#DDDDDD'; Text = '#333333'; DisabledText = '#9A9A9A'; Hover = '#E4E0EB' } }
    SolarizedLight = @{ Label = 'VS Code Solarized 浅色'; Dark = $false; Colors = @{
        Background = '#EEE8D5'; Field = '#FDF6E3'; Button = '#586E75'; ButtonHover = '#4B5F66'; ButtonPressed = '#3F5056'
        ButtonDisabled = '#DDD6C1'; Border = '#CFC6AE'; Divider = '#DDD6C1'; Text = '#475B62'; DisabledText = '#93A1A1'; Hover = '#E3DCC7' } }
    DarkModern = @{ Label = 'VS Code 深色 (Dark Modern)'; Dark = $true; Colors = @{
        Background = '#1F1F1F'; Field = '#2B2B2B'; Button = '#0078D4'; ButtonHover = '#026EC1'; ButtonPressed = '#005FA8'
        ButtonDisabled = '#3A3D41'; Border = '#454545'; Divider = '#333333'; Text = '#CCCCCC'; DisabledText = '#6E7681'; Hover = '#37373D' } }
}
$script:UiThemeName = ''
$script:UiColors = @{}
$script:NativeThemeLoaded = $false
$script:SelectedPanelHeight = 130
$script:ActionRowHeight = 45
$script:OutputPages = @(@('Details', '预览 / 待手工处理'), @('Log', '运行日志'))
$script:OutputPage = ''
$script:OutputTabHeight = 30
$script:MenuBarHeight = 36
$script:ButtonHeight = 26
$script:ButtonPaddingX = 10
$script:ButtonMarginY = 3
$script:DescriptionColumnWidth = 650

function New-Control {
    param([string]$Type, [string]$Name, [string]$Text = '')
    $control = New-Object ("System.Windows.Forms.$Type")
    $control.Name = $Name
    $control.Text = $Text
    $control.Dock = 'Fill'
    $control.Margin = New-Object Windows.Forms.Padding(4)
    Set-ControlColors $control
    $script:Controls[$Name] = $control
    return $control
}

function Set-UiTheme {
    param([string]$Name)
    if (-not $script:UiThemes.Contains($Name)) { $Name = 'Blue' }
    $theme = $script:UiThemes[$Name]
    $colors = @{ Dark = [bool]$theme.Dark; ButtonText = [Drawing.Color]::White }
    foreach ($key in $theme.Colors.Keys) { $colors[$key] = [Drawing.ColorTranslator]::FromHtml($theme.Colors[$key]) }
    $script:UiThemeName = $Name
    $script:UiColors = $colors
}

function Update-UiTheme {
    param($Root)
    Update-ThemeTree $Root
    $Root.Invalidate($true)
}

function Update-ThemeTree {
    param($Control)
    Update-ControlColors $Control
    foreach ($child in $Control.Controls) { Update-ThemeTree $child }
}

# 事件处理只在创建时注册一次，颜色由 Update-ControlColors 按当前主题设置，切换主题时可整棵控件树重新上色。
function Set-ControlColors {
    param($Control)
    if ($Control -is [Windows.Forms.Button]) {
        $Control.UseVisualStyleBackColor = $false
        $Control.FlatStyle = 'Flat'
        $Control.Add_EnabledChanged({ Update-ControlColors $this })
        Set-ButtonMetrics $Control
    }
    elseif ($Control -is [Windows.Forms.ComboBox]) { Set-ComboColors $Control }
    if (Test-NativeThemeControl $Control) { $Control.Add_HandleCreated({ Set-NativeTheme $this }) }
    Update-ControlColors $Control
}

# 面板、标签、复选框等未显式设置底色的控件继承父容器底色，因此只需给窗口、分隔区和输入类控件设置底色。
function Update-ControlColors {
    param($Control)
    if ($Control -is [Windows.Forms.Button]) { Update-ButtonColors $Control; return }
    $Control.ForeColor = $script:UiColors.Text
    if ($Control -is [Windows.Forms.Form] -or $Control -is [Windows.Forms.SplitterPanel]) {
        $Control.BackColor = $script:UiColors.Background
    }
    elseif ($Control -is [Windows.Forms.SplitContainer]) { $Control.BackColor = $script:UiColors.Divider }
    elseif ((Test-FieldControl $Control) -or $Control.Tag -eq 'TextFrame') { $Control.BackColor = $script:UiColors.Field }
    # 系统网格线固定为浅灰，深色主题下会形成刺眼的白线。
    if ($Control -is [Windows.Forms.ListView]) { $Control.GridLines = -not $script:UiColors.Dark }
    if ($Control.IsHandleCreated -and (Test-NativeThemeControl $Control)) { Set-NativeTheme $Control }
}

function Test-NativeThemeControl {
    param($Control)
    return ($Control -is [Windows.Forms.Form] -or $Control -is [Windows.Forms.RichTextBox] -or $Control -is [Windows.Forms.ListView])
}

# 标题栏、滚动条和列表表头由系统绘制，深色主题需通过 DWM / uxtheme 切换；从未使用深色主题时不加载。
function Set-NativeTheme {
    param($Control)
    if (-not $script:UiColors.Dark -and -not $script:NativeThemeLoaded) { return }
    if (-not $script:NativeThemeLoaded) {
        Add-Type -Namespace P4AutoMerge -Name NativeTheme -MemberDefinition @'
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
[DllImport("uxtheme.dll", EntryPoint = "#135")] public static extern int SetPreferredAppMode(int mode);
[DllImport("uxtheme.dll", EntryPoint = "#133")] public static extern bool AllowDarkModeForWindow(IntPtr hwnd, bool allow);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
        $script:NativeThemeLoaded = $true
        # 滚动条和表头的深色样式需先允许应用使用深色模式（uxtheme 未公开序号，自 Windows 10 1903 起可用，旧系统忽略）。
        try { [void][P4AutoMerge.NativeTheme]::SetPreferredAppMode(1) } catch { }
    }
    $dark = [bool]$script:UiColors.Dark
    if ($Control -is [Windows.Forms.Form]) {
        $value = [int]$dark
        [void][P4AutoMerge.NativeTheme]::DwmSetWindowAttribute($Control.Handle, 20, [ref]$value, 4)
        # SWP_FRAMECHANGED | NOSIZE | NOMOVE | NOZORDER | NOACTIVATE：立即重绘已显示窗口的标题栏。
        [void][P4AutoMerge.NativeTheme]::SetWindowPos($Control.Handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x37)
        return
    }
    Set-WindowDarkMode $Control.Handle $dark 'DarkMode_Explorer'
    if ($Control -is [Windows.Forms.ListView]) {
        $header = [P4AutoMerge.NativeTheme]::SendMessage($Control.Handle, 0x101F, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($header -ne [IntPtr]::Zero) { Set-WindowDarkMode $header $dark 'DarkMode_ItemsView' }
    }
}

function Set-WindowDarkMode {
    param([IntPtr]$Handle, [bool]$Dark, [string]$DarkTheme)
    try { [void][P4AutoMerge.NativeTheme]::AllowDarkModeForWindow($Handle, $Dark) } catch { }
    $theme = $null
    if ($Dark) { $theme = $DarkTheme }
    [void][P4AutoMerge.NativeTheme]::SetWindowTheme($Handle, $theme, $null)
    [void][P4AutoMerge.NativeTheme]::SendMessage($Handle, 0x031A, [IntPtr]::Zero, [IntPtr]::Zero)
}

# 带视觉样式的下拉列表忽略 BackColor，自绘选中项和下拉项才能显示主题底色。
function Set-ComboColors {
    param($Combo)
    $Combo.FlatStyle = 'Flat'
    $Combo.DrawMode = 'OwnerDrawFixed'
    $Combo.Add_DrawItem({ Write-ComboItem $this $_ })
}

function Write-ComboItem {
    param($Combo, $Event)
    $selected = ($Event.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $back = $script:UiColors.Field
    if (-not $Combo.Enabled) { $back = $script:UiColors.Background }
    elseif ($selected) { $back = $script:UiColors.Hover }
    $brush = New-Object Drawing.SolidBrush($back)
    try { $Event.Graphics.FillRectangle($brush, $Event.Bounds) }
    finally { $brush.Dispose() }
    if ($Event.Index -lt 0) { return }
    $fore = $script:UiColors.Text
    if (-not $Combo.Enabled) { $fore = $script:UiColors.DisabledText }
    $flags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis, NoPrefix'
    [Windows.Forms.TextRenderer]::DrawText($Event.Graphics, $Combo.GetItemText($Combo.Items[$Event.Index]),
        $Combo.Font, $Event.Bounds, $fore, $flags)
}

# 带视觉样式的列表表头固定为系统浅色，自绘后才能跟随主题；数据行仍由系统绘制以保留复选框和选中效果。
function Write-ListHeader {
    param($Event)
    $bounds = $Event.Bounds
    $brush = New-Object Drawing.SolidBrush($script:UiColors.Field)
    $pen = New-Object Drawing.Pen($script:UiColors.Border)
    try {
        $Event.Graphics.FillRectangle($brush, $bounds)
        $Event.Graphics.DrawLine($pen, $bounds.Right - 1, $bounds.Top + 3, $bounds.Right - 1, $bounds.Bottom - 4)
        $Event.Graphics.DrawLine($pen, $bounds.Left, $bounds.Bottom - 1, $bounds.Right - 1, $bounds.Bottom - 1)
    }
    finally { $brush.Dispose(); $pen.Dispose() }
    $text = New-Object Drawing.Rectangle(($bounds.X + 6), $bounds.Y, [Math]::Max(0, $bounds.Width - 10), $bounds.Height)
    $flags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis, NoPrefix'
    [Windows.Forms.TextRenderer]::DrawText($Event.Graphics, $Event.Header.Text, $Event.Font, $text, $script:UiColors.Text, $flags)
}

function Test-FieldControl {
    param($Control)
    return ($Control -is [Windows.Forms.TextBoxBase] -or $Control -is [Windows.Forms.ListView] -or
        $Control -is [Windows.Forms.ComboBox] -or $Control -is [Windows.Forms.NumericUpDown])
}

function Update-ButtonColors {
    param($Button)
    if (@($script:OutputPages | Where-Object { $_[0] -eq [string]$Button.Tag }).Count) {
        Set-OutputTabColors $Button ($Button.Tag -eq $script:OutputPage); return
    }
    $Button.ForeColor = $script:UiColors.ButtonText
    $Button.FlatAppearance.MouseOverBackColor = $script:UiColors.ButtonHover
    $Button.FlatAppearance.MouseDownBackColor = $script:UiColors.ButtonPressed
    Update-ButtonState $Button
}

# 系统自动尺寸自带不对称留白，且默认最小宽 75，短文字按钮两侧空得多、长文字按钮几乎贴边。
# 因此统一为固定高度、文字宽度加固定左右间距；字体在加入窗口后才确定，需随字体和文字变化重新计算。
function Set-ButtonMetrics {
    param($Button)
    $Button.AutoSize = $false
    $Button.Dock = 'None'
    $Button.Anchor = 'Left'
    $Button.Margin = New-Object Windows.Forms.Padding(4, $script:ButtonMarginY, 4, $script:ButtonMarginY)
    $Button.Padding = New-Object Windows.Forms.Padding(0)
    $Button.Add_FontChanged({ Update-ButtonSize $this })
    $Button.Add_TextChanged({ Update-ButtonSize $this })
    Update-ButtonSize $Button
}

function Update-ButtonSize {
    param($Button)
    $flags = [Windows.Forms.TextFormatFlags]'NoPadding, SingleLine'
    $text = [Windows.Forms.TextRenderer]::MeasureText($Button.Text, $Button.Font, [Drawing.Size]::Empty, $flags)
    $Button.Size = New-Object Drawing.Size(($text.Width + 2 * $script:ButtonPaddingX), $script:ButtonHeight)
}

# 平面按钮禁用时文字固定为系统灰色，强调色底上看不清，因此禁用时换成低对比底色。
function Update-ButtonState {
    param($Button)
    $back = $script:UiColors.ButtonDisabled
    if ($Button.Enabled) { $back = $script:UiColors.Button }
    $Button.BackColor = $back
    $Button.FlatAppearance.BorderColor = $back
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
    $grid.RowCount = 3
    $grid.ColumnCount = 1
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 33)))
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 33)))
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $grid.Controls.Add((New-ListToolbar), 0, 0)
    $grid.Controls.Add((New-SearchToolbar), 0, 1)
    $list = New-Control 'ListView' 'Changes'
    $list.View = 'Details'
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.GridLines = -not $script:UiColors.Dark
    $list.ShowItemToolTips = $true
    $list.OwnerDraw = $true
    $list.Add_DrawColumnHeader({ Write-ListHeader $_ })
    $list.Add_DrawItem({ $_.DrawDefault = $true })
    $list.Add_DrawSubItem({ $_.DrawDefault = $true })
    # 表头右侧空白由系统绘制、无法跟随主题，因此让最后一列“说明”始终填满剩余宽度。
    $list.Add_ClientSizeChanged({ Update-ListFillColumn $this })
    foreach ($column in @(@('源 CL', 85), @('提交人', 110), @('日期', 145), @('说明', $script:DescriptionColumnWidth))) {
        [void]$list.Columns.Add($column[0], $column[1])
    }
    $grid.Controls.Add($list, 0, 2)
    return $grid
}

function Update-ListFillColumn {
    param($List)
    $last = $List.Columns[$List.Columns.Count - 1]
    $used = 0
    for ($index = 0; $index -lt $List.Columns.Count - 1; $index++) { $used += $List.Columns[$index].Width }
    $width = [Math]::Max($script:DescriptionColumnWidth, $List.ClientSize.Width - $used)
    if ($last.Width -ne $width) { $last.Width = $width }
}

function New-SearchToolbar {
    $bar = New-Control 'TableLayoutPanel' 'SearchToolbar'
    # 上下不留外边距，行高才能完整容纳按钮，标签、输入框和按钮在同一中线上。
    $bar.Margin = New-Object Windows.Forms.Padding(4, 0, 4, 0)
    $bar.ColumnCount = 5
    $bar.RowCount = 1
    [void]$bar.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    foreach ($width in @(165, 0, 90, 75, 225)) {
        $style = New-Object Windows.Forms.ColumnStyle('Absolute', $width)
        if ($width -eq 0) { $style.SizeType = 'Percent'; $style.Width = 100 }
        [void]$bar.ColumnStyles.Add($style)
    }
    $label = New-Control 'Label' 'SearchLabel' '搜索 CL / 提交人：'
    $label.TextAlign = 'MiddleLeft'
    $bar.Controls.Add($label, 0, 0)
    $search = New-Control 'TextBox' 'ChangeSearch'
    $search.Anchor = 'Left, Right'; $search.Dock = 'None'
    $search.AccessibleName = '仅搜索 CL 编号和提交人；输入完整提交人账号时优先精确筛选'
    $bar.Controls.Add($search, 1, 0)
    $clear = New-Control 'Button' 'ClearSearch' '清除搜索'
    $bar.Controls.Add($clear, 2, 0)
    $caption = New-Control 'Label' 'ManualLabel' '手动 CL：'
    $caption.TextAlign = 'MiddleLeft'
    $bar.Controls.Add($caption, 3, 0)
    $manual = New-Control 'TextBox' 'ManualChanges'
    $manual.Anchor = 'Left, Right'; $manual.Dock = 'None'
    $manual.AccessibleName = '补充 CL 编号，用逗号或空格分隔；与上方勾选的 CL 合并去重'
    $bar.Controls.Add($manual, 4, 0)
    return $bar
}

function New-ListToolbar {
    $bar = New-Control 'FlowLayoutPanel' 'ListToolbar'
    $bar.Margin = New-Object Windows.Forms.Padding(4, 0, 4, 0)
    $bar.WrapContents = $false
    foreach ($entry in @(@('Connect', '连接 / 刷新 workspace'), @('Fetch', '加载来源 CL'))) {
        $bar.Controls.Add((New-Control 'Button' $entry[0] $entry[1]))
    }
    $caption = New-Control 'Label' 'LimitLabel' '最近条数：'
    $caption.AutoSize = $true
    $bar.Controls.Add($caption)
    $limit = New-Control 'NumericUpDown' 'Limit'
    $limit.Minimum = 1
    $limit.Maximum = 1000
    $limit.Value = 1000
    $limit.Width = 70
    # 系统上下箭头无法跟随主题配色，隐藏后仍可输入、滚轮或方向键调整；原箭头位置系统固定画白底，需用主题色补上。
    $limit.Controls[0].Visible = $false
    $limit.Add_Paint({
        $edit = $this.Controls[1]
        $area = New-Object Drawing.Rectangle($edit.Right, 1, [Math]::Max(0, $this.ClientSize.Width - $edit.Right - 1), [Math]::Max(0, $this.ClientSize.Height - 2))
        $brush = New-Object Drawing.SolidBrush($this.BackColor)
        try { $_.Graphics.FillRectangle($brush, $area) }
        finally { $brush.Dispose() }
    })
    $bar.Controls.Add($limit)
    $count = New-Control 'Label' 'SearchCount' '尚未加载来源 CL'
    $count.AutoSize = $true
    $bar.Controls.Add($count)
    # 流式布局中停靠为 Fill 的控件贴行顶；取消停靠、仅左锚定时才与较高的按钮垂直居中对齐。
    foreach ($control in @($caption, $limit, $count)) { $control.Dock = 'None'; $control.Anchor = 'Left' }
    return $bar
}

function New-ActionPanel {
    $bar = New-Control 'FlowLayoutPanel' 'Actions'
    $bar.AutoSize = $true
    foreach ($entry in @(@('Preview', '1. 预览'), @('Start', '2. 执行合并'),
        @('Load', '恢复该 workspace 队列'), @('Resume', '检查并继续'),
        @('P4V', '在 P4V 打开 workspace'), @('Finish', '结束队列 (保留 CL)'))) {
        $bar.Controls.Add((New-Control 'Button' $entry[0] $entry[1]))
    }
    $script:Controls.Start.Enabled = $false
    $script:Controls.Resume.Enabled = $false
    $script:Controls.P4V.Enabled = $false
    $script:Controls.Finish.Enabled = $false
    return $bar
}

function New-OutputPanel {
    $panel = New-Control 'TableLayoutPanel' 'Output'
    $panel.ColumnCount = 1
    $panel.RowCount = 2
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $script:OutputTabHeight)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $strip = New-Control 'FlowLayoutPanel' 'OutputTabs'
    $strip.WrapContents = $false
    $strip.Margin = New-Object Windows.Forms.Padding(4, 4, 4, 0)
    $pages = New-Control 'Panel' 'OutputPages'
    foreach ($entry in $script:OutputPages) {
        $strip.Controls.Add((New-OutputTab $entry[0] $entry[1]))
        $pages.Controls.Add((New-TextArea $entry[0]))
    }
    $panel.Controls.Add($strip, 0, 0)
    $panel.Controls.Add($pages, 0, 1)
    Show-OutputPage 'Details'
    return $panel
}

function New-OutputTab {
    param([string]$Page, [string]$Caption)
    $tab = New-Control 'Button' ($Page + 'Tab') $Caption
    $tab.Margin = New-Object Windows.Forms.Padding(0, 0, 4, 0)
    $tab.Tag = $Page
    $tab.Add_Click({ Show-OutputPage ([string]$this.Tag) })
    return $tab
}

# 系统多行文本框的立体边框和常驻滚动条无法跟随主题，因此在面板上绘制 1 像素主题色边框、内含无边框的 RichTextBox，滚动条仅在内容超出时出现。
function New-TextArea {
    param([string]$Name)
    $frame = New-Control 'Panel' ($Name + 'Frame')
    $frame.Padding = New-Object Windows.Forms.Padding(6, 4, 1, 1)
    $frame.Tag = 'TextFrame'
    $frame.BackColor = $script:UiColors.Field
    $frame.Add_Paint({
        [Windows.Forms.ControlPaint]::DrawBorder($_.Graphics, $this.ClientRectangle, $script:UiColors.Border, 'Solid')
    })
    $text = New-Control 'RichTextBox' $Name
    Set-PlainRichText $text
    $text.Margin = New-Object Windows.Forms.Padding(0)
    $frame.Controls.Add($text)
    return $frame
}

# 默认 AutoFont 会为中文切换字体并把行高从 17 拉到 23 像素，UIFonts 保持与普通文本框一致的行高。
function Set-PlainRichText {
    param($Box)
    $Box.ReadOnly = $true
    $Box.DetectUrls = $false
    $Box.BorderStyle = 'None'
    $Box.ScrollBars = 'Vertical'
    $Box.LanguageOption = 'UIFonts'
}

function Show-OutputPage {
    param([string]$Name)
    foreach ($entry in $script:OutputPages) {
        $selected = $entry[0] -eq $Name
        $script:Controls[$entry[0] + 'Frame'].Visible = $selected
        Set-OutputTabColors $script:Controls[$entry[0] + 'Tab'] $selected
    }
    $script:OutputPage = $Name
}

function Set-OutputTabColors {
    param($Tab, [bool]$Selected)
    $back = $script:UiColors.Background
    $border = $script:UiColors.Background
    if ($Selected) { $back = $script:UiColors.Field; $border = $script:UiColors.Border }
    $Tab.BackColor = $back
    $Tab.ForeColor = $script:UiColors.Text
    $Tab.FlatAppearance.BorderColor = $border
    $Tab.FlatAppearance.MouseOverBackColor = $script:UiColors.Hover
    $Tab.FlatAppearance.MouseDownBackColor = $script:UiColors.Hover
}

# 界面由 powershell.exe 承载，不显式设置时标题栏和任务栏会显示 PowerShell 图标。
function Get-AppIcon {
    $executable = $env:P4AM_EXECUTABLE
    if ($executable -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return [Drawing.Icon]::ExtractAssociatedIcon($executable)
    }
    $source = Join-Path $PSScriptRoot 'P4AutoMerge.ico'
    if (Test-Path -LiteralPath $source -PathType Leaf) { return New-Object Drawing.Icon($source) }
    return $null
}

function New-MainForm {
    $form = New-Control 'Form' 'Main' 'P4 自动合并 — 默认安全 Resolve / 手动处理冲突'
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $form.Size = New-Object Drawing.Size(1220, (995 + $script:MenuBarHeight))
    $form.MinimumSize = New-Object Drawing.Size(1020, (955 + $script:MenuBarHeight))
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
    # 停靠按添加的逆序进行，后加入的菜单栏先占据顶部，内容区再填满剩余空间。
    $form.Controls.Add((New-MenuBar))
    Update-ResolveLabels
    return $form
}

function New-MenuBar {
    $bar = New-Control 'FlowLayoutPanel' 'MenuBar'
    $bar.Dock = 'Top'
    $bar.Height = $script:MenuBarHeight
    $bar.WrapContents = $false
    $bar.Margin = New-Object Windows.Forms.Padding(0)
    $bar.Padding = New-Object Windows.Forms.Padding(4, (($script:MenuBarHeight - $script:ButtonHeight) / 2), 0, 0)
    # 与其他操作按钮同样使用强调色底，避免和标签文字混淆、不易发现。
    $item = New-Control 'Button' 'SettingsMenu' '设置'
    $item.Margin = New-Object Windows.Forms.Padding(4, 0, 0, 0)
    $bar.Controls.Add($item)
    return $bar
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

function New-SelectedPanel {
    $group = New-Control 'GroupBox' 'SelectedGroup' '已选择的 CL — 自动刷新'
    $group.Controls.Add((New-TextArea 'SelectedDetails'))
    return $group
}

function New-ResizableContent {
    $split = New-Control 'SplitContainer' 'ContentSplit'
    $split.Orientation = 'Horizontal'
    $split.Size = New-Object Drawing.Size(1100, 550)
    $split.SplitterWidth = 6
    $split.Panel1MinSize = 400
    $split.Panel2MinSize = 110
    $split.SplitterDistance = 400
    $split.BackColor = $script:UiColors.Divider
    $split.Panel1.BackColor = $script:UiColors.Background
    $split.Panel2.BackColor = $script:UiColors.Background
    $split.AccessibleName = '上下拖动分隔条，调整来源 CL 列表和下方预览的高度'
    $hostPanel = New-Control 'TableLayoutPanel' 'SelectionHost'
    $hostPanel.ColumnCount = 1
    $hostPanel.RowCount = 3
    [void]$hostPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$hostPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $script:ActionRowHeight)))
    [void]$hostPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $script:SelectedPanelHeight)))
    $hostPanel.Controls.Add((New-SelectionPanel), 0, 0)
    $hostPanel.Controls.Add((New-ActionPanel), 0, 1)
    $hostPanel.Controls.Add((New-SelectedPanel), 0, 2)
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
            SearchText = "$($change.change) $($change.user)"
            User = [string]$change.user
            Item = New-ChangeListItem $change
        })
    }
    $script:ChangeCache = $cache.ToArray()
    Reset-Preview
    Update-FilteredChanges
    $script:Controls.Status.Text = "已加载 $($script:SourceChanges.Count) 个来源 CL。完整账号优先匹配提交人；搜索仅覆盖已加载条目，其他 CL 可在右侧输入编号。"
}

function Get-SearchAuthor {
    param([string]$Query)
    if (-not $Query) { return '' }
    foreach ($entry in $script:ChangeCache) {
        if ([string]::Equals($entry.User, $Query, [StringComparison]::OrdinalIgnoreCase)) { return $entry.User }
    }
    return ''
}

function Update-FilteredChanges {
    $query = $script:Controls.ChangeSearch.Text.Trim()
    $script:SearchAuthor = Get-SearchAuthor $query
    $script:UpdatingChanges = $true
    $list = $script:Controls.Changes
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $items = New-Object 'System.Collections.Generic.List[System.Windows.Forms.ListViewItem]'
        foreach ($entry in $script:ChangeCache) {
            if ($script:SearchAuthor -and -not [string]::Equals($entry.User, $script:SearchAuthor, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not $script:SearchAuthor -and $query -and $entry.SearchText.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
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
    if ($script:SearchAuthor) { $script:Controls.SearchCount.Text += "，提交人：$script:SearchAuthor" }
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
    Show-OutputPage 'Details'
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
    Show-OutputPage 'Details'
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
    Show-OutputPage 'Log'
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
    $script:Controls.CheckUpdate.Add_Click({ Start-UpdateOperation 'Check' -Manual })
    $script:Controls.SettingsMenu.Add_Click({ Show-UpdateSettings })
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
    Set-UiTheme $script:UpdatePreferences.Theme
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
        $form.Dispose()
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
            Test-CompactSearchRow
            Test-ListToolbarAlignment
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

function Test-ListToolbarAlignment {
    $button = $script:Controls.Connect
    $center = $button.Top + $button.Height / 2
    foreach ($name in @('LimitLabel', 'Limit', 'SearchCount')) {
        $control = $script:Controls[$name]
        if ([Math]::Abs(($control.Top + $control.Height / 2) - $center) -gt 1) {
            throw "List toolbar item is not vertically centered with the buttons: $name"
        }
    }
    $settings = $script:Controls.SettingsMenu
    if ($settings.Bottom -gt $script:Controls.MenuBar.ClientSize.Height -or $settings.Height -lt $button.Height) {
        throw 'Settings button is clipped or smaller than the action buttons'
    }
    Test-ButtonMetrics $script:Controls.Main
}

# 所有按钮同高、左右留白一致，且完整位于父容器内，不被行高裁切。
function Test-ButtonMetrics {
    param($Root)
    $flags = [Windows.Forms.TextFormatFlags]'NoPadding, SingleLine'
    foreach ($control in @(Get-ControlTree $Root | Where-Object { $_ -is [Windows.Forms.Button] })) {
        $text = [Windows.Forms.TextRenderer]::MeasureText($control.Text, $control.Font, [Drawing.Size]::Empty, $flags)
        if ($control.Height -ne $script:ButtonHeight -or $control.Width -ne $text.Width + 2 * $script:ButtonPaddingX) {
            throw "Button padding is not uniform: $($control.Name) $($control.Size)"
        }
        $parent = $control.Parent.ClientSize
        if ($control.Top -lt 0 -or $control.Bottom -gt $parent.Height -or $control.Right -gt $parent.Width) {
            throw "Button is clipped by its container: $($control.Name)"
        }
    }
}

function Get-ControlTree {
    param($Control)
    foreach ($child in $Control.Controls) { $child; Get-ControlTree $child }
}

function Test-CompactSearchRow {
    $bar = $script:Controls.SearchToolbar
    foreach ($name in @('ChangeSearch', 'ManualChanges')) {
        $field = $script:Controls[$name]
        if ($field.Parent -ne $bar -or $field.Right -gt $bar.ClientSize.Width -or $field.Width -lt 150) {
            throw "Compact search field is clipped or misplaced: $name"
        }
    }
    if ($script:Controls.ManualChanges.Multiline -or $script:Controls.Selection.RowCount -ne 3) {
        throw 'Large manual CL input area was not removed'
    }
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
    Test-ThemeControls
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
    if ($script:Controls.ContainsKey('SelectedWindow') -or $script:Controls.OutputPages.Controls.Count -ne 2 -or
        $script:Controls.SelectedDetails.FindForm() -ne $script:Controls.Main -or
        $script:Controls.SelectedGroup.Parent -ne $script:Controls.SelectionHost) { throw 'Selected CL overview is not embedded below the action buttons' }
    Write-Output 'Resolve controls passed: P4 labels with streams, safe default, invalidation, saved mode lock and embedded selected CL panel.'
}

function Test-UpdateControls {
    $savedRelease=$script:AvailableUpdate; $savedPreferences=$script:UpdatePreferences
    $module=Get-Module P4AutoMerge.Update
    $oldPath=& $module { $script:PreferencesPath }
    $path=Join-Path $env:TEMP ('P4AutoMerge-UpdateUiTest-' + [guid]::NewGuid().ToString('N') + '/settings.json')
    & $module { param($p) $script:PreferencesPath=$p } $path
    $script:AvailableUpdate=[pscustomobject]@{Version='9.0.0'; Notes="## 9.0.0`n- **Test** update log`r`n- run ``p4 info``"; Page='https://github.com/rexyizhouhu/p4-auto-merge/releases/tag/v9.0.0'}
    $script:UpdatePreferences=[pscustomobject]@{Frequency='Always'; SkippedVersion=''; LastPromptUtc=''}
    $dialog=New-UpdateDialog
    try {
        $dialog.Form.CreateControl(); $dialog.Form.PerformLayout()
        $grid=$dialog.Form.Controls[0]
        $buttons=@($grid.Controls[4].Controls | ForEach-Object { $_.Text })
        if (($buttons -join ',') -ne '更新,取消,跳过此版本' -or $dialog.Frequency.Items.Count -ne 4 -or
            -not $script:Controls.UpdateNotes.Text.Contains('Test update log')) { throw 'Update dialog choices, frequency or notes missing' }
        Test-MarkdownNotes $script:Controls.UpdateNotes
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
    Write-Output 'Update dialog passed hidden checks: markdown release notes, update/cancel/skip, four frequencies, settings persisted on skip/cancel. No dialog displayed.'
}

function Test-ThemeControls {
    $original = $script:UiThemeName
    $controls = $script:Controls
    try {
        if ($controls.MenuBar.Dock -ne 'Top' -or $controls.MenuBar.Top -ne 0 -or $controls.SettingsMenu.Text -ne '设置' -or
            $controls.CheckUpdate.Text -ne '检查更新' -or $controls.CheckUpdate.Parent -ne $controls.UpdateBar) {
            throw 'Settings menu is not at the top-left or check update button is missing'
        }
        foreach ($name in @($script:UiThemes.Keys)) {
            Set-UiTheme $name
            Update-UiTheme $controls.Main
            Test-ThemeColors $name
        }
        $dialog = New-UpdateDialog -Settings
        try {
            $buttons = @($dialog.Form.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.FlowLayoutPanel] } |
                ForEach-Object { $_.Controls } | ForEach-Object { $_.Text })
            $themeCombo = @($dialog.Form.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.ComboBox] })[1]
            if (($buttons -join ',') -ne '保存,取消' -or $themeCombo.Items.Count -ne $script:UiThemes.Count) {
                throw 'Settings dialog buttons or theme choices are wrong'
            }
            $dialog.Form.CreateControl(); $dialog.Form.PerformLayout()
            Test-ButtonMetrics $dialog.Form
            $themeCombo.SelectedIndex = [array]::IndexOf(@($script:UiThemes.Keys), 'DarkModern')
            if ($script:UiThemeName -ne 'DarkModern' -or $dialog.Form.BackColor.ToArgb() -ne $script:UiColors.Background.ToArgb()) {
                throw 'Theme choice did not preview in the settings dialog'
            }
            Test-ThemeColors 'DarkModern'
        }
        finally { $dialog.Form.Dispose() }
    }
    finally { Set-UiTheme $original; Update-UiTheme $controls.Main }
    Write-Output "Themes passed: top-left settings menu, bottom check update, $($script:UiThemes.Count) themes applied live and previewed from settings."
}

function Test-ThemeColors {
    param([string]$Name)
    $colors = $script:UiColors
    $expected = @(
        @('Main', 'BackColor', 'Background'), @('Connect', 'BackColor', 'Button'), @('Details', 'BackColor', 'Field'),
        @('DetailsFrame', 'BackColor', 'Field'), @('ContentSplit', 'BackColor', 'Divider'), @('Changes', 'BackColor', 'Field'),
        @('SettingsMenu', 'BackColor', 'Button'), @('Status', 'ForeColor', 'Text'), @('DetailsTab', 'BackColor', 'Field')
    )
    foreach ($entry in $expected) {
        if ($script:Controls[$entry[0]].($entry[1]).ToArgb() -ne $colors[$entry[2]].ToArgb()) {
            throw "Theme $Name did not color $($entry[0]).$($entry[1])"
        }
    }
    if ($script:Controls.Changes.GridLines -eq $colors.Dark) { throw "Theme $Name kept unsuitable list grid lines" }
}

function Test-MarkdownNotes {
    param($Box)
    $lines = @($Box.Lines | Where-Object { $_ })
    if (($lines -join '|') -cne '9.0.0|  •  Test update log|  •  run p4 info') {
        throw "Markdown notes were not split into rendered lines: $($lines -join '|')"
    }
    $Box.Select($Box.Text.IndexOf('Test'), 4)
    $bold = $Box.SelectionFont.Bold
    $Box.Select($Box.Text.IndexOf('9.0.0'), 5)
    if (-not $bold -or -not $Box.SelectionFont.Bold -or $Box.SelectionFont.Size -le $Box.Font.Size) {
        throw 'Markdown bold text or heading style was not rendered'
    }
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
    if ($script:OutputPage -ne 'Log') { throw 'Runtime error did not select the log tab' }
    Write-Output 'Worker error regression passed: nested timer updates complete/dispose once, inline error, no popup.'
}

function Test-ChangeSearch {
    Test-AuthorSearchCollision
    [void]$script:Controls.Changes.Handle
    $records = @(
        [pscustomobject]@{ change = '101'; user = 'Alice'; time = '1700000000'; desc = '修复开门 [x]' },
        [pscustomobject]@{ change = '102'; user = 'Bob'; time = '1700000001'; desc = 'Update movement' },
        [pscustomobject]@{ change = '103'; user = 'Alice'; time = '1700000002'; desc = ('x' * 260) + '尾部标记' }
    )
    Show-ChangeList $records
    $script:Controls.Changes.Items[0].Checked = $true
    if (-not $script:SelectedChanges.Contains(101)) { throw 'Checked-item event did not record selection' }
    foreach ($entry in @(@('102', 1), @('ALICE', 2), @('ali', 2), @('开门', 0), @('[x]', 0), @('尾部标记', 0), @('missing', 0))) {
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

function Test-AuthorSearchCollision {
    $records = @(
        [pscustomobject]@{ change = '201'; user = 'ta'; time = '1700000000'; desc = 'https://www.tapd.cn/issue/1' },
        [pscustomobject]@{ change = '202'; user = 'Bob'; time = '1700000001'; desc = 'https://www.tapd.cn/issue/2 ta' },
        [pscustomobject]@{ change = '203'; user = 'ta-helper'; time = '1700000002'; desc = 'https://www.tapd.cn/issue/3' }
    )
    Show-ChangeList $records
    $script:Controls.Changes.Items[1].Checked = $true
    foreach ($query in @('ta', 'TA', ' ta ')) {
        $script:Controls.ChangeSearch.Text = $query
        if ($script:Controls.Changes.Items.Count -ne 1 -or $script:Controls.Changes.Items[0].Text -ne '201') {
            throw 'Exact submitter search was polluted by TAPD links or other usernames'
        }
    }
    if (-not $script:SelectedChanges.Contains(202) -or -not $script:Controls.SearchCount.Text.Contains('提交人：ta')) {
        throw 'Author filtering lost a hidden selection or failed to explain its mode'
    }
    $script:Controls.ChangeSearch.Text = 'tapd'
    if ($script:Controls.Changes.Items.Count -ne 0) { throw 'Description still participates in search' }
    Clear-SourceChanges
    Write-Output 'Author search passed: exact ta beats TAPD/username substrings, case/space handling and hidden checks retained.'
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
    Show-OutputPage 'Details'
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
    Show-OutputPage 'Details'
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

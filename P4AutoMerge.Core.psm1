Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:LogQueue = $null
$script:P4Runner = $null
$script:P4Charsets = @{}
$script:StateDirectory = Join-Path $env:LOCALAPPDATA 'FlamesTools\P4AutoMerge'
$script:QueryTimeout = 120000
$script:WriteTimeout = 1800000
$script:BatchSize = 60

function Write-MergeLog {
    param([string]$Message)
    if ($script:LogQueue -and $script:LogQueue.Count -lt 10000) {
        $script:LogQueue.Enqueue(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message))
    }
}

function Get-OptionalValue {
    param($Object, [string]$Name, $Default = '')
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-P4Process {
    param([string[]]$Arguments, [AllowNull()][string]$InputText, [int]$Timeout, [string]$Executable = 'p4.exe')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command $Executable -ErrorAction Stop).Source
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        Start-P4Process $process
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            $bytes = $utf8.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($Timeout)) {
            $process.Kill()
            throw 'P4 命令超时；写操作可能已部分完成，请核对 pending CL，禁止盲目重试。'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode; Output = $stdout.Result; Error = $stderr.Result
        }
    }
    finally { $process.Dispose() }
}

function Start-P4Process {
    param($Process)
    $utf8 = New-Object Text.UTF8Encoding($false)
    if ($Process.StartInfo.PSObject.Properties['StandardInputEncoding']) {
        $Process.StartInfo.StandardInputEncoding = $utf8
        [void]$Process.Start()
        return
    }
    # .NET Framework creates and flushes the stdin writer inside Start(), before raw byte writes.
    [Threading.Monitor]::Enter([Console])
    $originalEncoding = $null
    try {
        $originalEncoding = [Console]::InputEncoding
        [Console]::InputEncoding = $utf8
        [void]$Process.Start()
    }
    finally {
        try {
            if ($null -ne $originalEncoding) { [Console]::InputEncoding = $originalEncoding }
        }
        finally { [Threading.Monitor]::Exit([Console]) }
    }
}

function Get-P4Defaults {
    $env:P4PORT = '192.168.60.201:1666'
    foreach ($name in @('P4USER', 'P4CLIENT')) {
        if ([Environment]::GetEnvironmentVariable($name)) { continue }
        $result = Invoke-P4Process @('set', $name) $null $script:QueryTimeout
        if ($result.Output -match ('(?m)^' + $name + '=([^\s]+)')) {
            [Environment]::SetEnvironmentVariable($name, $Matches[1])
        }
    }
    return [pscustomobject]@{ Server = $env:P4PORT; User = $env:P4USER; Client = $env:P4CLIENT }
}

function ConvertFrom-P4Output {
    param($Result, [string]$Command = '', [switch]$RejectReplacement)
    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ($Result.Output -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add(($line | ConvertFrom-Json)) }
        catch { throw "P4 返回了无法识别的输出：$line" }
    }
    if ($RejectReplacement) {
        foreach ($record in $records) { Assert-P4RecordEncoding $record }
    }
    $errors = @($records | Where-Object { [int](Get-OptionalValue $_ 'severity' 0) -ge 3 })
    if ($errors.Count -gt 0) {
        throw (($errors | ForEach-Object { Get-OptionalValue $_ 'data' }) -join "`n")
    }
    $warnings = @($records | Where-Object { [int](Get-OptionalValue $_ 'severity' 0) -eq 2 })
    foreach ($warning in $warnings) { Assert-ExpectedWarning $warning $Command }
    if ($Result.ExitCode -ne 0 -and ($warnings.Count -eq 0 -or $Result.Error)) {
        throw "P4 命令失败 ($($Result.ExitCode))：$($Result.Error) $($Result.Output)"
    }
    foreach ($record in $records) {
        $message = Get-OptionalValue $record 'data'
        if ($message) { Write-MergeLog $message.Trim() }
    }
    return $records.ToArray()
}

function Assert-ExpectedWarning {
    param($Record, [string]$Command)
    $alreadyIntegrated = '(?i)^(?:.* - )?all revision\(s\) already integrated\.\s*$'
    $patterns = @{
        opened = '(?i)^(?:.* - )?file\(s\) not opened on this client\.\s*$'
        merge = $alreadyIntegrated
        integrate = $alreadyIntegrated
        resolve = '(?i)^(?:.* - )?no file\(s\) to resolve\.\s*$'
        reconcile = '(?i)^(?:.* - )?no file\(s\) to reconcile\.\s*$'
    }
    $message = [string](Get-OptionalValue $Record 'data')
    if ([int](Get-OptionalValue $Record 'generic' 0) -ne 17 -or
        -not $patterns.ContainsKey($Command) -or $message -notmatch $patterns[$Command]) {
        throw "P4 返回需要检查的警告，队列已停止：$message"
    }
}

function Assert-P4RecordEncoding {
    param($Record)
    foreach ($property in $Record.PSObject.Properties) {
        if ($property.Value -is [string] -and $property.Value.Contains([char]0xFFFD)) {
            throw 'P4 返回了编码替换字符，已停止操作以免使用损坏的路径。非 Unicode 服务器的元数据需为 UTF-8；工具不猜测旧字符集。'
        }
    }
}

function Get-P4ConnectionArguments {
    param($Context, [string]$Charset)
    $arguments = @('-p', $Context.Server, '-C', $Charset, '-Q', $Charset)
    if ($Context.User) { $arguments += @('-u', $Context.User) }
    if ($Context.Client) { $arguments += @('-c', $Context.Client) }
    return $arguments
}

function Invoke-P4CommandProcess {
    param([string[]]$Arguments, [AllowNull()][string]$InputText, [int]$Timeout)
    if ($script:P4Runner) { return & $script:P4Runner $Arguments $InputText $Timeout }
    return Invoke-P4Process $Arguments $InputText $Timeout
}

function Get-P4ServerCharset {
    param($Context)
    $server = [string]$Context.Server
    if ([string]::IsNullOrWhiteSpace($server)) { throw '请先指定 P4 服务器。' }
    if ($script:P4Charsets.ContainsKey($server)) { return $script:P4Charsets[$server] }
    $arguments = @(Get-P4ConnectionArguments $Context 'none') + @('-ztag', '-Mj', 'info')
    $result = Invoke-P4CommandProcess $arguments $null $script:QueryTimeout
    $info = @(ConvertFrom-P4Output $result 'info' | Where-Object { Get-OptionalValue $_ 'serverVersion' })
    if ($info.Count -ne 1) { throw 'P4 服务器信息不完整，无法确认 Unicode 模式，已停止操作。' }
    $unicode = [string](Get-OptionalValue $info[0] 'unicode')
    $charset = 'none'
    if ($unicode -eq 'enabled') { $charset = 'utf8' }
    elseif ($unicode -notin @('', 'disabled')) { throw "无法识别 P4 Unicode 模式：$unicode" }
    $script:P4Charsets[$server] = $charset
    Write-MergeLog "P4 服务器 $server 的字符集模式：$charset"
    return $charset
}

function Invoke-P4 {
    param($Context, [string[]]$Command, [switch]$Write, [AllowNull()][string]$InputText)
    $hasInput = $PSBoundParameters.ContainsKey('InputText')
    $charset = Get-P4ServerCharset $Context
    $arguments = @(Get-P4ConnectionArguments $Context $charset)
    if (-not $hasInput) { $arguments += @('-ztag', '-Mj') }
    $arguments += $Command
    Write-MergeLog ('p4 ' + (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '))
    $timeout = $script:QueryTimeout
    if ($Write) { $timeout = $script:WriteTimeout }
    $result = Invoke-P4CommandProcess $arguments $InputText $timeout
    if (-not $hasInput) { return ConvertFrom-P4Output $result $Command[0] -RejectReplacement:($charset -eq 'none') }
    if ($result.ExitCode -ne 0) { throw "P4 创建 CL 失败：$($result.Output) $($result.Error)" }
    return $result.Output
}

function Get-P4Catalog {
    param($Context)
    $info = @(Invoke-P4 $Context @('info'))[0]
    $Context.User = $info.userName
    $clients = @(Invoke-P4 $Context @('clients', '-u', $Context.User) |
        Where-Object { Get-OptionalValue $_ 'client' })
    $streams = @(Invoke-P4 $Context @('streams') |
        Where-Object { Get-OptionalValue $_ 'Stream' })
    return [pscustomobject]@{ Context = $Context; Info = $info; Clients = $clients; Streams = $streams }
}

function Get-CrossBranchMode {
    param($Request)
    return Get-RequestBoolean $Request 'AllowCrossBranch'
}

function Get-ReintegrateMode {
    param($Request)
    return Get-RequestBoolean $Request 'ForceReintegrate'
}

function Get-RequestBoolean {
    param($Request, [string]$Name)
    $value = Get-OptionalValue $Request $Name $false
    return $value -is [bool] -and $value
}

function Test-ChildMergeDirection {
    param($Child, [bool]$ToParent)
    $options = @(([string](Get-OptionalValue $Child 'Options')) -split '\s+')
    $direction = 'fromparent'
    if ($ToParent) { $direction = 'toparent' }
    if ($options -notcontains $direction -or $options -contains "no$direction") { return $false }
    if ($options -contains 'mergeany') { return $true }
    $firmer = Get-OptionalValue $Child 'firmerThanParent'
    if ($firmer -notin @('true', 'false')) { return $false }
    return $ToParent -eq ($firmer -eq 'true')
}

function Test-ParentChildMergeDirection {
    param($Source, $Target)
    $sourceParent = Get-OptionalValue $Source 'baseParent' (Get-OptionalValue $Source 'Parent')
    $targetParent = Get-OptionalValue $Target 'baseParent' (Get-OptionalValue $Target 'Parent')
    if ($sourceParent -ceq $Target.Stream) {
        return Test-ChildMergeDirection $Source $true
    }
    if ($targetParent -ceq $Source.Stream) {
        return Test-ChildMergeDirection $Target $false
    }
    return $false
}

function Get-AllowedTargetStreams {
    param([string]$SourcePath, [object[]]$Streams, [bool]$AllowCrossBranch = $false)
    if (-not $SourcePath) { return @() }
    $sources = @($Streams | Where-Object { $_.Stream -ceq $SourcePath })
    if ($sources.Count -ne 1 -or (Get-OptionalValue $sources[0] 'Type') -eq 'virtual') { return @() }
    $depotEnd = $SourcePath.IndexOf('/', 2)
    if ($depotEnd -lt 0) { return @() }
    $prefix = $SourcePath.Substring(0, $depotEnd + 1)
    foreach ($target in $Streams) {
        if ($target.Stream -ceq $SourcePath -or -not $target.Stream.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        if ((Get-OptionalValue $target 'Type') -eq 'virtual') { continue }
        if ($AllowCrossBranch -or (Test-ParentChildMergeDirection $sources[0] $target)) { $target }
    }
}

function Assert-MergeDirection {
    param($Request)
    Assert-DepotRoot $Request.Source
    Assert-DepotRoot $Request.Target
    $source = @(Invoke-P4 $Request.Context @('stream', '-o', $Request.Source))[0]
    $target = @(Invoke-P4 $Request.Context @('stream', '-o', $Request.Target))[0]
    $allowed = @(Get-AllowedTargetStreams $Request.Source @($source, $target) (Get-CrossBranchMode $Request))
    if (@($allowed | Where-Object { $_.Stream -ceq $Request.Target }).Count -eq 0) {
        throw '此目标不符合当前合并范围。普通父子模式只允许直接父子分支且方向允许 merge；同仓库其他目标需明确勾选允许跨分支合并。'
    }
    if (-not (Get-CrossBranchMode $Request)) { Assert-SimpleStreamViews $Request.Context @($source, $target) }
}

function Assert-SimpleStreamSpec {
    param($Stream)
    $complex = @($Stream.PSObject.Properties | Where-Object {
        ($_.Name -match '^Remapped\d+$' -and [string]$_.Value) -or
        ($_.Name -match '^Paths\d+$' -and [string]$_.Value -match '^\s*isolate(?:\s|$)')
    })
    if ($complex.Count -gt 0) {
        throw "分支 '$($Stream.Stream)' 包含 isolate 或 Remapped 规则，普通父子模式无法保证完整合并所选 CL，已停止。请人工核对映射；工具不会自动切换强制跨分支模式。"
    }
}

function Assert-SimpleStreamViews {
    param($Context, [object[]]$Streams)
    $cache = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($stream in $Streams) { $cache[$stream.Stream] = $stream }
    foreach ($stream in $Streams) {
        $path = [string]$stream.Stream
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        while ($path -and $path -ne 'none') {
            if (-not $seen.Add($path)) { throw "分支继承关系存在循环：$path，已停止。" }
            $current = Get-CachedStreamSpec $Context $cache $path
            Assert-SimpleStreamSpec $current
            if ((Get-OptionalValue $current 'ParentView') -eq 'noinherit') { break }
            $path = [string](Get-OptionalValue $current 'Parent')
        }
    }
}

function Get-CachedStreamSpec {
    param($Context, $Cache, [string]$Path)
    if ($Cache.ContainsKey($Path)) { return $Cache[$Path] }
    $records = @(Invoke-P4 $Context @('stream', '-o', $Path))
    if ($records.Count -ne 1 -or (Get-OptionalValue $records[0] 'Stream') -cne $Path) {
        throw "无法读取继承分支：$Path，已停止。"
    }
    $Cache[$Path] = $records[0]
    return $Cache[$Path]
}

function ConvertTo-ChangeNumbers {
    param([string]$Text)
    $tokens = @($Text -split '[,，;；\s]+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { throw '请勾选或输入至少一个已提交 CL。' }
    $numbers = foreach ($token in $tokens) {
        $number = 0
        if (-not [int]::TryParse($token, [ref]$number) -or $number -le 0) {
            throw "CL 编号无效：$token；请用空格、逗号或换行分隔编号。"
        }
        $number
    }
    return @($numbers | Sort-Object -Unique)
}

function Assert-DepotRoot {
    param([string]$Path)
    if ($Path -notmatch '^//[^/\s@#%*]+/[^/\s@#%*]+(?:/[^/\s@#%*]+)*$' -or $Path.Contains('...')) {
        throw "请选择有效的分支根路径（不要带 /... 或修订号）：$Path"
    }
}

function Assert-Workspace {
    param($Context, [string]$Target)
    Assert-DepotRoot $Target
    $client = @(Invoke-P4 $Context @('client', '-o', $Context.Client))[0]
    if ((Get-OptionalValue $client 'Stream') -cne $Target) {
        throw "workspace 实际分支是 '$($client.Stream)'，与目标 '$Target' 不一致。"
    }
    $hostName = Get-OptionalValue $client 'Host'
    if ($hostName -and $hostName -ine $env:COMPUTERNAME) {
        throw "workspace 属于主机 '$hostName'，当前主机是 '$env:COMPUTERNAME'。"
    }
    if (-not (Test-Path -LiteralPath $client.Root -PathType Container)) {
        throw "workspace 本地目录不存在或不可访问：$($client.Root)"
    }
    if ((Get-OptionalValue $client 'StreamAtChange') -or (Get-OptionalValue $client 'Type') -ne 'writeable') {
        throw '请选择可写、未固定历史修订的 stream workspace。'
    }
    return $client
}

function Assert-CleanWorkspace {
    param($Context, [int]$AllowedChange = 0)
    $opened = @(Invoke-P4 $Context @('opened') | Where-Object { Get-OptionalValue $_ 'depotFile' })
    $foreign = @($opened | Where-Object { (Get-OptionalValue $_ 'change') -ne [string]$AllowedChange })
    if ($foreign.Count -gt 0) {
        throw "workspace 里已有其他打开的文件：$($foreign[0].depotFile)。请使用干净的合并 workspace。"
    }
}

function Get-SourceChanges {
    param($Request)
    Assert-DepotRoot $Request.Source
    $limit = [int]$Request.Limit
    if ($limit -lt 1 -or $limit -gt 1000) { throw 'CL 列表数量必须为 1–1000。' }
    return @(Invoke-P4 $Request.Context @('changes', '-s', 'submitted', '-l', '-m', "$limit", "$($Request.Source)/...") |
        Where-Object { Get-OptionalValue $_ 'change' })
}

function Get-SourceTargetFiles {
    param($Request, [int]$Change)
    $record = @(Invoke-P4 $Request.Context @('describe', '-s', "$Change"))[0]
    if ((Get-OptionalValue $record 'status') -ne 'submitted') { throw "CL $Change 尚未提交。" }
    $files = @($record.PSObject.Properties | Where-Object { $_.Name -match '^depotFile\d+$' })
    if ($files.Count -eq 0) { throw "CL $Change 不包含可合并文件。" }
    foreach ($file in $files) {
        if (-not $file.Value.StartsWith($Request.Source + '/', [StringComparison]::Ordinal)) {
            throw "CL $Change 包含来源分支之外的文件：$($file.Value)。请拆分选择或选择正确来源。"
        }
        $Request.Target + $file.Value.Substring($Request.Source.Length)
    }
}

function Assert-MappedTargets {
    param($Context, [string[]]$Files)
    for ($offset = 0; $offset -lt $Files.Count; $offset += $script:BatchSize) {
        $end = [Math]::Min($offset + $script:BatchSize - 1, $Files.Count - 1)
        $rows = @(Invoke-P4 $Context (@('where') + $Files[$offset..$end]))
        if (@($rows | Where-Object { $null -ne $_.PSObject.Properties['unmap'] }).Count -gt 0) {
            throw '所选 CL 的目标文件被 workspace 映射排除，无法完整合并。'
        }
        $mapped = @($rows | Where-Object { Get-OptionalValue $_ 'path' })
        if ($mapped.Count -ne $end - $offset + 1) { throw '目标文件未完整映射到本地 workspace。' }
    }
}

function Get-MergeCommand {
    param($Request, [int]$Change, [int]$Pending = 0, [switch]$Preview)
    if (Get-ReintegrateMode $Request) { return Get-ReintegrateCommand $Request $Change $Pending -Preview:$Preview }
    $force = Get-CrossBranchMode $Request
    $command = @('merge', '-Af')
    if ($force) { $command = @('merge', '-F') }
    if ($Preview) { $command += '-n' }
    if ($Pending -gt 0) { $command += @('-c', "$Pending") }
    if ($force) { return $command + @("$($Request.Source)/...@$Change,$Change", "$($Request.Target)/...") }
    return $command + @('--from', $Request.Source, "$($Request.Target)/...@$Change,$Change")
}

function Get-ReintegrateCommand {
    param($Request, [int]$Change, [int]$Pending = 0, [switch]$Preview)
    $command = @('integrate', '-Af', '-f', '-Rbd', '-Or')
    if ($Preview) { $command += '-n' }
    if ($Pending -gt 0) { $command += @('-c', "$Pending") }
    if (Get-CrossBranchMode $Request) {
        return $command + @('-F', "$($Request.Source)/...@$Change,$Change", "$($Request.Target)/...")
    }
    return $command + @('-S', $Request.Target, '-P', $Request.Source, '-r', "$($Request.Target)/...@$Change,$Change")
}

function Assert-UnopenedContent {
    param($Context, [string[]]$Files)
    for ($offset = 0; $offset -lt $Files.Count; $offset += $script:BatchSize) {
        $end = [Math]::Min($offset + $script:BatchSize - 1, $Files.Count - 1)
        $command = @('reconcile', '-n', '-I', '-a', '-e', '-d') + $Files[$offset..$end]
        $changed = @(Invoke-P4 $Context $command | Where-Object { Get-OptionalValue $_ 'depotFile' })
        if ($changed.Count -gt 0) {
            throw "待合并路径存在未 checkout 的本地新增、修改或删除：$($changed[0].depotFile)。请先处理。"
        }
    }
}

function Get-MergePreview {
    param($Request)
    Assert-DepotRoot $Request.Source
    if ($Request.Source -ceq $Request.Target) { throw '来源分支与目标分支不能相同。' }
    Assert-MergeDirection $Request
    $client = Assert-Workspace $Request.Context $Request.Target
    Assert-CleanWorkspace $Request.Context
    $changes = @(ConvertTo-ChangeNumbers $Request.ChangeText)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $targets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($change in $changes) {
        $filesToCheck = @(Get-SourceTargetFiles $Request $change)
        Assert-MappedTargets $Request.Context $filesToCheck
        $targets.AddRange([string[]]$filesToCheck)
        $rows = @(Invoke-P4 $Request.Context (Get-MergeCommand $Request $change -Preview))
        $files = @($rows | Where-Object { Get-OptionalValue $_ 'depotFile' })
        $actualTargets = @($files | ForEach-Object { $_.depotFile })
        if ($actualTargets.Count -gt 0) {
            Assert-MappedTargets $Request.Context $actualTargets
            $targets.AddRange([string[]]$actualTargets)
        }
        $items.Add([pscustomobject]@{ Change = $change; Files = $files; Messages = $rows })
    }
    $affected = @($targets | Sort-Object -Unique)
    if ($affected.Count -gt 0) { Assert-UnopenedContent $Request.Context $affected }
    return [pscustomobject]@{ Request = $Request; Changes = $changes; Items = $items.ToArray(); Root = $client.Root }
}

function Assert-NextChange {
    param($State, [int]$Change)
    Assert-MergeDirection $State.Request
    $targets = @(Get-SourceTargetFiles $State.Request $Change)
    Assert-MappedTargets $State.Request.Context $targets
    $rows = @(Invoke-P4 $State.Request.Context (Get-MergeCommand $State.Request $Change $State.Pending -Preview))
    $actual = @($rows | Where-Object { Get-OptionalValue $_ 'depotFile' } | ForEach-Object { $_.depotFile })
    $targets = @(($targets + $actual) | Sort-Object -Unique)
    Assert-MappedTargets $State.Request.Context $targets
    Assert-UnopenedContent $State.Request.Context $targets
}

function Get-SessionPath {
    param($Context)
    $identity = "$($Context.Server)|$($Context.User)|$($Context.Client)"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))) }
    finally { $algorithm.Dispose() }
    return Join-Path $script:StateDirectory ($hash.Replace('-', '') + '.json')
}

function Save-MergeSession {
    param($State)
    [void][IO.Directory]::CreateDirectory($script:StateDirectory)
    $path = Get-SessionPath $State.Request.Context
    $temp = "$path.tmp"
    $json = $State | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp, $path, "$path.bak") }
    else { [IO.File]::Move($temp, $path) }
}

function Read-MergeSession {
    param($Context)
    $path = Get-SessionPath $Context
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-PendingChange {
    param($State)
    $context = $State.Request.Context
    $description = "P4AutoMerge: $($State.Request.Source) -> $($State.Request.Target)"
    $description += "`n`tSource CLs: $($State.Changes -join ', ')`n`tResolve mode: safe (-as); manual review required."
    $description += "`n`tIgnore integration history: $(Get-ReintegrateMode $State.Request)"
    $form = "Change: new`nClient: $($context.Client)`nUser: $($context.User)`nDescription:`n`t$description`n"
    $output = Invoke-P4 $context @('change', '-i') -Write -InputText $form
    if ($output -notmatch 'Change (\d+) created') {
        throw "无法识别新建 CL 编号；请在 P4V 检查，不要重复创建。原始输出：$output"
    }
    return [int]$Matches[1]
}

function Get-UnresolvedFiles {
    param($State)
    return @(Invoke-P4 $State.Request.Context @('resolve', '-n', '-c', "$($State.Pending)") |
        Where-Object { (Get-OptionalValue $_ 'clientFile') -or (Get-OptionalValue $_ 'fromFile') })
}

function Get-PendingFiles {
    param($State)
    return @(Invoke-P4 $State.Request.Context @('opened', '-c', "$($State.Pending)") |
        Where-Object { Get-OptionalValue $_ 'depotFile' } | ForEach-Object { $_.depotFile })
}

function Assert-SessionFiles {
    param($State)
    $current = @(Get-PendingFiles $State)
    $missing = @($State.ExpectedOpened | Where-Object { $_ -cnotin $current })
    if ($missing.Count -gt 0) {
        throw "队列文件从 pending CL 中消失，可能被 revert：$($missing[0])。请在 P4V 核对；需要放弃文件时请结束队列跟踪。"
    }
}

function Assert-SessionOwner {
    param($State)
    [void](Assert-Workspace $State.Request.Context $State.Request.Target)
    $record = @(Invoke-P4 $State.Request.Context @('change', '-o', "$($State.Pending)"))[0]
    if ($record.Status -ne 'pending' -or $record.Client -cne $State.Request.Context.Client -or
        $record.User -cne $State.Request.Context.User) {
        throw "CL $($State.Pending) 不再是当前用户和 workspace 的待提交 CL；队列停止，请核对。"
    }
    Assert-CleanWorkspace $State.Request.Context $State.Pending
}

function Complete-CurrentChange {
    param($State)
    $State.Index = [int]$State.Index + 1
    $State.Phase = 'Ready'
    $State.Unresolved = @()
    Save-MergeSession $State
}

function Resolve-CurrentChange {
    param($State)
    [void](Invoke-P4 $State.Request.Context @('resolve', '-as', '-c', "$($State.Pending)") -Write)
    $State.ExpectedOpened = @(Get-PendingFiles $State)
    $State.Unresolved = @(Get-UnresolvedFiles $State)
    if ($State.Unresolved.Count -gt 0) {
        $State.Phase = 'Waiting'
        Save-MergeSession $State
        Write-MergeLog "剩余 $($State.Unresolved.Count) 个待手工处理项目。请在 P4V 解决，再点击检查并继续。"
        return $false
    }
    Complete-CurrentChange $State
    return $true
}

function Invoke-MergeQueue {
    param($State)
    while ([int]$State.Index -lt @($State.Changes).Count) {
        $change = [int]$State.Changes[$State.Index]
        Assert-SessionOwner $State
        Assert-SessionFiles $State
        Assert-NextChange $State $change
        Write-MergeLog "开始处理源 CL $change，结果放入 pending CL $($State.Pending)。"
        $State.Phase = 'Merging'
        Save-MergeSession $State
        [void](Invoke-P4 $State.Request.Context (Get-MergeCommand $State.Request $change $State.Pending) -Write)
        $State.ExpectedOpened = @(Get-PendingFiles $State)
        $State.Phase = 'Resolving'
        Save-MergeSession $State
        if (-not (Resolve-CurrentChange $State)) { return $State }
    }
    $State.Phase = 'Complete'
    Save-MergeSession $State
    Write-MergeLog "队列完成。请检查 pending CL $($State.Pending) 后自行提交。"
    return $State
}

function New-MergeSession {
    param($Request)
    $previous = Read-MergeSession $Request.Context
    if ($previous -and $previous.Phase -notin @('Complete', 'Abandoned')) {
        throw '此 workspace 已有未完成或结果不确定的队列，请先恢复并检查原队列。'
    }
    $preview = Get-MergePreview $Request
    $fileCount = @($preview.Items | ForEach-Object { $_.Files }).Count
    if ($fileCount -eq 0) { throw '没有需要合并的文件；未创建 pending CL。' }
    $state = [pscustomobject]@{
        Version = 1; Request = $Request; Changes = @($preview.Changes); Pending = 0
        Index = 0; Phase = 'Creating'; Unresolved = @(); ExpectedOpened = @()
        LastError = ''; Started = (Get-Date).ToString('o')
    }
    Save-MergeSession $state
    $state.Pending = New-PendingChange $state
    $state.Phase = 'Ready'
    Save-MergeSession $state
    return Invoke-MergeQueue $state
}

function Resume-MergeSession {
    param($Context)
    $state = Read-MergeSession $Context
    if (-not $state) { throw '此 workspace 没有保存的队列。' }
    if ($state.Phase -in @('Merging', 'Creating', 'Failed')) {
        throw "上次操作结果不确定：$($state.LastError)。请核对 pending CL $($state.Pending)，工具不会自动重复 merge。"
    }
    if ($state.Phase -in @('Complete', 'Abandoned')) { return $state }
    Assert-SessionOwner $state
    if ($state.Phase -in @('Waiting', 'Ready', 'Resolving')) { Assert-SessionFiles $state }
    if ($state.Phase -eq 'Resolving' -and -not (Resolve-CurrentChange $state)) { return $state }
    if ($state.Phase -eq 'Waiting') {
        $state.Unresolved = @(Get-UnresolvedFiles $state)
        if ($state.Unresolved.Count -gt 0) { Save-MergeSession $state; return $state }
        Complete-CurrentChange $state
    }
    return Invoke-MergeQueue $state
}

function Stop-MergeSession {
    param($Context)
    $state = Read-MergeSession $Context
    if (-not $state) { throw '此 workspace 没有保存的队列。' }
    $state.Phase = 'Abandoned'
    Save-MergeSession $state
    Write-MergeLog "已结束队列跟踪。pending CL $($state.Pending) 及 workspace 文件保留。"
    return $state
}

function Invoke-SessionOperation {
    param([string]$Action, $Request)
    try {
        switch ($Action) {
            'Start' { return New-MergeSession $Request }
            'Resume' { return Resume-MergeSession $Request.Context }
            'Finish' { return Stop-MergeSession $Request.Context }
        }
    }
    catch {
        $failure = $_
        $state = Read-MergeSession $Request.Context
        if ($state -and $state.Phase -notin @('Complete', 'Abandoned')) {
            $state.LastError = $failure.Exception.Message
            Save-MergeSession $state
        }
        throw $failure
    }
}

function Invoke-WithWorkspaceLock {
    param($Context, [scriptblock]$Operation)
    $client = @(Invoke-P4 $Context @('client', '-o', $Context.Client))[0]
    $root = [IO.Path]::GetFullPath($client.Root).TrimEnd('\', '/').ToUpperInvariant()
    $lockContext = [pscustomobject]@{ Server = 'local-workspace'; User = ''; Client = $root }
    $identity = [IO.Path]::GetFileNameWithoutExtension((Get-SessionPath $lockContext))
    $mutex = New-Object Threading.Mutex($false, "Local\P4AutoMerge-$identity")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '另一个工具窗口正在操作同一 workspace，请等待其完成。' }
        return & $Operation
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-MergeAction {
    param([string]$Action, $Request, $LogQueue)
    $script:LogQueue = $LogQueue
    switch ($Action) {
        'Catalog' { return Get-P4Catalog $Request.Context }
        'Changes' { return Get-SourceChanges $Request }
        'Preview' { return Get-MergePreview $Request }
        { $_ -in @('Start', 'Resume', 'Finish') } {
            return Invoke-WithWorkspaceLock $Request.Context { Invoke-SessionOperation $Action $Request }
        }
        'Load' { return Read-MergeSession $Request.Context }
        default { throw "未知操作：$Action" }
    }
}

function Open-P4VWorkspace {
    param($Context)
    $p4v = (Get-Command p4v.exe -ErrorAction Stop).Source
    $arguments = @('-p', $Context.Server, '-u', $Context.User, '-c', $Context.Client)
    $quoted = ($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    Start-Process -FilePath $p4v -ArgumentList $quoted
}

Export-ModuleMember -Function Get-P4Defaults, ConvertTo-ChangeNumbers, Invoke-MergeAction, Open-P4VWorkspace, Get-CrossBranchMode, Get-ReintegrateMode, Get-AllowedTargetStreams

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ProductVersion = '1.0.5'
$script:Repository = 'https://github.com/rexyizhouhu/p4-auto-merge'
$script:LatestApi = 'https://api.github.com/repos/rexyizhouhu/p4-auto-merge/releases/latest'
$script:LatestManifest = $script:Repository + '/releases/latest/download/update.json'
$script:MaximumInstallerBytes = 134217728
$script:PreferencesPath = Join-Path $env:LOCALAPPDATA 'FlamesTools/P4AutoMerge/update-settings.json'

function Get-UpdateVersion {
    return $script:ProductVersion
}

function Get-UpdatePreferences {
    param([string]$Path = $script:PreferencesPath)
    $result = [pscustomobject]@{ Frequency = 'Always'; SkippedVersion = ''; LastPromptUtc = ''; Theme = '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.Frequency -in @('Always', 'Weekly', 'Monthly', 'Never')) { $result.Frequency = $saved.Frequency }
        $result.SkippedVersion = [string]$saved.SkippedVersion
        $result.LastPromptUtc = [string]$saved.LastPromptUtc
        if ($saved.PSObject.Properties['Theme']) { $result.Theme = [string]$saved.Theme }
    }
    catch { return $result }
    return $result
}

function Save-UpdatePreferences {
    param($Preferences, [string]$Path = $script:PreferencesPath)
    if ($Preferences.Frequency -notin @('Always', 'Weekly', 'Monthly', 'Never')) { throw '更新提醒频率无效。' }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Preferences | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}

function Test-UpdateReminder {
    param($Preferences, [string]$Version, [datetime]$Now = [datetime]::UtcNow, [switch]$Manual)
    if ($Manual) { return $true }
    if ($Preferences.Frequency -eq 'Never' -or $Preferences.SkippedVersion -eq $Version) { return $false }
    if ($Preferences.Frequency -eq 'Always' -or -not $Preferences.LastPromptUtc) { return $true }
    try { $last = [datetime]::Parse($Preferences.LastPromptUtc).ToUniversalTime() }
    catch { return $true }
    if ($Preferences.Frequency -eq 'Weekly') { return $Now.ToUniversalTime() -ge $last.AddDays(7) }
    return $Now.ToUniversalTime() -ge $last.AddMonths(1)
}

function Read-UpdateResponse {
    param($Response, $Options)
    if ($Response.ResponseUri.Scheme -ne 'https') { throw '更新下载必须使用 HTTPS。' }
    if ($Response.ContentLength -gt $Options.MaximumBytes) { throw '更新响应超过大小限制。' }
    $inputStream = $Response.GetResponseStream()
    $outputStream = $null
    try {
        if ($Options.Output) { $outputStream = [IO.File]::Create($Options.Output) }
        else { $outputStream = New-Object IO.MemoryStream }
        Copy-UpdateResponse $inputStream $outputStream $Options.MaximumBytes
        if (-not $Options.Output) { return [Text.Encoding]::UTF8.GetString($outputStream.ToArray()) }
    }
    finally { $inputStream.Dispose(); if ($outputStream) { $outputStream.Dispose() } }
}

function Copy-UpdateResponse {
    param($InputStream, $OutputStream, [long]$MaximumBytes)
    $buffer = New-Object byte[] 32768
    $total = 0L
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (($count = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $count
        if ($total -gt $MaximumBytes -or $watch.Elapsed.TotalSeconds -gt 180) { throw '更新下载超过大小或时间限制。' }
        $OutputStream.Write($buffer, 0, $count)
    }
}

function Invoke-UpdateHttp {
    param($Options)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Options.Uri)
    $request.UserAgent = 'P4AutoMerge/' + $script:ProductVersion
    $request.Accept = 'application/vnd.github+json'
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 30000
    $response = $null
    try {
        $response = $request.GetResponse()
        return Read-UpdateResponse $response $Options
    }
    finally { if ($response) { $response.Dispose() }; $request.Abort() }
}

function ConvertTo-UpdateRelease {
    param($Release, [string]$CurrentVersion = $script:ProductVersion)
    if ($Release.draft -or $Release.prerelease) { throw '更新源不是正式发布版本。' }
    if ([string]$Release.tag_name -notmatch '^v?(\d+\.\d+\.\d+)$') { throw '更新版本号格式无效。' }
    $version = $Matches[1]
    if ([version]$version -le [version]$CurrentVersion) { return $null }
    $name = "P4AutoMerge-$version-Setup-x64.exe"
    $assets = @($Release.assets | Where-Object { $_.name -ceq $name })
    if ($assets.Count -ne 1) { throw '新版尚未提供唯一的 Windows x64 安装包。' }
    $asset = $assets[0]
    $url = $script:Repository + '/releases/download/' + $Release.tag_name + '/' + $name
    if ($asset.browser_download_url -cne $url -or $asset.state -ne 'uploaded') { throw '安装包地址或状态无效。' }
    if ($asset.size -le 0 -or $asset.size -gt $script:MaximumInstallerBytes) { throw '安装包大小无效。' }
    if ([string]$asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw '安装包缺少 SHA-256 校验值。' }
    $digest = $Matches[1].ToLowerInvariant()
    $notes = [string]$Release.body
    if ($notes.Length -gt 20000) { $notes = $notes.Substring(0, 20000) + "`r`n…更多内容请查看发布页。" }
    return [pscustomobject]@{
        Version = $version; Name = $name; Uri = $url; SHA256 = $digest
        Size = [long]$asset.size; Notes = $notes
        Page = $script:Repository + '/releases/tag/' + $Release.tag_name
    }
}

function Get-LatestUpdate {
    param([string]$CurrentVersion = $script:ProductVersion)
    $options = [pscustomobject]@{ Uri = $script:LatestManifest; Output = ''; MaximumBytes = 2097152 }
    try { $json = Invoke-UpdateHttp $options }
    catch [Net.WebException] {
        if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
        $options.Uri = $script:LatestApi
        $json = Invoke-UpdateHttp $options
    }
    $release = $json | ConvertFrom-Json
    return ConvertTo-UpdateRelease $release $CurrentVersion
}

function Save-UpdateInstaller {
    param($Release, [string]$Root = (Join-Path $env:LOCALAPPDATA 'FlamesTools/P4AutoMerge/Updates/Downloads'))
    if ($Release.Name -cne "P4AutoMerge-$($Release.Version)-Setup-x64.exe" -or
        $Release.Version -notmatch '^\d+\.\d+\.\d+$') { throw '安装包名称无效。' }
    $expected = $script:Repository + '/releases/download/v' + $Release.Version + '/' + $Release.Name
    $alternate = $script:Repository + '/releases/download/' + $Release.Version + '/' + $Release.Name
    if ($Release.Uri -cne $expected -and $Release.Uri -cne $alternate) { throw '安装包下载地址无效。' }
    $directory = Join-Path $Root ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory $Release.Name
    try {
        $options = [pscustomobject]@{ Uri = $Release.Uri; Output = $path; MaximumBytes = $script:MaximumInstallerBytes }
        Invoke-UpdateHttp $options
        if ((Get-Item -LiteralPath $path).Length -ne $Release.Size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Release.SHA256) { throw '更新安装包校验失败，已停止安装。' }
        return [pscustomobject]@{ Path = $path; SHA256 = $Release.SHA256; Version = $Release.Version }
    }
    catch { if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }; throw }
}

function Test-UpdateCanInstall {
    param([bool]$Busy, $Session)
    return -not $Busy -and (-not $Session -or $Session.Phase -in @('Complete', 'Abandoned'))
}

Export-ModuleMember -Function Get-UpdateVersion, Get-UpdatePreferences, Save-UpdatePreferences,
    Test-UpdateReminder, Get-LatestUpdate, Save-UpdateInstaller, Test-UpdateCanInstall

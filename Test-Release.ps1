param([Parameter(Mandatory = $true)][string]$ZipPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-ReleaseArchive {
    param([string]$Path)
    $expected = @('P4AutoMerge/P4AutoMerge.exe', 'P4AutoMerge/使用说明.txt',
        'P4AutoMerge/release.json', 'P4AutoMerge/.p4ignore', 'P4AutoMerge/SHA256SUMS.txt')
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        if ($names.Count -ne $expected.Count -or @(Compare-Object $expected $names).Count -gt 0) {
            throw 'ZIP 包含非发布文件或缺少文件。'
        }
    }
    finally { $archive.Dispose() }
    Write-Output 'PASS archive allowlist: only EXE, instructions, metadata, checksums and local ignore.'
}

function Assert-ReleaseContents {
    param([string]$Package)
    $manifest = Get-Content -LiteralPath (Join-Path $Package 'SHA256SUMS.txt') -Encoding UTF8
    foreach ($line in $manifest) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid checksum manifest line' }
        $expectedHash = $Matches[1]
        $actual = Get-FileHash -LiteralPath (Join-Path $Package $Matches[2]) -Algorithm SHA256
        if ($actual.Hash -ine $expectedHash) { throw '发布文件校验失败。' }
    }
    $exe = Join-Path $Package 'P4AutoMerge.exe'
    $bytes = [IO.File]::ReadAllBytes($exe)
    $header = [BitConverter]::ToInt32($bytes, 60)
    if ([BitConverter]::ToUInt32($bytes, $header) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $header + 4) -ne 0x8664 -or
        [BitConverter]::ToUInt16($bytes, $header + 24 + 68) -ne 2) { throw 'Expected x64 Windows GUI executable' }
    $assembly = [Reflection.Assembly]::LoadFile($exe)
    foreach ($name in @('P4AutoMerge.ps1', 'P4AutoMerge.Core.psm1', 'P4AutoMerge.Update.psm1', 'P4AutoMerge.UpdateUi.ps1')) {
        $resource = $assembly.GetManifestResourceStream($name)
        $memory = New-Object IO.MemoryStream
        try {
            $resource.CopyTo($memory)
            $expected = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name))
            if ([Convert]::ToBase64String($memory.ToArray()) -cne [Convert]::ToBase64String($expected)) {
                throw "内置文件不匹配当前已验证源码：$name"
            }
        }
        finally { $resource.Dispose(); $memory.Dispose() }
    }
    Write-Output 'PASS package hashes, x64 GUI PE header and embedded source bytes.'
}

function Invoke-PackagedCheck {
    param([string]$Exe, [string]$Mode, [string]$Expected)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = $Mode
    $info.WorkingDirectory = $env:TEMP
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = $info.StandardOutputEncoding
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(45000)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            throw "发布 EXE 验证超时：$Mode"
        }
        if ($process.ExitCode -ne 0 -or $output.Result -notmatch $Expected) {
            throw "发布 EXE 验证失败：$Mode`n$($output.Result)`n$($errors.Result)"
        }
        Write-Output $output.Result.Trim()
        Write-Output "PASS packaged EXE $Mode from Chinese/spaced path with unrelated working directory."
    }
    finally { $process.Dispose() }
}

$archivePath = (Resolve-Path -LiteralPath $ZipPath).Path
Assert-ReleaseArchive $archivePath
$testRoot = Join-Path $env:TEMP ('P4AutoMerge-ReleaseTest-' + [guid]::NewGuid().ToString('N'))
$unpacked = Join-Path $testRoot '中文 解压位置'
[void][IO.Directory]::CreateDirectory($unpacked)
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $unpacked)
$package = Join-Path $unpacked 'P4AutoMerge'
Assert-ReleaseContents $package
$exe = Join-Path $package 'P4AutoMerge.exe'
Invoke-PackagedCheck $exe '-HeadlessTest' 'UI state tests passed'
Invoke-PackagedCheck $exe '-ReadOnlyStartupTest' 'READ-ONLY STARTUP OK'
Write-Output 'Release verification passed. No mouse/keyboard input, visible test form or P4 write operations.'

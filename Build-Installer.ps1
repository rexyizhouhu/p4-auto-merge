param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [string]$CompilerPath = (Join-Path $env:LOCALAPPDATA 'FlamesTools/BuildTools/InnoSetup-7.1.1/Portable/ISCC.exe'),
    [string]$OutputRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')
if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot 'Releases' }

function Assert-InstallerInputs {
    $script:Package = (Resolve-Path -LiteralPath $PackageDirectory).Path
    if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) { throw '请指定已验证的 Inno Setup 编译器。' }
    $signature = Get-AuthenticodeSignature -LiteralPath $CompilerPath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
        throw 'Inno Setup 编译器签名不符合预期。'
    }
    foreach ($line in (Get-Content -LiteralPath (Join-Path $script:Package 'SHA256SUMS.txt') -Encoding UTF8)) {
        if ($line -notmatch '^([a-f0-9]{64})  ([^\\/]+)$') { throw '发布校验清单格式不正确。' }
        $expected = $Matches[1]
        $actual = Get-FileHash -LiteralPath (Join-Path $script:Package $Matches[2])
        if ($actual.Hash -ine $expected) { throw '安装器载荷校验失败。' }
    }
}

function Write-InstallerInstructions {
    param([string]$Path, [string]$Version)
    $text = @"
P4 自动合并工具 $Version 安装版（Windows x64）

双击 P4AutoMerge-$Version-Setup-x64.exe，按中文安装向导操作。
默认安装到当前用户的 LOCALAPPDATA\Programs\P4AutoMerge，可在向导中更改。
默认勾选“在桌面创建快捷方式”，也会创建开始菜单入口。不需要管理员权限。
可在 Windows 设置的“已安装的应用”中找到“P4 自动合并工具”并卸载。
卸载会移除程序和快捷方式，保留 LOCALAPPDATA\FlamesTools\P4AutoMerge 中的队列和诊断。
升级或卸载前请等待自动处理完成，并关闭工具窗口。

需要 Windows 10/11 x64、Windows PowerShell 5.1、.NET Framework 4.8，以及已安装并登录的 P4。
手工 Resolve 需要 P4V。本包不包含账号、登录票据、workspace 配置或本地合并队列。
安装后，独立“已选择的 CL”窗口自动显示全部勾选和手动输入的编号、提交人及说明。
搜索隐藏的勾选项仍会显示；手动编号未加载详情时会明确标记，执行前仍须点击“1. 预览”。
当前安装包未代码签名。安装器使用 Inno Setup（https://jrsoftware.org/）生成。
每次启动会检查 GitHub 新版；提示窗附更新日志，可更新、取消、跳过此版本及设置提醒频率。
仅确认后下载安装包并校验 SHA-256，队列结束后退出工具并启动原目录覆盖安装向导。
"@
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
}

function New-InstallerRelease {
    Assert-InstallerInputs
    $metadata = Get-Content -LiteralPath (Join-Path $script:Package 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $version = [string]$metadata.Version
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw '版本号格式不正确。' }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $directory = [IO.Path]::GetFullPath((Join-Path $OutputRoot ('Installer-' + $stamp)))
    [void][IO.Directory]::CreateDirectory($directory)
    $arguments = @('/Qp', ('/DPackageDir=' + $script:Package), ('/DOutputDir=' + $directory),
        ('/DAppVersion=' + $version), (Join-Path $PSScriptRoot 'Installer.iss'))
    & $CompilerPath @arguments
    if ($LASTEXITCODE -ne 0) { throw '安装包构建失败。' }
    $setup = Join-Path $directory "P4AutoMerge-$version-Setup-x64.exe"
    $readme = Join-Path $directory '安装说明.txt'
    Write-InstallerInstructions $readme $version
    $updateManifest = Join-Path $directory 'update.json'
    $notes = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CHANGELOG.md') -Raw -Encoding UTF8
    Write-UpdateManifest $setup $version $notes $updateManifest
    Write-PackageHashes $directory @([IO.Path]::GetFileName($setup), '安装说明.txt')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $zip = Join-Path $directory "P4AutoMerge-$version-Installer-x64.zip"
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @([IO.Path]::GetFileName($setup), '安装说明.txt', 'SHA256SUMS.txt')) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $directory $name), $name)
        }
    }
    finally { $archive.Dispose() }
    return [pscustomobject]@{Version=$version; Setup=$setup; Zip=$zip; UpdateManifest=$updateManifest; Package=$script:Package; Compiler=$CompilerPath; Directory=$directory}
}

New-InstallerRelease

param([string]$OutputRoot = (Join-Path $PSScriptRoot 'Releases'))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')

function Build-Launcher {
    param([string]$Output)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '缺少 Windows .NET Framework C# 编译器。' }
    $arguments = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll', "/out:$Output",
        ('/win32manifest:' + (Join-Path $PSScriptRoot 'Launcher.manifest')),
        ('/win32icon:' + (Join-Path $PSScriptRoot 'P4AutoMerge.ico')),
        ('/resource:' + (Join-Path $PSScriptRoot 'P4AutoMerge.ps1') + ',P4AutoMerge.ps1'),
        ('/resource:' + (Join-Path $PSScriptRoot 'P4AutoMerge.Core.psm1') + ',P4AutoMerge.Core.psm1'),
        ('/resource:' + (Join-Path $PSScriptRoot 'P4AutoMerge.Update.psm1') + ',P4AutoMerge.Update.psm1'),
        ('/resource:' + (Join-Path $PSScriptRoot 'P4AutoMerge.UpdateUi.ps1') + ',P4AutoMerge.UpdateUi.ps1'),
        (Join-Path $PSScriptRoot 'Launcher.cs'))
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Output)) { throw '工具 EXE 构建失败。' }
}

function Write-ReleaseInstructions {
    param([string]$Path, [string]$Version)
    $text = @"
P4 自动合并工具 $Version（Windows x64）

使用前准备
1. Windows 10/11 x64，Windows PowerShell 5.1 与 .NET Framework 4.8。
2. 安装 P4 命令行工具 p4.exe，加入 PATH，并在自己的账号下完成 P4 登录。
3. 安装 P4V，用于手工 Resolve。使用一个本机存在、绑定正确 stream 的干净 workspace。
4. 本包不包含 P4/P4V 安装程序、登录凭据、任何人的 workspace 配置或本地队列。

启动和操作
1. 完整解压 ZIP，双击 P4AutoMerge.exe。不需要管理员权限或额外打包器。
2. 默认服务器 192.168.60.201:1666；可以在界面修改。工具读取当前用户的 P4 身份。
3. 选择目标 workspace 和来源 stream，再选择目标 stream。未选择来源前目标不可选。
4. 默认仅父子分支且方向允许 merge；勾选“允许跨分支合并”才显示其他同仓库目标。
5. 加载来源 CL，可搜索 CL 编号和提交人；输入完整账号时精确筛选该提交人。
   搜索隐藏的勾选项仍参与合并；其他 CL 可在搜索栏右侧“手动 CL”输入编号。
   独立“已选择的 CL”窗口自动显示勾选及手动输入合并后的编号、顺序、提交人和说明。
   未加载详情的手动编号会明确标记；必须再点“1. 预览”检查来源和文件操作。
6. 需要重合已合入或撤销的 CL 时，可勾选“强制重新合并”；作用于本次全部所选 CL。
7. 先预览，再执行。CL 按升序处理，结果放入一个 pending CL。
8. 自动 Resolve 只使用 -as；需要合并内容的项目留给你在 P4V 手工处理。
9. 在 P4V 确认 Resolve 完成后，回工具点击“检查并继续”。最后自行检查并提交。

注意事项
- 工具不会自动 submit、sync、revert 或编译。merge 自身可能按 P4 正常语义更新文件。
- 普通父子模式遇到 isolate 或 Remapped 等复杂视图会停止，请人工核对。
- “0 个文件/已合并”指 P4 的合并历史，不能证明目标内容之后未被撤销。
- 写入结果不确定时保留 pending CL 并停止，不要反复点击执行。
- 不要同时使用其他窗口或 P4V 修改正在自动处理的 workspace。
- 不要在尚未处理完的队列中 revert 文件；需要放弃时先核对并结束队列跟踪。
- 发布文件仅本地保留，随包 .p4ignore 可防止常规添加到 P4。

本地数据
EXE 内置界面和核心脚本，首次运行解出到当前用户 LOCALAPPDATA 下的
FlamesTools\P4AutoMerge\Runtime；队列和诊断也保存在 FlamesTools\P4AutoMerge。
每次启动通过 GitHub 检查正式新版。提示窗显示更新日志，可更新、取消、跳过此版本，
并可直接选择每次启动、每周、每月或永不提醒；底部“更新 / 设置”也可更改。
仅确认更新后下载安装包，SHA-256 校验通过且队列结束后关闭工具并启动安装向导。
便携版更新会安装新版，保留原便携文件；源码启动只打开下载页。
每个人使用自己的 P4 身份和队列，不需要 GitHub 账号、令牌或 Git。
SHA256SUMS.txt 可校验发布文件完整性。此版本尚未进行代码签名。
"@
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
}

function New-ReleasePackage {
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $destination = [IO.Path]::GetFullPath((Join-Path $OutputRoot $stamp))
    $package = Join-Path $destination 'P4AutoMerge'
    [void][IO.Directory]::CreateDirectory($package)
    $exe = Join-Path $package 'P4AutoMerge.exe'
    Build-Launcher $exe
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    Write-ReleaseInstructions (Join-Path $package '使用说明.txt') $version
    [IO.File]::WriteAllText((Join-Path $package '.p4ignore'), "*`r`n", (New-Object Text.UTF8Encoding($false)))
    $metadata = [ordered]@{ Product='P4AutoMerge'; Version=$version; Platform='Windows x64'; BuiltUtc=(Get-Date).ToUniversalTime().ToString('o') }
    $metadataJson = $metadata | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $package 'release.json'), $metadataJson, (New-Object Text.UTF8Encoding($false)))
    Write-PackageHashes $package @('P4AutoMerge.exe', '使用说明.txt', 'release.json', '.p4ignore')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $destination ("P4AutoMerge-$version-win-x64-$stamp.zip")
    [IO.Compression.ZipFile]::CreateFromDirectory($package, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    return [pscustomobject]@{Version=$version; Exe=$exe; Zip=$zip; ZipSHA256=(Get-FileHash -LiteralPath $zip).Hash; Directory=$destination}
}

New-ReleasePackage

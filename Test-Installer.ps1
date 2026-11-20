param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [string]$CompilerPath = (Join-Path $env:LOCALAPPDATA 'FlamesTools/BuildTools/InnoSetup-7.1.1/Portable/ISCC.exe')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:TestId = [guid]::NewGuid().ToString('N')
$script:TestRoot = Join-Path $env:TEMP ('P4AutoMerge-InstallerValidation-' + $script:TestId)
$script:InstallDir = Join-Path $script:TestRoot '中文 安装目录'
$script:RegistryKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\P4AM.Test.' + $script:TestId + '_is1'
$script:Package = (Resolve-Path -LiteralPath $PackageDirectory).Path
[void][IO.Directory]::CreateDirectory($script:TestRoot)

function Build-ValidationInstaller {
    $metadata = Get-Content -LiteralPath (Join-Path $script:Package 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $arguments = @('/Qp', ('/DPackageDir=' + $script:Package), ('/DOutputDir=' + $script:TestRoot),
        ('/DAppVersion=' + $metadata.Version), ('/DValidationRoot=' + $script:TestRoot),
        ('/DValidationId=' + $script:TestId), (Join-Path $PSScriptRoot 'Installer.iss'))
    & $CompilerPath @arguments
    if ($LASTEXITCODE -ne 0) { throw '隔离测试安装器构建失败。' }
    return Join-Path $script:TestRoot 'P4AutoMerge-Validation.exe'
}

function Invoke-SilentProcess {
    param([string]$File, [string[]]$Arguments, [switch]$AllowFailure)
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0 -and -not $AllowFailure) { throw "隔离验证进程失败：$File，退出码 $($process.ExitCode)" }
    return $process.ExitCode
}

function Get-InstallArguments {
    param([string]$Name)
    return @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
        ('/DIR="' + $script:InstallDir + '"'), ('/LOG="' + (Join-Path $script:TestRoot ($Name + '.log')) + '"'))
}

function Assert-InstalledPackage {
    foreach ($name in @('P4AutoMerge.exe', '使用说明.txt', 'release.json', 'SHA256SUMS.txt', '.p4ignore')) {
        $expected = (Get-FileHash -LiteralPath (Join-Path $script:Package $name)).Hash
        if ((Get-FileHash -LiteralPath (Join-Path $script:InstallDir $name)).Hash -cne $expected) { throw "安装文件不匹配：$name" }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RegistryKey)
    if (-not $key) { throw '未创建当前用户的卸载入口。' }
    try {
        if ([string]$key.GetValue('InstallLocation').TrimEnd('\') -ine $script:InstallDir.TrimEnd('\')) { throw '卸载入口安装目录错误。' }
        if (-not $key.GetValue('UninstallString')) { throw '卸载入口没有卸载命令。' }
    }
    finally { $key.Dispose() }
    $shell = New-Object -ComObject WScript.Shell
    $explorer = New-Object -ComObject Shell.Application
    try {
        foreach ($relative in @('Desktop/P4 自动合并工具.lnk', 'StartMenu/P4 自动合并工具.lnk')) {
            $path = Join-Path $script:TestRoot $relative
            if (-not (Test-Path -LiteralPath $path)) { throw "未创建测试快捷方式：$relative" }
            $link = $shell.CreateShortcut($path)
            if ($link.TargetPath -ine (Join-Path $script:InstallDir 'P4AutoMerge.exe') -or $link.WorkingDirectory -ine $script:InstallDir) { throw '快捷方式目标或工作目录错误。' }
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
            # 任务栏按应用身份合并按钮、决定图标；快捷方式必须与界面进程声明的身份一致。
            $item = $explorer.NameSpace([IO.Path]::GetDirectoryName($path)).ParseName([IO.Path]::GetFileName($path))
            if ([string]$item.ExtendedProperty('System.AppUserModel.ID') -cne 'FlamesTools.P4AutoMerge') { throw "快捷方式缺少任务栏应用身份：$relative" }
        }
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($explorer)
    }
    Write-Output 'PASS install: exact payload, HKCU uninstall entry, desktop/start menu shortcut targets and taskbar identity.'
}

function Remove-ValidationInstallation {
    $uninstaller = Join-Path $script:InstallDir 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstaller)) { return }
    [void](Invoke-SilentProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        ('/LOG="' + (Join-Path $script:TestRoot 'uninstall.log') + '"')))
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RegistryKey)
    if ($key) { $key.Dispose(); throw '测试卸载入口未删除。' }
    foreach ($path in @((Join-Path $script:InstallDir 'P4AutoMerge.exe'),
        (Join-Path $script:TestRoot 'Desktop/P4 自动合并工具.lnk'),
        (Join-Path $script:TestRoot 'StartMenu/P4 自动合并工具.lnk'))) {
        if (Test-Path -LiteralPath $path) { throw '测试程序或快捷方式未卸载。' }
    }
    Write-Output 'PASS uninstall: application, shortcuts and HKCU uninstall entry removed.'
}

function Test-InstalledExecutable {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $script:InstallDir 'P4AutoMerge.exe'
    $info.Arguments = '-HeadlessTest'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(45000)) { & taskkill.exe /PID $process.Id /T /F | Out-Null; throw 'Installed EXE self-test timeout' }
        if ($process.ExitCode -ne 0 -or $output.Result -notmatch 'Selected CL overview passed') { throw ('Installed EXE self-test failed: ' + $errors.Result + $output.Result) }
        Write-Output 'PASS installed EXE: hidden UI and selected-CL regression.'
    }
    finally { $process.Dispose() }
}

$installer = Build-ValidationInstaller
try {
    [void](Invoke-SilentProcess $installer (Get-InstallArguments 'install'))
    Assert-InstalledPackage
    Test-InstalledExecutable
    $sentinel = Join-Path $script:InstallDir 'USER-DATA-MUST-REMAIN.txt'
    [IO.File]::WriteAllText($sentinel, 'user data sentinel')
    [void](Invoke-SilentProcess $installer (Get-InstallArguments 'upgrade'))
    Assert-InstalledPackage
    if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Upgrade deleted an unrelated file' }
    Write-Output 'PASS same-version reinstall preserves an unrelated user file.'
    $running = New-Object Threading.Mutex($false, 'Local\FlamesTools.P4AutoMerge.Running')
    try {
        $uninstaller = Join-Path $script:InstallDir 'unins000.exe'
        $code = Invoke-SilentProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            ('/LOG="' + (Join-Path $script:TestRoot 'running-uninstall-blocked.log') + '"')) -AllowFailure
        if ($code -eq 0) { throw 'Uninstall did not block a running application' }
        Assert-InstalledPackage
        Write-Output 'PASS uninstall blocks a running application and preserves files, shortcuts and registry.'
    }
    finally { $running.Dispose() }
}
finally { Remove-ValidationInstallation }
if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Uninstall deleted an unrelated user file' }
try {
    [void](Invoke-SilentProcess $installer ((Get-InstallArguments 'without-desktop') + @('/MERGETASKS=!desktopicon')))
    if (Test-Path -LiteralPath (Join-Path $script:TestRoot 'Desktop/P4 自动合并工具.lnk')) { throw 'Desktop opt-out was ignored' }
    Write-Output 'PASS desktop shortcut opt-out.'
}
finally { Remove-ValidationInstallation }
$lifetime = New-Object Threading.Mutex($false, 'Local\FlamesTools.P4AutoMerge.Running')
try {
    $exitCode = Invoke-SilentProcess $installer (Get-InstallArguments 'running-app-blocked') -AllowFailure
    if ($exitCode -eq 0 -or (Test-Path -LiteralPath (Join-Path $script:InstallDir 'P4AutoMerge.exe'))) { throw 'Installer did not block a running application' }
    Write-Output 'PASS installer blocks a running application without terminating it.'
}
finally { $lifetime.Dispose() }
Write-Output ('Installer validation passed in isolated directory: ' + $script:TestRoot)
Write-Output 'No real desktop/start-menu shortcuts, no P4 writes, no mouse/keyboard input.'

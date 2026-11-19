function Write-PackageHashes {
    param([string]$Directory, [string[]]$Names)
    $lines = foreach ($name in $Names) {
        $hash = Get-FileHash -LiteralPath (Join-Path $Directory $name) -Algorithm SHA256
        $hash.Hash.ToLowerInvariant() + '  ' + $name
    }
    [IO.File]::WriteAllLines((Join-Path $Directory 'SHA256SUMS.txt'), [string[]]$lines,
        (New-Object Text.UTF8Encoding($false)))
}

function Write-UpdateManifest {
    param([string]$Setup, [string]$Version, [string]$Notes, [string]$Output)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw '更新清单版本无效。' }
    $name = [IO.Path]::GetFileName($Setup)
    if ($name -cne "P4AutoMerge-$Version-Setup-x64.exe") { throw '更新清单安装包名称无效。' }
    $asset = [ordered]@{
        name=$name; state='uploaded'; size=(Get-Item -LiteralPath $Setup).Length
        digest=('sha256:' + (Get-FileHash -LiteralPath $Setup -Algorithm SHA256).Hash.ToLowerInvariant())
        browser_download_url="https://github.com/rexyizhouhu/p4-auto-merge/releases/download/v$Version/$name"
    }
    # 1.0.2、1.0.3 的更新窗口用普通文本框显示日志，只认 CRLF 换行。
    $body = $Notes -replace '\r?\n', "`r`n"
    $manifest = [ordered]@{ tag_name="v$Version"; draft=$false; prerelease=$false; body=$body; assets=@($asset) }
    [IO.File]::WriteAllText($Output, ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

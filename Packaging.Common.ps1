function Write-PackageHashes {
    param([string]$Directory, [string[]]$Names)
    $lines = foreach ($name in $Names) {
        $hash = Get-FileHash -LiteralPath (Join-Path $Directory $name) -Algorithm SHA256
        $hash.Hash.ToLowerInvariant() + '  ' + $name
    }
    [IO.File]::WriteAllLines((Join-Path $Directory 'SHA256SUMS.txt'), [string[]]$lines,
        (New-Object Text.UTF8Encoding($false)))
}

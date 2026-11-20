Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot 'P4AutoMerge.Update.psm1') -Force -PassThru
$script:Passed = 0
$testRoot = Join-Path $env:TEMP ('P4AutoMerge-UpdateTest-' + [guid]::NewGuid().ToString('N'))

function Assert-Update {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-UpdateThrows {
    param([scriptblock]$Operation)
    try { & $Operation }
    catch { return }
    throw 'Expected update operation to fail'
}

function Test-UpdateCase {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Output "PASS $Name"
}

function New-UpdateFixture {
    $bytes = [Text.Encoding]::UTF8.GetBytes('test installer payload')
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    return [pscustomobject]@{
        tag_name='v1.1.0'; draft=$false; prerelease=$false; body='Release notes 测试日志'
        assets=@([pscustomobject]@{ name='P4AutoMerge-1.1.0-Setup-x64.exe'; state='uploaded'
            browser_download_url='https://github.com/rexyizhouhu/p4-auto-merge/releases/download/v1.1.0/P4AutoMerge-1.1.0-Setup-x64.exe'
            size=$bytes.Length; digest=('sha256:' + $digest) })
    }
}

Test-UpdateCase 'Numeric versions, no downgrade, no same-version update' {
    $fixture = New-UpdateFixture
    $release = & $module { param($data) ConvertTo-UpdateRelease $data '1.0.9' } $fixture
    Assert-Update ($release.Version -eq '1.1.0' -and $release.Notes.Contains('测试日志')) 'Version/notes lost'
    foreach ($version in @('1.1.0', '2.0.0')) {
        $result = & $module { param($data,$current) ConvertTo-UpdateRelease $data $current } $fixture $version
        Assert-Update ($null -eq $result) 'Same version or downgrade offered'
    }
}

Test-UpdateCase 'Reject preview, missing/duplicate assets, bad URL/hash/size' {
    $mutations = @(
        { param($f) $f.draft=$true }, { param($f) $f.prerelease=$true },
        { param($f) $f.tag_name='v2.0.0-beta' }, { param($f) $f.assets=@() },
        { param($f) $f.assets=@($f.assets[0],$f.assets[0]) },
        { param($f) $f.assets[0].browser_download_url='https://example.com/installer.exe' },
        { param($f) $f.assets[0].digest='sha256:missing' },
        { param($f) $f.assets[0].size=134217729 }, { param($f) $f.assets[0].state='starter' }
    )
    foreach ($mutation in $mutations) {
        $fixture=New-UpdateFixture; & $mutation $fixture
        Assert-UpdateThrows { & $module { param($f) ConvertTo-UpdateRelease $f } $fixture }
    }
}

Test-UpdateCase 'Reminder intervals, calendar month, skip only one version, manual override' {
    $preferences=[pscustomobject]@{Frequency='Always'; SkippedVersion=''; LastPromptUtc='2026-01-31T12:00:00Z'}
    $now=[datetime]'2026-02-01T12:00:00Z'
    Assert-Update (Test-UpdateReminder $preferences '1.1.0' $now) 'Always did not remind'
    $preferences.Frequency='Weekly'
    Assert-Update (-not (Test-UpdateReminder $preferences '1.1.0' $now)) 'Weekly reminded too soon'
    Assert-Update (Test-UpdateReminder $preferences '1.1.0' ([datetime]'2026-02-07T12:00:00Z')) 'Weekly boundary wrong'
    $preferences.Frequency='Monthly'
    Assert-Update (-not (Test-UpdateReminder $preferences '1.1.0' ([datetime]'2026-02-28T11:59:59Z'))) 'Month reminded early'
    Assert-Update (Test-UpdateReminder $preferences '1.1.0' ([datetime]'2026-02-28T12:00:00Z')) 'Calendar month boundary wrong'
    $preferences.Frequency='Never'
    Assert-Update (-not (Test-UpdateReminder $preferences '1.1.0' $now)) 'Never displayed automatic prompt'
    Assert-Update (Test-UpdateReminder $preferences '1.1.0' $now -Manual) 'Manual ignored Never override'
    $preferences.Frequency='Always'; $preferences.SkippedVersion='1.1.0'
    Assert-Update (-not (Test-UpdateReminder $preferences '1.1.0' $now)) 'Skipped version prompted'
    Assert-Update (Test-UpdateReminder $preferences '1.1.1' $now) 'Skip suppressed a newer version'
    Assert-Update (Test-UpdateReminder $preferences '1.1.0' $now -Manual) 'Manual did not override skip'
}

Test-UpdateCase 'Preferences persistence, corrupted file fallback and atomic writes' {
    $path=Join-Path $testRoot 'settings.json'
    $prefs=Get-UpdatePreferences $path
    Assert-Update ($prefs.Frequency -eq 'Always') 'Default is not every launch'
    $prefs.Frequency='Monthly'; $prefs.SkippedVersion='1.1.0'; $prefs.LastPromptUtc=[datetime]::UtcNow.ToString('o'); $prefs.Theme='DarkModern'
    Save-UpdatePreferences $prefs $path
    $saved=Get-UpdatePreferences $path
    Assert-Update ($saved.Frequency -eq 'Monthly' -and $saved.SkippedVersion -eq '1.1.0' -and $saved.Theme -eq 'DarkModern') 'Settings not persisted'
    Save-UpdatePreferences $saved $path
    Assert-Update (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp').Count -eq 0) 'Temporary preference file leaked'
    [IO.File]::WriteAllText($path,'broken json')
    Assert-Update ((Get-UpdatePreferences $path).Frequency -eq 'Always') 'Corrupted settings block startup'
}

Test-UpdateCase 'Merge activity prevents update; terminal sessions permit it' {
    Assert-Update (-not (Test-UpdateCanInstall $true $null)) 'Running command permits install'
    foreach ($phase in @('Creating','Merging','Waiting','Resolving','ReviewRequired','Failed')) {
        Assert-Update (-not (Test-UpdateCanInstall $false ([pscustomobject]@{Phase=$phase}))) ('Active phase permits install: '+$phase)
    }
    foreach ($phase in @('Complete','Abandoned')) {
        Assert-Update (Test-UpdateCanInstall $false ([pscustomobject]@{Phase=$phase})) 'Terminal session blocks update'
    }
}

Test-UpdateCase 'Built manifest matches installer hash, release notes and launcher version' {
    . (Join-Path $PSScriptRoot 'Packaging.Common.ps1')
    [void][IO.Directory]::CreateDirectory($testRoot)
    $setup=Join-Path $testRoot 'P4AutoMerge-1.1.0-Setup-x64.exe'
    $manifest=Join-Path $testRoot 'update.json'
    [IO.File]::WriteAllText($setup,'test packaging payload')
    Write-UpdateManifest $setup '1.1.0' '测试更新日志' $manifest
    $data=Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $release=& $module { param($data) ConvertTo-UpdateRelease $data } $data
    Assert-Update ($release.SHA256 -ieq (Get-FileHash -LiteralPath $setup).Hash -and $release.Notes -eq '测试更新日志') 'Generated update manifest differs from payload'
    $launcher=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Launcher.cs') -Raw
    Assert-Update ($launcher.Contains('AssemblyInformationalVersion("' + (Get-UpdateVersion) + '")')) 'Launcher and updater versions differ'
    [IO.File]::Delete($setup)
}

Test-UpdateCase 'Streaming response is bounded' {
    $inputStream=New-Object IO.MemoryStream(,[byte[]](1,2,3,4))
    $outputStream=New-Object IO.MemoryStream
    try { Assert-UpdateThrows { & $module { param($i,$o) Copy-UpdateResponse $i $o 3 } $inputStream $outputStream } }
    finally { $inputStream.Dispose(); $outputStream.Dispose() }
}

Test-UpdateCase 'Mocked GitHub check and verified download; corrupted payload is removed' {
    $fixture=New-UpdateFixture
    & $module {
        param($data)
        $script:TestRelease=$data; $script:CorruptDownload=$false
        function script:Invoke-UpdateHttp {
            param($Options)
            if (-not $Options.Output) { return ($script:TestRelease | ConvertTo-Json -Depth 5) }
            $text='test installer payload'
            if ($script:CorruptDownload) { $text='corrupt' }
            [IO.File]::WriteAllText($Options.Output,$text,(New-Object Text.UTF8Encoding($false)))
        }
    } $fixture
    $release=Get-LatestUpdate
    $installer=Save-UpdateInstaller $release $testRoot
    Assert-Update ((Get-FileHash -LiteralPath $installer.Path).Hash -ieq $release.SHA256) 'Downloaded hash not validated'
    & $module { $script:CorruptDownload=$true }
    Assert-UpdateThrows { Save-UpdateInstaller $release $testRoot }
    Assert-Update (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.exe' -Recurse).Count -eq 1) 'Corrupt payload remained executable'
}

Write-Output "All $script:Passed update test groups passed. No installer executed, no network or P4 writes."

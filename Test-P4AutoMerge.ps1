param([switch]$ReadOnlyConnection)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot 'P4AutoMerge.Core.psm1') -Force -PassThru
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)
    try { & $Operation }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        return
    }
    throw "Expected exception matching: $Pattern"
}

function New-TestRequest {
    return [pscustomobject]@{
        Context = [pscustomobject]@{ Server = 'test:1666'; User = 'tester'; Client = 'test-client' }
        Source = '//Depot/Source'; Target = '//Depot/Target'; ChangeText = '102, 101, 102'; Limit = 10
        AllowCrossBranch = $false
        ForceReintegrate = $false
    }
}

function Set-TestFixture {
    & $module {
        $script:Fixture = @{
            Calls = New-Object 'System.Collections.Generic.List[object]'
            Stream = '//Depot/Target'; Host = $env:COMPUTERNAME; Opened = @()
            Dirty = $false; WrongSource = $false; Submitted = $true
            HasFiles = $true; Unresolved = $true; FailMerge = $false; FailResolve = $false
            PendingStatus = 'pending'; PendingUser = 'tester'
            WarningMerge = $false; Unmapped = $false; ActualTarget = '//Depot/Target/a.txt'
            SourceOptions = 'allsubmit unlocked toparent nofromparent mergedown'
            SourceIsolate = $false; ParentRemap = $false; TargetParent = 'none'
        }
        $script:P4Runner = {
            param($arguments, $inputText, $timeout)
            $verbs = @('client', 'opened', 'describe', 'merge', 'integrate', 'reconcile', 'change', 'resolve', 'where', 'stream')
            $verbIndex = 0
            while ($verbIndex -lt $arguments.Count -and $arguments[$verbIndex] -notin $verbs) { $verbIndex++ }
            if ($verbIndex -ge $arguments.Count) { throw 'Test runner received unknown command.' }
            $command = @($arguments[$verbIndex..($arguments.Count - 1)])
            $script:Fixture.Calls.Add([pscustomobject]@{ Command = $command; Input = $inputText })
            if ($command[0] -eq 'change' -and $command -contains '-i') {
                return [pscustomobject]@{ ExitCode = 0; Output = 'Change 900 created.'; Error = '' }
            }
            $rows = @(Get-FixtureRows $command)
            $json = ($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n"
            return [pscustomobject]@{ ExitCode = 0; Output = $json; Error = '' }
        }
    }
}

function Install-FixtureHelpers {
    & $module {
        function script:Get-FixtureRows {
            param([string[]]$Command)
            switch ($Command[0]) {
                'client' { return @{ Stream = $script:Fixture.Stream; Host = $script:Fixture.Host; Root = $script:StateDirectory; Type = 'writeable' } }
                'stream' { return Get-FixtureStream $Command }
                'opened' { return $script:Fixture.Opened }
                'describe' { return Get-FixtureDescription }
                'merge' { return Get-FixtureMerge $Command }
                'integrate' { return Get-FixtureMerge $Command }
                'reconcile' { return Get-FixtureReconcile $Command }
                'where' { return Get-FixtureMapping $Command }
                'change' { return @{ Status = $script:Fixture.PendingStatus; Client = 'test-client'; User = $script:Fixture.PendingUser } }
                'resolve' { return Get-FixtureResolve $Command }
            }
        }
        function script:Get-FixtureDescription {
            $status = 'submitted'
            if (-not $script:Fixture.Submitted) { $status = 'pending' }
            $file = '//Depot/Source/a.txt'
            if ($script:Fixture.WrongSource) { $file = '//Depot/Other/a.txt' }
            return @{ status = $status; depotFile0 = $file }
        }
        function script:Get-FixtureMerge {
            param($Command)
            if ($script:Fixture.FailMerge -and $Command -notcontains '-n') { throw 'Simulated partial merge failure' }
            if ($script:Fixture.WarningMerge -and $Command -notcontains '-n') {
                return @{ severity = 2; generic = 17; data = 'Target not in client view; some files skipped.' }
            }
            if ($script:Fixture.HasFiles) {
                if ($Command -notcontains '-n') {
                    $script:Fixture.Opened = @(@{ depotFile = $script:Fixture.ActualTarget; change = '900' })
                }
                return @{ depotFile = $script:Fixture.ActualTarget; action = 'integrate' }
            }
            return @{ severity = 2; generic = 17; data = 'All revision(s) already integrated.' }
        }
    }
    Install-ResolveFixtureHelpers
}

function Install-ResolveFixtureHelpers {
    & $module {
        function script:Get-FixtureStream {
            param($Command)
            if ($Command[-1] -eq '//Depot/Ancestor') {
                return @{ Stream = '//Depot/Ancestor'; Parent = 'none'; Paths0 = 'isolate inherited/...' }
            }
            if ($Command[-1] -eq '//Depot/Source') {
                $paths = 'share ...'
                if ($script:Fixture.SourceIsolate) { $paths = 'isolate private/...' }
                return @{ Stream = '//Depot/Source'; Type = 'release'; Parent = '//Depot/Target'; Options = $script:Fixture.SourceOptions; firmerThanParent = 'true'; Paths0 = $paths }
            }
            $remap = ''
            if ($script:Fixture.ParentRemap) { $remap = 'old/... new/...' }
            return @{ Stream = '//Depot/Target'; Type = 'mainline'; Parent = $script:Fixture.TargetParent; Options = 'allsubmit unlocked notoparent nofromparent mergedown'; firmerThanParent = 'n/a'; Remapped0 = $remap }
        }
        function script:Get-FixtureResolve {
            param($Command)
            if ($Command -contains '-as' -and $script:Fixture.FailResolve) { throw 'Simulated resolve failure' }
            if ($Command -contains '-n' -and $script:Fixture.Unresolved) {
                return @{ clientFile = 'C:\test\a.txt'; fromFile = '//Depot/Source/a.txt'; resolveType = 'content' }
            }
        }
        function script:Get-FixtureMapping {
            param($Command)
            foreach ($file in $Command[1..($Command.Count - 1)]) {
                if ($script:Fixture.Unmapped) { @{ depotFile = $file; unmap = ''; path = 'C:\test\a.txt' } }
                else { @{ depotFile = $file; path = 'C:\test\a.txt' } }
            }
        }
        function script:Get-FixtureReconcile {
            param($Command)
            if ($script:Fixture.Dirty -and $Command -contains $script:Fixture.ActualTarget) {
                return @{ depotFile = $script:Fixture.ActualTarget; action = 'edit' }
            }
        }
    }
}

function Get-TestCalls {
    return & $module { return @($script:Fixture.Calls.ToArray()) }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    Set-TestFixture
    & $module {
        if (Test-Path -LiteralPath $script:StateDirectory) {
            Get-ChildItem -LiteralPath $script:StateDirectory -File | Remove-Item
        }
    }
    & $Body
    $script:Passed++
    Write-Output "PASS $Name"
}

function Test-TargetPolicy {
    $streams = @(
        [pscustomobject]@{ Stream = '//Depot/Main'; Type = 'mainline'; Parent = 'none'; Options = 'notoparent nofromparent mergedown'; firmerThanParent = 'n/a' },
        [pscustomobject]@{ Stream = '//Depot/Dev'; Type = 'development'; Parent = '//Depot/Main'; Options = 'toparent fromparent mergedown'; firmerThanParent = 'false' },
        [pscustomobject]@{ Stream = '//Depot/Release'; Type = 'release'; Parent = '//Depot/Main'; Options = 'toparent nofromparent mergedown'; firmerThanParent = 'true' },
        [pscustomobject]@{ Stream = '//Depot/Sibling'; Type = 'release'; Parent = '//Depot/Main'; Options = 'toparent nofromparent mergedown'; firmerThanParent = 'true' },
        [pscustomobject]@{ Stream = '//Depot/Virtual'; Type = 'virtual'; Parent = '//Depot/Main'; Options = 'notoparent nofromparent mergedown'; firmerThanParent = 'n/a' },
        [pscustomobject]@{ Stream = '//Other/Main'; Type = 'mainline'; Parent = 'none'; Options = ''; firmerThanParent = 'n/a' }
    )
    $normal = @(Get-AllowedTargetStreams '//Depot/Main' $streams)
    Assert-True ($normal.Count -eq 1 -and $normal[0].Stream -eq '//Depot/Dev') 'Main normal targets are wrong'
    $release = @(Get-AllowedTargetStreams '//Depot/Release' $streams)
    Assert-True ($release.Count -eq 1 -and $release[0].Stream -eq '//Depot/Main') 'Release normal targets are wrong'
    Assert-True (@(Get-AllowedTargetStreams '//Depot/Dev' $streams).Count -eq 0) 'Development-to-parent requires copy by default'
    $forced = @(Get-AllowedTargetStreams '//Depot/Release' $streams $true)
    Assert-True ($forced.Count -eq 3) 'Cross targets include self, other depot or virtual stream'
    Assert-True (@(Get-AllowedTargetStreams '' $streams $true).Count -eq 0) 'Empty source has targets'
    Assert-True (@(Get-AllowedTargetStreams '//Depot/Virtual' $streams $true).Count -eq 0) 'Virtual source has standalone target paths'
    $streams[1].Options = 'toparent fromparent mergeany'
    Assert-True (@(Get-AllowedTargetStreams '//Depot/Dev' $streams).Count -eq 1) 'mergeany direction ignored'
    $streams[2].Options = 'toparent fromparent mergedown'
    $normal = @(Get-AllowedTargetStreams '//Depot/Main' $streams)
    Assert-True (@($normal | Where-Object { $_.Stream -eq '//Depot/Release' }).Count -eq 0) 'Release copy direction admitted as normal merge'
    $streams[2].Options = 'toparent fromparent mergeany'
    $normal = @(Get-AllowedTargetStreams '//Depot/Main' $streams)
    Assert-True (@($normal | Where-Object { $_.Stream -eq '//Depot/Release' }).Count -eq 1) 'Allowed mergeany target missing'
}

function Test-ReadOnlyConnection {
    $defaults = Get-P4Defaults
    $context = [pscustomobject]@{ Server = $defaults.Server; User = $defaults.User; Client = $defaults.Client }
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $catalog = Invoke-MergeAction 'Catalog' ([pscustomobject]@{ Context = $context }) $queue
    Assert-True ($catalog.Clients.Count -gt 0) 'No workspaces returned'
    Assert-True ($catalog.Streams.Count -gt 0) 'No streams returned'
    Write-Output "READ-ONLY OK: $($catalog.Context.User), $($catalog.Clients.Count) workspaces, $($catalog.Streams.Count) streams."
    $request = [pscustomobject]@{ Context = $catalog.Context; Source = $catalog.Info.clientStream; Limit = 3 }
    $changes = @(Invoke-MergeAction 'Changes' $request $queue)
    Assert-True ($changes.Count -gt 0) 'No source CLs returned for current stream'
    Assert-True ($null -ne $changes[0].PSObject.Properties['desc']) 'Full description field missing'
    Write-Output "READ-ONLY CL SEARCH DATA OK: $($changes.Count) submitted CLs with full descriptions."
}

function Assert-ReintegrateCommands {
    param([object[]]$Calls, [bool]$CrossBranch)
    $commands = @($Calls | Where-Object { $_.Command[0] -eq 'integrate' })
    Assert-True ($commands.Count -gt 0) 'No reintegration command recorded'
    foreach ($call in $commands) {
        $command = $call.Command
        foreach ($flag in @('-Af', '-f', '-Rbd', '-Or')) {
            Assert-True ($command -ccontains $flag) "Reintegration missing $flag"
        }
        Assert-True (($command -ccontains '-F') -eq $CrossBranch) 'Reintegration changed cross-branch mode'
        $path = '//Depot/Target/...'
        if ($CrossBranch) { $path = '//Depot/Source/...' }
        Assert-True (@($command | Where-Object { $_ -in @("$path@101,101", "$path@102,102") }).Count -eq 1) 'Reintegration lost exact source CL range'
        if (-not $CrossBranch) {
            Assert-True ($command -ccontains '-S' -and $command -ccontains '-P' -and $command -ccontains '-r') 'Normal reintegration lost stream view'
        }
        if ($command -ccontains '-n') { continue }
        Assert-True ($command -ccontains '-c' -and $command -contains '900') 'Reintegration missing pending CL'
    }
    $resolves = @($Calls | Where-Object { $_.Command[0] -eq 'resolve' -and $_.Command -notcontains '-n' })
    Assert-True (@($resolves | Where-Object { $_.Command -cnotcontains '-as' }).Count -eq 0) 'Reintegration changed safe resolve mode'
}

function Test-NativeInputEncoding {
    $originalEncoding = [Console]::InputEncoding
    $withBom = New-Object Text.UTF8Encoding($true)
    $withoutBom = New-Object Text.UTF8Encoding($false)
    $probeCode = '$ProgressPreference="SilentlyContinue"; $memory=New-Object IO.MemoryStream; [Console]::OpenStandardInput().CopyTo($memory); [Console]::WriteLine([Convert]::ToBase64String($memory.ToArray()))'
    $arguments = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCode)))
    $executable = Join-Path $PSHOME 'powershell.exe'
    try {
        foreach ($encoding in @($withBom, $withoutBom)) {
            [Console]::InputEncoding = $encoding
            foreach ($inputText in @("Change: new`nDescription:`n`t中文测试`n", '', $null)) {
                $result = & $module { param($argsToRun,$text,$exe) Invoke-P4Process $argsToRun $text 15000 $exe } $arguments $inputText $executable
                Assert-True ($result.ExitCode -eq 0 -and -not $result.Error) 'Native stdin probe failed'
                $actual = [Convert]::FromBase64String($result.Output.Trim())
                $expected = $withoutBom.GetBytes([string]$inputText)
                Assert-True ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($expected)) 'Native stdin added a BOM or altered Unicode form bytes'
                Assert-True ([Console]::InputEncoding.GetPreamble().Length -eq $encoding.GetPreamble().Length) 'Input encoding not restored'
            }
        }
        [Console]::InputEncoding = $withBom
        Assert-Throws { & $module {
            $process = New-Object Diagnostics.Process
            $process.StartInfo.FileName = Join-Path ([IO.Path]::GetTempPath()) ('P4AutoMerge-Missing-' + [guid]::NewGuid().ToString('N') + '.exe')
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardInput = $true
            try { Start-P4Process $process } finally { $process.Dispose() }
        } } 'Start|file|文件|cannot'
        Assert-True ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'Failed start did not restore input encoding'
    }
    finally { [Console]::InputEncoding = $originalEncoding }
}

if ($ReadOnlyConnection) { Test-ReadOnlyConnection; exit 0 }
$testRoot = Join-Path $env:TEMP ('P4AutoMerge-Test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
& $module { param($path) $script:StateDirectory = $path } $testRoot
Install-FixtureHelpers

try {
    Test-Case 'Native process receives exact no-BOM UTF8 form bytes and restores encoding on failure' {
        Test-NativeInputEncoding
    }
    Test-Case 'CL parsing: sort, deduplicate, reject ranges and invalid numbers' {
        $numbers = @(ConvertTo-ChangeNumbers '102, 101 102;103')
        Assert-True (($numbers -join ',') -eq '101,102,103') 'Wrong ordering or duplication'
        Assert-Throws { ConvertTo-ChangeNumbers '101-103' } 'CL'
        Assert-Throws { ConvertTo-ChangeNumbers '-1' } 'CL'
        Assert-Throws { ConvertTo-ChangeNumbers '2147483648' } 'CL'
    }
    Test-Case 'Preview uses exact CL ranges and performs no write commands' {
        $preview = Invoke-MergeAction 'Preview' (New-TestRequest) $null
        Assert-True ($preview.Changes.Count -eq 2) 'Wrong change count'
        $calls = @(Get-TestCalls)
        $merges = @($calls | Where-Object { $_.Command[0] -eq 'merge' })
        Assert-True ($merges.Count -eq 2) 'Wrong merge preview count'
        Assert-True ($merges[0].Command -contains '//Depot/Target/...@101,101') 'Not an exact CL range'
        Assert-True ($merges[1].Command -contains '//Depot/Target/...@102,102') 'Not an exact CL range'
        Assert-True ($merges[0].Command -contains '--from' -and $merges[0].Command -notcontains '-F') 'Normal merge bypassed stream policy'
        Assert-True (@($merges | Where-Object { $_.Command -notcontains '-n' }).Count -eq 0) 'Preview mutated files'
        Assert-True (@($calls | Where-Object { $_.Command[0] -in @('change', 'resolve') }).Count -eq 0) 'Preview created a CL or resolved'
    }
    Test-Case 'Reject mismatching target workspace and other host' {
        & $module { $script:Fixture.Stream = '//Depot/Wrong' }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'workspace'
        & $module { $script:Fixture.Stream = '//Depot/Target'; $script:Fixture.Host = 'ANOTHER-HOST' }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'ANOTHER-HOST'
    }
    Test-Case 'Reject existing opened and unopened local modifications' {
        & $module { $script:Fixture.Opened = @(@{ depotFile = '//Depot/Target/a.txt'; change = 'default' }) }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'workspace'
        & $module { $script:Fixture.Opened = @(); $script:Fixture.Dirty = $true }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'checkout'
    }
    Test-Case 'Reject pending or unrelated source CLs' {
        & $module { $script:Fixture.Submitted = $false }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'CL 101'
        & $module { $script:Fixture.Submitted = $true; $script:Fixture.WrongSource = $true }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } '//Depot/Other'
    }
    Test-Case 'Pause at unresolved items, resume without replaying previous merge' {
        $state = Invoke-MergeAction 'Start' (New-TestRequest) $null
        Assert-True ($state.Phase -eq 'Waiting' -and $state.Index -eq 0) 'Did not pause at first CL'
        $again = Invoke-MergeAction 'Resume' (New-TestRequest) $null
        Assert-True ($again.Phase -eq 'Waiting') 'Advanced with unresolved items'
        & $module { $script:Fixture.Unresolved = $false }
        $done = Invoke-MergeAction 'Resume' (New-TestRequest) $null
        Assert-True ($done.Phase -eq 'Complete' -and $done.Index -eq 2) 'Queue did not finish'
        $calls = @(Get-TestCalls)
        $writes = @($calls | Where-Object { $_.Command[0] -eq 'merge' -and $_.Command -notcontains '-n' })
        Assert-True ($writes.Count -eq 2) 'A merge was replayed'
        $unsafe = @($calls | Where-Object { $_.Command[0] -eq 'resolve' -and ($_.Command -contains '-am' -or $_.Command -contains '-af') })
        Assert-True ($unsafe.Count -eq 0) 'Unsafe resolve mode'
        $resolves = @($calls | Where-Object { $_.Command[0] -eq 'resolve' -and $_.Command -contains '-as' })
        Assert-True ($resolves.Count -eq 2 -and $resolves[0].Command -contains '900') 'Resolve not scoped to pending CL'
        Assert-True (@($calls | Where-Object { $_.Command[0] -in @('submit', 'sync', 'revert') }).Count -eq 0) 'Unauthorized command'
    }
    Test-Case 'Persist and load session; reject new queue while existing one is waiting' {
        [void](Invoke-MergeAction 'Start' (New-TestRequest) $null)
        $state = Invoke-MergeAction 'Load' (New-TestRequest) $null
        Assert-True ($state.Pending -eq 900 -and $state.Phase -eq 'Waiting') 'Session not persisted'
        Assert-Throws { Invoke-MergeAction 'Start' (New-TestRequest) $null } 'workspace'
    }
    Test-Case 'Partial merge failure blocks automatic retry and retains pending CL' {
        & $module { $script:Fixture.FailMerge = $true }
        Assert-Throws { Invoke-MergeAction 'Start' (New-TestRequest) $null } 'partial merge'
        $state = Invoke-MergeAction 'Load' (New-TestRequest) $null
        Assert-True ($state.Phase -eq 'Merging' -and $state.Pending -eq 900) 'Lost uncertain write state'
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } 'merge'
        $calls = @(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' -and $_.Command -notcontains '-n' })
        Assert-True ($calls.Count -eq 1) 'Retried uncertain merge'
    }
    Test-Case 'Interrupted resolve can resume safely without another merge' {
        & $module { $script:Fixture.FailResolve = $true }
        Assert-Throws { Invoke-MergeAction 'Start' (New-TestRequest) $null } 'resolve failure'
        & $module { $script:Fixture.FailResolve = $false; $script:Fixture.Unresolved = $false }
        $state = Invoke-MergeAction 'Resume' (New-TestRequest) $null
        Assert-True ($state.Phase -eq 'Complete') 'Resolve recovery failed'
        $calls = @(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' -and $_.Command -notcontains '-n' })
        Assert-True ($calls.Count -eq 2) 'Replayed merge after resolve failure'
    }
    Test-Case 'Already integrated changes create no empty pending CL' {
        & $module { $script:Fixture.HasFiles = $false }
        Assert-Throws { Invoke-MergeAction 'Start' (New-TestRequest) $null } 'pending CL'
        Assert-True (@(Get-TestCalls | Where-Object { $_.Command[0] -eq 'change' }).Count -eq 0) 'Created empty CL'
    }
    Test-Case 'Reject submitted or foreign pending CL when resuming' {
        [void](Invoke-MergeAction 'Start' (New-TestRequest) $null)
        & $module { $script:Fixture.PendingStatus = 'submitted' }
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } '900'
        & $module { $script:Fixture.PendingStatus = 'pending'; $script:Fixture.PendingUser = 'another-user' }
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } '900'
    }
    Test-Case 'Ending tracking retains P4 files without issuing write commands' {
        [void](Invoke-MergeAction 'Start' (New-TestRequest) $null)
        $before = @(Get-TestCalls).Count
        $state = Invoke-MergeAction 'Finish' (New-TestRequest) $null
        Assert-True ($state.Phase -eq 'Abandoned' -and $state.Pending -eq 900) 'Wrong end state'
        $after = @(Get-TestCalls)
        Assert-True ($after.Count -eq $before + 1 -and $after[-1].Command[0] -eq 'client') 'Finish changed P4 files'
    }
    Test-Case 'Unexpected warning stops merge and blocks replay' {
        & $module { $script:Fixture.WarningMerge = $true }
        Assert-Throws { Invoke-MergeAction 'Start' (New-TestRequest) $null } 'not in client view'
        $state = Invoke-MergeAction 'Load' (New-TestRequest) $null
        Assert-True ($state.Phase -eq 'Merging') 'Warning was treated as success'
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } 'merge'
    }
    Test-Case 'Reject excluded mapping and check renamed actual targets' {
        & $module { $script:Fixture.Unmapped = $true }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'workspace'
        & $module { $script:Fixture.Unmapped = $false; $script:Fixture.ActualTarget = '//Depot/Target/renamed.txt'; $script:Fixture.Dirty = $true }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'renamed.txt'
        $calls = @(Get-TestCalls | Where-Object { $_.Command[0] -eq 'reconcile' })
        Assert-True ($calls[-1].Command -contains '//Depot/Target/renamed.txt') 'Actual renamed target was not checked'
        Assert-True ($calls[-1].Command -contains '-a' -and $calls[-1].Command -contains '-I') 'Untracked or ignored collision not checked'
    }
    Test-Case 'Revert while waiting or interrupted resolving cannot silently skip files' {
        [void](Invoke-MergeAction 'Start' (New-TestRequest) $null)
        & $module { $script:Fixture.Opened = @(); $script:Fixture.Unresolved = $false }
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } 'revert'
        & $module {
            $context = [pscustomobject]@{ Server = 'test:1666'; User = 'tester'; Client = 'test-client' }
            $state = Read-MergeSession $context
            $state.Phase = 'Resolving'
            Save-MergeSession $state
        }
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } 'revert'
    }
    Test-Case 'Recheck later source CL for new local changes before actual merge' {
        [void](Invoke-MergeAction 'Start' (New-TestRequest) $null)
        & $module { $script:Fixture.Unresolved = $false; $script:Fixture.Dirty = $true }
        Assert-Throws { Invoke-MergeAction 'Resume' (New-TestRequest) $null } 'checkout'
        $writes = @(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' -and $_.Command -notcontains '-n' })
        Assert-True ($writes.Count -eq 1) 'Merged next CL without checking local changes'
    }
    Test-Case 'Native argument quoting and malformed/error output handling' {
        & $module {
            if ((ConvertTo-NativeArgument 'C:\with space\') -ne '"C:\with space\\"') { throw 'Trailing slash quoting failed' }
            if ((ConvertTo-NativeArgument 'a"b') -ne '"a\"b"') { throw 'Quote escaping failed' }
        }
        Assert-Throws { & $module { ConvertFrom-P4Output ([pscustomobject]@{ ExitCode = 1; Output = '{"severity":3,"data":"permission denied"}'; Error = '' }) } } 'permission denied'
        Assert-Throws { & $module { ConvertFrom-P4Output ([pscustomobject]@{ ExitCode = 0; Output = 'invalid'; Error = '' }) } } 'invalid'
    }
    Test-Case 'Normal mode enforces stream flow; cross mode must be explicitly enabled' {
        & $module { $script:Fixture.SourceOptions = 'allsubmit unlocked notoparent nofromparent mergedown' }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } '合并范围'
        Assert-True (@(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' }).Count -eq 0) 'Invalid flow reached merge'
        $request = New-TestRequest
        $request.AllowCrossBranch = $true
        [void](Invoke-MergeAction 'Preview' $request $null)
        $merges = @(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' })
        Assert-True ($merges[0].Command -contains '-F' -and $merges[0].Command -contains '//Depot/Source/...@101,101') 'Explicit cross mode not applied'
    }
    Test-Case 'Cross mode persists through waiting and resume; missing mode is safe by default' {
        $request = New-TestRequest
        $request.AllowCrossBranch = $true
        [void](Invoke-MergeAction 'Start' $request $null)
        $state = Invoke-MergeAction 'Load' $request $null
        Assert-True (Get-CrossBranchMode $state.Request) 'Cross mode lost in state'
        & $module { $script:Fixture.Unresolved = $false }
        $state = Invoke-MergeAction 'Resume' $request $null
        Assert-True ($state.Phase -eq 'Complete') 'Cross queue did not resume'
        $writes = @(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' -and $_.Command -notcontains '-n' })
        Assert-True (@($writes | Where-Object { $_.Command -notcontains '-F' }).Count -eq 0) 'Resume changed merge mode'
        Assert-True (-not (Get-CrossBranchMode ([pscustomobject]@{}))) 'Missing mode enabled forced merge'
        Assert-True (-not (Get-CrossBranchMode ([pscustomobject]@{ AllowCrossBranch = 'false' }))) 'Text value enabled forced merge'
    }
    Test-Case 'Target filtering follows parent/type/options and excludes unrelated depots and virtual streams' {
        Test-TargetPolicy
    }
    Test-Case 'Normal mode rejects isolate, remaps, inherited exclusions and cyclic ancestry before merge' {
        & $module { $script:Fixture.SourceIsolate = $true }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'isolate'
        & $module { $script:Fixture.SourceIsolate = $false; $script:Fixture.ParentRemap = $true }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'Remapped'
        & $module { $script:Fixture.ParentRemap = $false; $script:Fixture.TargetParent = '//Depot/Ancestor' }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } 'Ancestor'
        & $module { $script:Fixture.TargetParent = '//Depot/Source' }
        Assert-Throws { Invoke-MergeAction 'Preview' (New-TestRequest) $null } '循环'
        Assert-True (@(Get-TestCalls | Where-Object { $_.Command[0] -eq 'merge' }).Count -eq 0) 'Complex normal stream reached merge'
        $request = New-TestRequest
        $request.AllowCrossBranch = $true
        [void](Invoke-MergeAction 'Preview' $request $null)
    }
    Test-Case 'Reintegration is explicit, uses exact CLs and preserves both modes through resume' {
        foreach ($crossBranch in @($false, $true)) {
            Set-TestFixture
            $request = New-TestRequest
            $request.AllowCrossBranch = $crossBranch
            $request.ForceReintegrate = $true
            [void](Invoke-MergeAction 'Preview' $request $null)
            Assert-True (@(Get-TestCalls | Where-Object { $_.Command[0] -eq 'change' }).Count -eq 0) 'Reintegration preview wrote a CL'
            $state = Invoke-MergeAction 'Start' $request $null
            Assert-True ($state.Phase -eq 'Waiting') 'Reintegration did not stop for manual resolve'
            $state = Invoke-MergeAction 'Load' $request $null
            Assert-True (Get-ReintegrateMode $state.Request) 'Reintegration mode lost on reload'
            & $module { $script:Fixture.Unresolved = $false }
            $state = Invoke-MergeAction 'Resume' (New-TestRequest) $null
            Assert-True ($state.Phase -eq 'Complete') 'Reintegration queue did not finish'
            $calls = @(Get-TestCalls)
            Assert-ReintegrateCommands $calls $crossBranch
            $writes = @($calls | Where-Object { $_.Command[0] -eq 'integrate' -and $_.Command -cnotcontains '-n' })
            Assert-True ($writes.Count -eq 2) 'Reintegration resume repeated a completed merge'
            Assert-True (@($calls | Where-Object { $_.Command[0] -eq 'merge' }).Count -eq 0) 'Reintegration fell back to regular merge'
        }
    }
    Test-Case 'Reintegration does not expand targets; missing and text options remain off' {
        Assert-True (-not (Get-ReintegrateMode ([pscustomobject]@{}))) 'Old queue enabled reintegration'
        Assert-True (-not (Get-ReintegrateMode ([pscustomobject]@{ForceReintegrate = 'true'}))) 'Text enabled reintegration'
        $request = New-TestRequest
        $request.ForceReintegrate = $true
        & $module { $script:Fixture.SourceOptions = 'notoparent nofromparent mergedown' }
        Assert-Throws { Invoke-MergeAction 'Preview' $request $null } '合并范围'
        Assert-True (@(Get-TestCalls | Where-Object { $_.Command[0] -in @('merge','integrate') }).Count -eq 0) 'Reintegration bypassed target policy'
    }
    Test-Case 'Uncertain reintegration stops replay; unexpected integrate warnings fail closed' {
        $request = New-TestRequest
        $request.ForceReintegrate = $true
        & $module { $script:Fixture.FailMerge = $true }
        Assert-Throws { Invoke-MergeAction 'Start' $request $null } 'merge'
        Assert-Throws { Invoke-MergeAction 'Resume' $request $null } '不确定'
        & $module {
            $result = [pscustomobject]@{ ExitCode=1; Output='{"severity":2,"generic":17,"data":"All revision(s) already integrated."}'; Error='' }
            [void](ConvertFrom-P4Output $result 'integrate')
        }
        Assert-Throws { & $module {
            ConvertFrom-P4Output ([pscustomobject]@{ ExitCode=1; Output='{"severity":2,"generic":17,"data":"Target not in client view; some files skipped."}'; Error='' }) 'integrate'
        } } '停止'
    }
    Write-Output "All $script:Passed test groups passed. No real merge/resolve/sync/submit executed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\P4AutoMerge-Test-'
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

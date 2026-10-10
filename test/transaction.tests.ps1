[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\rust_transaction.ps1')

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

# Release a real Windows file lock from a background thread, without needing a
# PowerShell runspace on that thread.
Add-Type -TypeDefinition @'
public static class TransactionTestLock {
    public static System.Threading.Tasks.Task ReleaseAfter(System.IO.FileStream handle, int milliseconds) {
        return System.Threading.Tasks.Task.Run(() => {
            System.Threading.Thread.Sleep(milliseconds);
            handle.Dispose();
        });
    }
}
'@

$base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $base ('rpc-transaction-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $active = Join-Path $root 'staging'
    $candidate = Join-Path $root 'staging.next.1'
    New-Item -ItemType Directory -Path $active,$candidate -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $active 'marker.txt') -Value 'old' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $candidate 'marker.txt') -Value 'new' -Encoding ASCII
    Promote-ManagedDirectory -ManagedRoot $root -ActivePath $active -CandidatePath $candidate
    Assert-True ((Get-Content -LiteralPath (Join-Path $active 'marker.txt') -Raw).Trim() -eq 'new') 'New candidate was not promoted.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'staging.previous\marker.txt') -Raw).Trim() -eq 'old') 'Previous state was not retained.'

    $occupied = Join-Path $root 'staging.next.2'
    New-Item -ItemType Directory -Path $occupied -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $occupied 'marker.txt') -Value 'newer' -Encoding ASCII
    $handle = [IO.File]::Open((Join-Path $active 'marker.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $failed = $false
    try { Promote-ManagedDirectory -ManagedRoot $root -ActivePath $active -CandidatePath $occupied }
    catch { $failed = $true }
    finally { $handle.Dispose() }
    Assert-True $failed 'Occupied active directory unexpectedly switched.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $active 'marker.txt') -Raw).Trim() -eq 'new') 'Occupied-directory failure changed active state.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'staging.previous\marker.txt') -Raw).Trim() -eq 'old') 'Occupied-directory failure lost recovery state.'

    # A briefly occupied candidate must be promoted once its lock clears, without
    # discarding the active or recovery directory. This is the Zig setup failure.
    $handle = [IO.File]::Open((Join-Path $occupied 'marker.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $blocked = $false
    try { [IO.Directory]::Move($occupied, ($occupied + '.probe')) }
    catch { $blocked = $true }
    Assert-True $blocked 'Candidate lock did not block the initial rename.'
    $release = [TransactionTestLock]::ReleaseAfter($handle, 900)
    try { Promote-ManagedDirectory -ManagedRoot $root -ActivePath $active -CandidatePath $occupied }
    finally { $release.GetAwaiter().GetResult(); $handle.Dispose() }
    Assert-True ((Get-Content -LiteralPath (Join-Path $active 'marker.txt') -Raw).Trim() -eq 'newer') 'Temporarily occupied candidate was not promoted.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'staging.previous\marker.txt') -Raw).Trim() -eq 'new') 'Promotion after a temporary lock lost the previous active state.'
    Assert-True (-not (Test-Path -LiteralPath $occupied)) 'Successful promotion left its candidate directory behind.'

    # A persistent candidate lock fails after the bounded retries and restores
    # both the active directory and the recovery directory set aside earlier.
    $lockedCandidate = Join-Path $root 'staging.next.locked'
    New-Item -ItemType Directory -Path $lockedCandidate -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $lockedCandidate 'marker.txt') -Value 'locked' -Encoding ASCII
    $handle = [IO.File]::Open((Join-Path $lockedCandidate 'marker.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $failed = $false
    try { Promote-ManagedDirectory -ManagedRoot $root -ActivePath $active -CandidatePath $lockedCandidate }
    catch { $failed = $true }
    finally { $handle.Dispose() }
    Assert-True $failed 'Persistently occupied candidate unexpectedly switched.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $active 'marker.txt') -Raw).Trim() -eq 'newer') 'Candidate-lock failure did not restore the active directory.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'staging.previous\marker.txt') -Raw).Trim() -eq 'new') 'Candidate-lock failure lost the recovery directory.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $lockedCandidate 'marker.txt') -Raw).Trim() -eq 'locked') 'Candidate-lock failure changed the candidate.'
    Assert-True (@(Get-ChildItem -LiteralPath $root -Directory -Filter '*.retired.*').Count -eq 0) 'Candidate-lock failure left a retired recovery directory.'

    $interrupted = Join-Path $root 'interrupted'
    New-Item -ItemType Directory -Path $interrupted -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $interrupted 'marker.txt') -Value 'recoverable' -Encoding ASCII
    [IO.Directory]::Move($interrupted, ($interrupted + '.previous'))
    Restore-PreviousManagedDirectory -ManagedRoot $root -ActivePath $interrupted
    Assert-True ((Get-Content -LiteralPath (Join-Path $interrupted 'marker.txt') -Raw).Trim() -eq 'recoverable') 'Interrupted promotion did not recover prior state.'

    [IO.Directory]::Move($interrupted, ($interrupted + '.previous'))
    $handle = [IO.File]::Open((Join-Path ($interrupted + '.previous') 'marker.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $release = [TransactionTestLock]::ReleaseAfter($handle, 900)
    try { Restore-PreviousManagedDirectory -ManagedRoot $root -ActivePath $interrupted }
    finally { $release.GetAwaiter().GetResult(); $handle.Dispose() }
    Assert-True ((Get-Content -LiteralPath (Join-Path $interrupted 'marker.txt') -Raw).Trim() -eq 'recoverable') 'Recovery did not wait for a temporary lock.'

    $keyA = Get-ToolkitOperationKey -Root $root -Scope toolkit
    $keyA2 = Get-ToolkitOperationKey -Root ($root.ToUpperInvariant() + '\') -Scope toolkit
    $keyB = Get-ToolkitOperationKey -Root (Join-Path $root 'other') -Scope toolkit
    Assert-True ($keyA -eq $keyA2 -and $keyA -ne $keyB) 'Mutex key did not normalize root boundaries.'
    $outer = Enter-ToolkitOperation -Root $root -Scope toolkit -Operation outer-test -TimeoutSeconds 2
    try {
        $inner = Enter-ToolkitOperation -Root $root -Scope toolkit -Operation inner-test -TimeoutSeconds 2
        Exit-ToolkitOperation -Handle $inner
        $owner = Get-Content -LiteralPath $outer.MetadataPath -Raw | ConvertFrom-Json
        Assert-True ($owner.operation -eq 'outer-test') 'Nested operation lost its outer owner record.'
    }
    finally { Exit-ToolkitOperation -Handle $outer }

    $childScript = Join-Path $root 'abandon.ps1'
    $scriptBody = @'
. '__REPO__\scripts\rust_transaction.ps1'
$h = Enter-ToolkitOperation -Root '__ROOT__' -Scope toolkit -Operation abandoned-test -TimeoutSeconds 5
exit 0
'@
    $scriptBody = $scriptBody.Replace('__REPO__', (Split-Path -Parent $PSScriptRoot)).Replace('__ROOT__', $root)
    Set-Content -LiteralPath $childScript -Value $scriptBody -Encoding UTF8
    $child = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', "`"$childScript`"") -WindowStyle Hidden -Wait -PassThru
    Assert-True ($child.ExitCode -eq 0) 'Abandoned-lock child failed.'
    $operation = Enter-ToolkitOperation -Root $root -Scope toolkit -Operation recovery-test -TimeoutSeconds 2
    try { Assert-True ($null -ne $operation) 'Abandoned mutex was not recovered.' }
    finally { Exit-ToolkitOperation -Handle $operation }

    $holdScript = Join-Path $root 'hold.ps1'
    $readyPath = Join-Path $root 'holder-ready.txt'
    $holdBody = @'
. '__REPO__\scripts\rust_transaction.ps1'
$h = Enter-ToolkitOperation -Root '__ROOT__' -Scope toolkit -Operation child-holder -TimeoutSeconds 5
Set-Content -LiteralPath '__READY__' -Value ready
try { Start-Sleep -Seconds 2 } finally { Exit-ToolkitOperation -Handle $h }
'@
    $holdBody = $holdBody.Replace('__REPO__', (Split-Path -Parent $PSScriptRoot)).Replace('__ROOT__', $root).Replace('__READY__', $readyPath)
    Set-Content -LiteralPath $holdScript -Value $holdBody -Encoding UTF8
    $holder = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', "`"$holdScript`"") -WindowStyle Hidden -PassThru
    try {
        for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path -LiteralPath $readyPath); $attempt++) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path -LiteralPath $readyPath) 'Concurrent holder did not acquire its lock.'
        $timedOut = $false
        try { $same = Enter-ToolkitOperation -Root $root -Scope toolkit -Operation competing-test -TimeoutSeconds 0; Exit-ToolkitOperation -Handle $same }
        catch { $timedOut = $_.Exception.Message.Contains('Timed out') }
        Assert-True $timedOut 'Same-root competing operation was not serialized.'
        $different = Enter-ToolkitOperation -Root (Join-Path $root 'other') -Scope toolkit -Operation independent-test -TimeoutSeconds 0
        Exit-ToolkitOperation -Handle $different
        Assert-True ($holder.WaitForExit(10000)) 'Concurrent holder did not exit.'
        $after = Enter-ToolkitOperation -Root $root -Scope toolkit -Operation after-holder -TimeoutSeconds 1
        Exit-ToolkitOperation -Handle $after
    }
    finally { if (-not $holder.HasExited) { Stop-Process -Id $holder.Id -Force } }
}
finally {
    $full = [IO.Path]::GetFullPath($root)
    $prefix = $base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $full) -like 'rpc-transaction-*' -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Write-Host 'transaction tests passed.'

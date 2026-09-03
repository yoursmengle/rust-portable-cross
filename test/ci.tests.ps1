[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ciScript = (Resolve-Path (Join-Path $PSScriptRoot "..\ci.ps1")).Path
$hookScript = (Resolve-Path (Join-Path $PSScriptRoot "..\.githooks\pre-commit")).Path

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        $Actual,

        [Parameter(Mandatory = $true)]
        $Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-TempRoot {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("rpc-ci-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git -C $RepoPath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

# A miniature repository holding nothing but a copy of ci.ps1 and whatever test
# suites the case under test needs. ci.ps1 anchors on its own $PSScriptRoot, so a
# copy placed here gates this repository rather than the real one.
function New-GateRepo {
    $root = New-TempRoot
    $init = & git init --quiet -b main $root 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git init failed: $init" }

    $null = Invoke-Git -RepoPath $root -Arguments @("config", "user.email", "ci-tests@example.invalid")
    $null = Invoke-Git -RepoPath $root -Arguments @("config", "user.name", "ci tests")

    Copy-Item -LiteralPath $ciScript -Destination (Join-Path $root "ci.ps1")
    New-Item -ItemType Directory -Path (Join-Path $root "test") -Force | Out-Null
    return $root
}

function Add-GateSuite {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $path = Join-Path $RepoPath "test\$Name"
    [System.IO.File]::WriteAllText($path, $Body, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Gate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [string[]]$Arguments = @()
    )

    $null = Invoke-Git -RepoPath $RepoPath -Arguments @("add", "-A")

    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $output = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoPath "ci.ps1") @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

# --- Every check passes -----------------------------------------------------

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"

    # Built from code points so this test file stays ASCII: on a legacy code page, a
    # check printing non-ASCII text used to come back mangled.
    $nonAscii = -join @(0x68C0, 0x67E5, 0x901A, 0x8FC7 | ForEach-Object { [char]$_ })
    Add-GateSuite -RepoPath $repo -Name "beta.tests.ps1" -Body "Write-Host '$nonAscii'`nexit 0"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 0 -Message "a run where every check passes should exit 0.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'Result: PASSED') -Message "a passing run should report PASSED.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'PASS\s+test/alpha\.tests\.ps1') -Message "each discovered suite should appear in the summary.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'PASS\s+test/beta\.tests\.ps1') -Message "each discovered suite should appear in the summary.`n$($run.Output)"

    # The miniature repository has no openspec/ directory, so that check must report
    # itself skipped - and a skip must neither pass nor fail the run.
    Assert-True -Condition ($run.Output -match 'SKIP\s+openspec-validate') -Message "a check with an unmet prerequisite should report as skipped.`n$($run.Output)"
    Assert-True -Condition ($run.Output -notmatch 'PASS\s+openspec-validate') -Message "a skipped check must not be reported as passed.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'NOT RUN') -Message "the verdict should say a skipped check did not run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'Result: PASSED') -Message "non-ASCII output must not corrupt the verdict.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Failing checks: all of them reported, none of them blocking the others --

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    Add-GateSuite -RepoPath $repo -Name "beta.tests.ps1" -Body "Write-Host 'beta is unhappy'`nexit 3"
    Add-GateSuite -RepoPath $repo -Name "gamma.tests.ps1" -Body "exit 5"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "a run with a failing check should exit non-zero.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'FAIL\s+test/beta\.tests\.ps1') -Message "the failing check should be named.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'beta is unhappy') -Message "the failing check's output should be reproduced.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'FAIL\s+test/gamma\.tests\.ps1') -Message "every failing check should be reported, not just the first.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match '2 failed') -Message "the verdict should count both failures.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'PASS\s+test/alpha\.tests\.ps1') -Message "a failing check must not stop the others from running.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- A tracked script that does not parse -----------------------------------

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    [System.IO.File]::WriteAllText((Join-Path $repo "broken.ps1"), "function Oops {", (New-Object System.Text.UTF8Encoding($false)))

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "a script that does not parse should fail the run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'FAIL\s+powershell-syntax') -Message "the syntax check should be the one that fails.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'broken\.ps1') -Message "the parse failure should name the file.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Working-tree warning ---------------------------------------------------

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    $null = Invoke-Git -RepoPath $repo -Arguments @("add", "-A")
    $null = Invoke-Git -RepoPath $repo -Arguments @("commit", "--quiet", "--no-verify", "-m", "initial")

    $clean = Invoke-Gate -RepoPath $repo
    Assert-True -Condition ($clean.Output -notmatch 'WORKING TREE') -Message "with no unstaged changes the gate should not warn.`n$($clean.Output)"

    # Modify a tracked file without staging it.
    [System.IO.File]::AppendAllText((Join-Path $repo "test\alpha.tests.ps1"), "`n# touched")
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $dirty = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "ci.ps1") 2>&1 | Out-String
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }
    Assert-True -Condition ($dirty -match 'WORKING TREE') -Message "with unstaged changes the gate should say it verified the working tree.`n$dirty"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Hook installation ------------------------------------------------------

$repo = New-GateRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repo ".githooks") -Force | Out-Null
    Copy-Item -LiteralPath $hookScript -Destination (Join-Path $repo ".githooks\pre-commit")

    $install = Invoke-Gate -RepoPath $repo -Arguments @("-InstallHook")
    Assert-Equal -Actual $install.ExitCode -Expected 0 -Message "installing the hook into a fresh clone should succeed.`n$($install.Output)"
    $configured = (Invoke-Git -RepoPath $repo -Arguments @("config", "--get", "core.hooksPath")).Output.Trim()
    Assert-Equal -Actual $configured -Expected ".githooks" -Message "installing should point core.hooksPath at .githooks"

    $reinstall = Invoke-Gate -RepoPath $repo -Arguments @("-InstallHook")
    Assert-Equal -Actual $reinstall.ExitCode -Expected 0 -Message "re-installing should be a no-op that succeeds.`n$($reinstall.Output)"
    $stillConfigured = (Invoke-Git -RepoPath $repo -Arguments @("config", "--get", "core.hooksPath")).Output.Trim()
    Assert-Equal -Actual $stillConfigured -Expected ".githooks" -Message "re-installing should leave the clone in the same state"

    # A hooks path this repository did not set must be left alone: core.hooksPath
    # replaces .git/hooks wholesale, so overwriting it disables someone else's hooks.
    $null = Invoke-Git -RepoPath $repo -Arguments @("config", "core.hooksPath", ".other-hooks")
    $refused = Invoke-Gate -RepoPath $repo -Arguments @("-InstallHook")
    Assert-True -Condition ($refused.ExitCode -ne 0) -Message "installing over a foreign hooks path should fail.`n$($refused.Output)"
    Assert-True -Condition ($refused.Output -match '\.other-hooks') -Message "the refusal should report what it found.`n$($refused.Output)"
    $untouched = (Invoke-Git -RepoPath $repo -Arguments @("config", "--get", "core.hooksPath")).Output.Trim()
    Assert-Equal -Actual $untouched -Expected ".other-hooks" -Message "a refused install must change nothing"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "ci tests passed."

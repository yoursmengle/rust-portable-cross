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

# --- Full lane executes real child checks and preserves their exit status -----

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name 'alpha.tests.ps1' -Body 'exit 0'
    foreach ($relative in @(
        'tools/cargo-home/bin/cargo.exe',
        'tools/cargo-home/bin/rustc.exe',
        'tools/zig/zig.exe'
    )) {
        $path = Join-Path $repo $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllBytes($path, [byte[]]@())
    }
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc') -Force | Out-Null
    foreach ($name in @('aarch64', 'armv7', 'thumbv7em', 'x64_win')) {
        $code = if ($name -eq 'armv7') { 7 } else { 0 }
        $body = "Add-Content -LiteralPath (Join-Path `$PSScriptRoot 'target-runs.txt') -Value '$name'`nexit $code`n"
        [IO.File]::WriteAllText((Join-Path $repo "check_tool_$name.ps1"), $body, (New-Object Text.UTF8Encoding($false)))
    }
    $run = Invoke-Gate -RepoPath $repo -Arguments @('-Full')
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "The failing ARMv7 child must fail Full CI.`n$($run.Output)"
    $called = @(Get-Content -LiteralPath (Join-Path $repo 'target-runs.txt'))
    Assert-Equal -Actual $called.Count -Expected 4 -Message 'Full CI must invoke each target check.'
    Assert-True -Condition ($run.Output -match 'FAIL\s+check_tool_armv7\.ps1' -and
        $run.Output -match 'exited with code 7' -and
        $run.Output -match 'PASS\s+check_tool_aarch64\.ps1' -and
        $run.Output -match 'PASS\s+check_tool_thumbv7em\.ps1' -and
        $run.Output -match 'PASS\s+check_tool_x64_win\.ps1') -Message "Full CI target results were not reported correctly.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- A suite can report itself skipped, and a skip never reads as a pass -----

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    Add-GateSuite -RepoPath $repo -Name "needs-toolkit.tests.ps1" -Body "Write-Host 'SKIP: toolkit is not provisioned'`nexit 3"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 0 -Message "a skipped suite must not fail the run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'SKIP\s+test/needs-toolkit\.tests\.ps1.*toolkit is not provisioned') -Message "a suite exiting with the skip code should report SKIP with its reason.`n$($run.Output)"
    Assert-True -Condition ($run.Output -notmatch 'PASS\s+test/needs-toolkit\.tests\.ps1') -Message "a skipped suite must not be reported as passed.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'NOT RUN') -Message "the verdict should say a skipped suite did not run.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Full lane runs test\full\*.ps1, which the default lane never does --------

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name 'alpha.tests.ps1' -Body 'exit 0'
    foreach ($relative in @(
        'tools/cargo-home/bin/cargo.exe',
        'tools/cargo-home/bin/rustc.exe',
        'tools/zig/zig.exe'
    )) {
        $path = Join-Path $repo $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllBytes($path, [byte[]]@())
    }
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc') -Force | Out-Null
    $fullRoot = Join-Path $repo 'test\full'
    New-Item -ItemType Directory -Path $fullRoot -Force | Out-Null
    $marker = "Add-Content -LiteralPath (Join-Path `$PSScriptRoot 'full-runs.txt') -Value `$MyInvocation.MyCommand.Name`n"
    [IO.File]::WriteAllText((Join-Path $fullRoot 'heavy_pass.ps1'), "${marker}exit 0`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $fullRoot 'heavy_skip.ps1'), "${marker}Write-Host 'SKIP: no host C toolchain'`nexit 3`n", (New-Object Text.UTF8Encoding($false)))

    $run = Invoke-Gate -RepoPath $repo
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $fullRoot 'full-runs.txt'))) -Message "the default lane must not run test\full checks.`n$($run.Output)"

    $run = Invoke-Gate -RepoPath $repo -Arguments @('-Full')
    Assert-Equal -Actual $run.ExitCode -Expected 0 -Message "a Full run whose full-lane checks pass or skip should exit 0.`n$($run.Output)"
    $called = @(Get-Content -LiteralPath (Join-Path $fullRoot 'full-runs.txt'))
    Assert-Equal -Actual $called.Count -Expected 2 -Message 'Full CI must invoke each test\full check.'
    Assert-True -Condition ($run.Output -match 'PASS\s+test/full/heavy_pass\.ps1' -and
        $run.Output -match 'SKIP\s+test/full/heavy_skip\.ps1.*no host C toolchain') -Message "Full CI full-lane results were not reported correctly.`n$($run.Output)"
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

# --- Documentation integrity: control characters ----------------------------

# Every case here writes its documents byte-for-byte rather than through a text
# helper: the defects under test ARE byte-level, and a helper that normalises line
# endings or re-encodes would erase the thing being asserted.
function Add-GateDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $path = Join-Path $RepoPath $Name
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $Body, (New-Object System.Text.UTF8Encoding($false)))
}

$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"

    # The two defects this check exists for: a "\b" decoded into a backspace and a
    # "\x86" decoded into U+0086. Both are invisible in a viewer and both take the
    # path separator with them.
    $backspace = [char]0x08
    $c1 = [char]0x86
    Add-GateDocument -RepoPath $repo -Name "notes.md" -Body "Run ``scripts$($backspace)uild.ps1``.`n"
    Add-GateDocument -RepoPath $repo -Name "other.md" -Body "See ``tools\sysroot$($c1)_64-pc-windows-msvc``.`n"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "a control character in a document should fail the run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'FAIL\s+documentation-integrity') -Message "the documentation check should be the one that fails.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'notes\.md\(line 1\): control character U\+0008') -Message "a backspace should be named by document, line and code point.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'other\.md\(line 1\): control character U\+0086') -Message "a C1 character should be named by document, line and code point.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# A carriage return that is not followed by a line feed is a mangled terminator,
# not a line ending: this is how "\r" arrives when an escape is decoded.
$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    Add-GateDocument -RepoPath $repo -Name "notes.md" -Body "first$([char]0x0D)second`n"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "a stray carriage return should fail the run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'notes\.md\(line 1\): control character U\+000D') -Message "a stray CR should be reported as a control character.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Documentation integrity: path resolution -------------------------------

# The path scan covers instructional documentation - the front page and the customer
# documentation - and reaches a verdict without any of the generated directories
# present, because this is the lane that runs on commit in an unprovisioned clone.
$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    New-Item -ItemType Directory -Path (Join-Path $repo "scripts") -Force | Out-Null
    Add-GateDocument -RepoPath $repo -Name "scripts\real.ps1" -Body "exit 0"

    # tools\ exists but tools\sysroot does not: that is exactly the shape of an
    # unprovisioned clone, and it is what makes the generated-root exemption the
    # rule under test here rather than the foreign-repository one.
    New-Item -ItemType Directory -Path (Join-Path $repo "tools") -Force | Out-Null
    Add-GateDocument -RepoPath $repo -Name "tools\.gitignore" -Body "sysroot/`n"

    $body = @(
        "Run ``.\scripts\real.ps1`` to build.",
        "It needs no ``link.exe`` and no ``ucrtbase.dll``.",
        "Pass ``.\scripts\real.ps1 -ProjectPath <your-project>`` for another project.",
        "Put your crate in ``<your-project>\src``.",
        "Link inputs live under ``tools\sysroot\x86_64-pc-windows-msvc\lib``.",
        "The downstream constant is in ``crates\hec-core\src\health.rs``.",
        "Suites are ``test\*.tests.ps1``.",
        "See ``scripts\real.ps1:12`` for the entry point.",
        "Hooks live in ``.git\hooks\pre-commit``.",
        ""
    ) -join "`n"
    Add-GateDocument -RepoPath $repo -Name "README.md" -Body $body

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 0 -Message "documentation whose paths all resolve should pass.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'PASS\s+documentation-integrity') -Message "the documentation check should pass.`n$($run.Output)"

    # A skip would mean the check declined to run; in a clone with no toolchain it
    # must still reach a verdict.
    Assert-True -Condition ($run.Output -notmatch 'SKIP\s+documentation-integrity') -Message "the documentation check must not skip itself for want of a toolchain.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'documented path\(s\) resolved') -Message "a pass should say how many paths it resolved.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# A path into a directory this repository really has, whose leaf does not exist.
$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    New-Item -ItemType Directory -Path (Join-Path $repo "scripts") -Force | Out-Null
    Add-GateDocument -RepoPath $repo -Name "scripts\real.ps1" -Body "exit 0"
    Add-GateDocument -RepoPath $repo -Name "README.md" -Body "Run ``.\scripts\renamed.ps1`` to build.`n"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "a documented path that does not exist should fail the run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'README\.md\(line 1\): documented path does not exist') -Message "the failure should name the document and line.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'renamed\.ps1') -Message "the failure should name the path.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# A pattern has to match something, but is not required to name a literal file.
$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"
    Add-GateDocument -RepoPath $repo -Name "README.md" -Body "Suites are ``test\*.missing``.`n"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 1 -Message "a pattern matching nothing should fail the run.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match '\*\.missing') -Message "the failure should name the pattern.`n$($run.Output)"
}
finally {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
}

# A planning record or received handoff names paths that do not exist here on
# purpose. Those documents are still scanned for control characters, but their
# paths are out of scope - rewriting them would destroy the record.
$repo = New-GateRepo
try {
    Add-GateSuite -RepoPath $repo -Name "alpha.tests.ps1" -Body "exit 0"

    # scripts\ exists and scripts\gone.ps1 does not, so scope is the only thing that
    # keeps this path out of the scan: neither the foreign-repository rule nor the
    # generated-root rule applies to it.
    New-Item -ItemType Directory -Path (Join-Path $repo "scripts") -Force | Out-Null
    Add-GateDocument -RepoPath $repo -Name "scripts\real.ps1" -Body "exit 0"
    Add-GateDocument -RepoPath $repo -Name "docs\handoff.md" -Body "The old build ran ``scripts\gone.ps1``.`n"

    $run = Invoke-Gate -RepoPath $repo
    Assert-Equal -Actual $run.ExitCode -Expected 0 -Message "a non-instructional document's paths should not be resolved.`n$($run.Output)"
    Assert-True -Condition ($run.Output -match 'PASS\s+documentation-integrity') -Message "a non-instructional document should not fail the path scan.`n$($run.Output)"
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

[CmdletBinding()]
param(
    # Additionally run the per-target cross-build checks. Requires an installed
    # toolchain under tools\ and takes minutes, so it never runs from the commit hook.
    [switch]$Full,

    # Point this clone's core.hooksPath at .githooks so `git commit` runs the gate.
    [switch]$InstallHook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$HooksPathValue = ".githooks"
$HookRelativePath = ".githooks\pre-commit"

# Paths that must exist before the -Full lane can run anything.
$RequiredToolchainPaths = @(
    "tools\cargo-home\bin\cargo.exe",
    "tools\cargo-home\bin\rustc.exe",
    "tools\zig\zig.exe",
    "tools\rustup-home\toolchains\stable-x86_64-pc-windows-msvc"
)

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Runs a native command (or an external script) and captures its merged output.
#
# The console's code page decides how .NET turns a child process's bytes back into
# text. On a legacy code page (936 here) UTF-8 output from git/rustc/zig comes back
# mangled, which has already produced one false failure in this repository, so force
# UTF-8 for the duration and put it back afterwards.
function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$WorkingDirectory = $RepoRoot
    )

    $previousEncoding = [Console]::OutputEncoding
    $previousLocation = (Get-Location).Path
    $global:LASTEXITCODE = 0
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Set-Location -LiteralPath $WorkingDirectory
        $output = & $FilePath @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location -LiteralPath $previousLocation
        [Console]::OutputEncoding = $previousEncoding
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-GitPath {
    $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
    if ($git.Count -gt 0) { return $git[0].Source }
    return $null
}

# Resolves an external tool to something Invoke-Captured can run, and to the argument
# prefix it needs. A tool installed by npm resolves to several entries at once (a .cmd,
# an extensionless shim, and a .ps1); prefer the executable, and run a PowerShell shim
# in a child process so its exit code is unambiguous.
function Resolve-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $candidates = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) { return $null }

    $application = @($candidates | Where-Object { $_.CommandType -eq "Application" })
    if ($application.Count -gt 0) {
        return [pscustomobject]@{
            FilePath       = $application[0].Source
            ArgumentPrefix = @()
        }
    }

    $script = @($candidates | Where-Object { $_.CommandType -eq "ExternalScript" })
    if ($script.Count -gt 0) {
        return [pscustomobject]@{
            FilePath       = (Get-PowerShellExecutable)
            ArgumentPrefix = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script[0].Source)
        }
    }

    return $null
}

# Every check reports exactly one of these. Skipped is deliberately not a pass:
# it says a check did not run, and carries the reason it did not.
function New-Outcome {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Passed", "Failed", "Skipped")]
        [string]$Status,

        [string]$Reason = "",

        [string]$Output = ""
    )

    return [pscustomobject]@{
        Status = $Status
        Reason = $Reason
        Output = $Output
    }
}

$script:Results = New-Object 'System.Collections.Generic.List[object]'

# Runs one check. A failing check never stops the ones after it: a developer who is
# interrupted by a blocked commit should learn everything that is wrong in one attempt.
function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    Write-Host "  - $Name"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $outcome = & $Body
    }
    catch {
        $outcome = New-Outcome -Status "Failed" -Reason "the check itself raised an error" -Output ($_ | Out-String)
    }
    $stopwatch.Stop()

    if ($null -eq $outcome) {
        $outcome = New-Outcome -Status "Failed" -Reason "the check returned no result"
    }

    $script:Results.Add([pscustomobject]@{
        Name    = $Name
        Status  = $outcome.Status
        Reason  = $outcome.Reason
        Output  = $outcome.Output
        Seconds = $stopwatch.Elapsed.TotalSeconds
    })
}

function Get-PowerShellExecutable {
    $hostPath = (Get-Process -Id $PID).Path
    if ($hostPath -and (Test-Path -LiteralPath $hostPath -PathType Leaf)) { return $hostPath }

    foreach ($candidate in @("pwsh", "powershell")) {
        $found = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }

    throw "No PowerShell executable found to run child scripts."
}

function New-ScriptCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return {
        $result = Invoke-Captured -FilePath (Get-PowerShellExecutable) -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Path
        )
        if ($result.ExitCode -eq 0) {
            return New-Outcome -Status "Passed"
        }
        return New-Outcome -Status "Failed" -Reason "exited with code $($result.ExitCode)" -Output $result.Output
    }.GetNewClosure()
}

function ConvertTo-CommandLine {
    param([string[]]$Arguments)

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + ($argument -replace '"', '\"') + '"' } else { $argument }
    }
    return ($quoted -join " ")
}

function Read-CapturedFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    # A child that emits non-ASCII must not break the report, so decode leniently:
    # an undecodable byte becomes a replacement character rather than an exception.
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

# Runs independent external checks concurrently.
#
# Wall clock is the whole point of this gate - a commit gate that is slower than the
# commit message gets bypassed, and then it is worse than nothing because it still
# looks like coverage. These checks are separate processes that share no state (each
# suite builds its own temp root), so running them at once keeps the lane's cost at
# the slowest check rather than the sum of all of them, and keeps it there as suites
# are added. Output goes to files rather than pipes so no child can deadlock on a
# full buffer while we wait for another.
function Invoke-ExternalChecks {
    param([object[]]$Checks)

    if (-not $Checks -or $Checks.Count -eq 0) { return }

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("rpc-ci-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    $started = New-Object 'System.Collections.Generic.List[object]'
    try {
        $index = 0
        foreach ($check in $Checks) {
            Write-Host "  - $($check.Name)"
            $stdoutPath = Join-Path $scratch "$index.out"
            $stderrPath = Join-Path $scratch "$index.err"
            $index++

            $process = Start-Process -FilePath $check.FilePath `
                -ArgumentList (ConvertTo-CommandLine -Arguments $check.Arguments) `
                -WorkingDirectory $RepoRoot `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -NoNewWindow -PassThru

            $started.Add([pscustomobject]@{
                Name    = $check.Name
                Process = $process
                StdOut  = $stdoutPath
                StdErr  = $stderrPath
            })
        }

        foreach ($entry in $started) {
            $entry.Process.WaitForExit()

            # Time each check by its own start/exit, not by when this loop got to it:
            # the loop waits in order, so a stopwatch here would charge every check
            # with the runtime of the slowest one before it.
            $seconds = 0.0
            try {
                $seconds = ($entry.Process.ExitTime - $entry.Process.StartTime).TotalSeconds
            }
            catch {
                $seconds = 0.0
            }

            $output = (Read-CapturedFile -Path $entry.StdOut) + (Read-CapturedFile -Path $entry.StdErr)
            $exitCode = $entry.Process.ExitCode

            if ($exitCode -eq 0) {
                $outcome = New-Outcome -Status "Passed"
            }
            else {
                $outcome = New-Outcome -Status "Failed" -Reason "exited with code $exitCode" -Output $output
            }

            $script:Results.Add([pscustomobject]@{
                Name    = $entry.Name
                Status  = $outcome.Status
                Reason  = $outcome.Reason
                Output  = $outcome.Output
                Seconds = $seconds
            })
        }
    }
    finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

function Test-PowerShellSyntax {
    $git = Get-GitPath
    if (-not $git) {
        return New-Outcome -Status "Skipped" -Reason "git was not found on PATH, so the tracked script list is unavailable"
    }

    $listed = Invoke-Captured -FilePath $git -Arguments @("ls-files", "*.ps1")
    if ($listed.ExitCode -ne 0) {
        return New-Outcome -Status "Skipped" -Reason "'git ls-files' failed, so the tracked script list is unavailable" -Output $listed.Output
    }

    $failures = New-Object 'System.Collections.Generic.List[string]'
    $checked = 0
    foreach ($relative in ($listed.Output -split "\r?\n")) {
        $trimmed = $relative.Trim()
        if (-not $trimmed) { continue }

        $path = Join-Path $RepoRoot $trimmed
        # A file can be tracked and already deleted in the working tree.
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $checked++
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $first = $parseErrors[0]
            $failures.Add("$trimmed(line $($first.Extent.StartLineNumber)): $($first.Message)")
        }
    }

    if ($failures.Count -gt 0) {
        return New-Outcome -Status "Failed" -Reason "$($failures.Count) of $checked tracked script(s) did not parse" -Output ($failures -join [Environment]::NewLine)
    }

    return New-Outcome -Status "Passed" -Reason "$checked tracked script(s) parsed"
}

# Returns the external check that validates the OpenSpec artifacts, or $null with a
# skip reason when there is nothing to validate or no CLI to validate it with. A clone
# without the openspec CLI must still be able to pass the default lane.
function Get-OpenSpecCheck {
    param([ref]$SkipReason)

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "openspec") -PathType Container)) {
        $SkipReason.Value = "this repository has no openspec/ directory"
        return $null
    }

    $openspec = Resolve-ExternalCommand -Name "openspec"
    if (-not $openspec) {
        $SkipReason.Value = "the openspec CLI was not found on PATH"
        return $null
    }

    return [pscustomobject]@{
        Name      = "openspec-validate"
        FilePath  = $openspec.FilePath
        Arguments = $openspec.ArgumentPrefix + @("validate", "--all", "--strict", "--no-interactive")
    }
}

function Get-TestSuiteChecks {
    $testRoot = Join-Path $RepoRoot "test"
    if (-not (Test-Path -LiteralPath $testRoot -PathType Container)) { return @() }

    # Discovered, not hardcoded, so a new suite is gated the moment it is added.
    return @(Get-ChildItem -LiteralPath $testRoot -Filter "*.tests.ps1" -File | Sort-Object Name)
}

function Get-CrossBuildChecks {
    return @(Get-ChildItem -LiteralPath $RepoRoot -Filter "check_tool_*.ps1" -File | Sort-Object Name)
}

function Assert-ToolchainInstalled {
    $missing = @(
        $RequiredToolchainPaths |
            Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) }
    )
    if ($missing.Count -eq 0) { return }

    throw @"
-Full requires an installed toolchain, and it is not present.

  Missing under $RepoRoot :
    $($missing -join "`n    ")

Install it with:
  .\scripts\rust_setup.ps1

Or run the default lane instead, which needs no toolchain:
  .\ci.ps1
"@
}

# ---------------------------------------------------------------------------
# Hook installation
# ---------------------------------------------------------------------------

function Install-CommitHook {
    $hookFile = Join-Path $RepoRoot $HookRelativePath
    if (-not (Test-Path -LiteralPath $hookFile -PathType Leaf)) {
        throw "Cannot install the commit hook: $hookFile does not exist."
    }

    $git = Get-GitPath
    if (-not $git) {
        throw "Cannot install the commit hook: git was not found on PATH."
    }

    $current = Invoke-Captured -FilePath $git -Arguments @("config", "--get", "core.hooksPath")
    $currentValue = $current.Output.Trim()

    if ($current.ExitCode -eq 0 -and $currentValue) {
        if ($currentValue -eq $HooksPathValue) {
            Write-Host "Commit gate already installed: core.hooksPath = $currentValue"
            return
        }

        # core.hooksPath replaces .git/hooks wholesale, so overwriting someone else's
        # value would silently disable every hook they rely on.
        throw @"
Refusing to install the commit gate.

  core.hooksPath is already set to: $currentValue
  This repository's hook lives in:  $HooksPathValue

core.hooksPath replaces .git/hooks entirely, so overwriting it would silently
disable whatever hooks that path provides. Nothing was changed.

If you want the gate anyway, clear the existing setting first:
  git config --unset core.hooksPath
"@
    }

    $set = Invoke-Captured -FilePath $git -Arguments @("config", "core.hooksPath", $HooksPathValue)
    if ($set.ExitCode -ne 0) {
        throw "Failed to set core.hooksPath: $($set.Output)"
    }

    Write-Host "Commit gate installed: core.hooksPath = $HooksPathValue"
    Write-Host "Remove it at any time with: git config --unset core.hooksPath"
}

# ---------------------------------------------------------------------------
# Working-tree honesty
# ---------------------------------------------------------------------------

# The gate verifies what is on disk, which is not necessarily what is being
# committed. Say so when the two differ, so a green run is not over-read.
function Get-WorkingTreeWarning {
    $git = Get-GitPath
    if (-not $git) { return $null }

    $status = Invoke-Captured -FilePath $git -Arguments @("diff", "--quiet")
    if ($status.ExitCode -eq 0) { return $null }
    if ($status.ExitCode -ne 1) { return $null }

    return "Tracked files have unstaged changes: this run verified the WORKING TREE, not the staged content."
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Write-Report {
    param([string]$WorkingTreeWarning)

    $failed = @($script:Results | Where-Object { $_.Status -eq "Failed" })
    $passed = @($script:Results | Where-Object { $_.Status -eq "Passed" })
    $skipped = @($script:Results | Where-Object { $_.Status -eq "Skipped" })

    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Step "Failures"
        foreach ($result in $failed) {
            Write-Host ""
            Write-Host "[FAIL] $($result.Name) - $($result.Reason)" -ForegroundColor Red
            if ($result.Output) {
                Write-Host ($result.Output.TrimEnd())
            }
        }
    }

    Write-Host ""
    Write-Step "Summary"
    foreach ($result in $script:Results) {
        $label = switch ($result.Status) {
            "Passed"  { "PASS" }
            "Failed"  { "FAIL" }
            "Skipped" { "SKIP" }
        }
        $colour = switch ($result.Status) {
            "Passed"  { "Green" }
            "Failed"  { "Red" }
            "Skipped" { "Yellow" }
        }
        $line = "  {0}  {1,-42} {2,6:0.0}s" -f $label, $result.Name, $result.Seconds
        if ($result.Reason) { $line = "$line  ($($result.Reason))" }
        Write-Host $line -ForegroundColor $colour
    }

    if ($WorkingTreeWarning) {
        Write-Host ""
        Write-Warning $WorkingTreeWarning
    }

    Write-Host ""
    if ($failed.Count -gt 0) {
        Write-Host "Result: FAILED - $($failed.Count) failed, $($passed.Count) passed, $($skipped.Count) skipped" -ForegroundColor Red
        return 1
    }

    $verdict = "Result: PASSED - $($passed.Count) passed"
    if ($skipped.Count -gt 0) {
        # Never let a skip read as coverage.
        $verdict = "$verdict, $($skipped.Count) NOT RUN (skipped)"
    }
    Write-Host $verdict -ForegroundColor Green
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($InstallHook) {
    Install-CommitHook
    exit 0
}

if ($Full) {
    Assert-ToolchainInstalled
}

Write-Step "Verifying $RepoRoot"
if ($Full) {
    Write-Host "Lane: full (default checks plus the per-target cross builds)"
}
else {
    Write-Host "Lane: default (use -Full to add the per-target cross builds)"
}
Write-Host ""

Invoke-Check -Name "powershell-syntax" -Body { Test-PowerShellSyntax }

$powerShellExe = Get-PowerShellExecutable
$externalChecks = New-Object 'System.Collections.Generic.List[object]'

foreach ($suite in Get-TestSuiteChecks) {
    $externalChecks.Add([pscustomobject]@{
        Name      = "test/$($suite.Name)"
        FilePath  = $powerShellExe
        Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $suite.FullName)
    })
}

$openSpecSkipReason = ""
$openSpecCheck = Get-OpenSpecCheck -SkipReason ([ref]$openSpecSkipReason)
if ($openSpecCheck) {
    $externalChecks.Add($openSpecCheck)
}
else {
    Invoke-Check -Name "openspec-validate" -Body { New-Outcome -Status "Skipped" -Reason $openSpecSkipReason }.GetNewClosure()
}

Invoke-ExternalChecks -Checks $externalChecks.ToArray()

# The cross builds share sample\target\ and cargo's locks, so unlike the suites above
# they cannot overlap - run them one at a time.
if ($Full) {
    foreach ($crossCheck in Get-CrossBuildChecks) {
        Invoke-Check -Name $crossCheck.Name -Body (New-ScriptCheck -Path $crossCheck.FullName)
    }
}

$exitCode = Write-Report -WorkingTreeWarning (Get-WorkingTreeWarning)
exit $exitCode

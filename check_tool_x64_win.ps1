[CmdletBinding()]
param(
    # Skips the negative test, which temporarily moves the sysroot aside.
    [switch]$SkipNegativeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# A check that dies unexpectedly must not look like a pass.
trap {
    Write-Host ""
    Write-Host "==> Self-containment check FAILED (unexpected error)"
    Write-Host "  - $($_.Exception.Message)"
    Write-Host "  - at $($_.InvocationInfo.PositionMessage)"
    exit 1
}

# Verifies that an x86_64-pc-windows-msvc build is genuinely self-contained:
# it builds with the host Visual Studio and Windows SDK environment scrubbed,
# runs the produced executable, and fails if any library the linker resolved came
# from outside the toolkit root.

$repoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSCommandPath)).Path
$pathBoundaryScript = Join-Path $repoRoot 'scripts\rust_path_boundary.ps1'
if (-not (Test-Path -LiteralPath $pathBoundaryScript -PathType Leaf)) {
    throw "Missing managed path helper: $pathBoundaryScript"
}
. $pathBoundaryScript
$toolsRoot = Join-Path $repoRoot "tools"
$winSysroot = Join-Path $toolsRoot "sysroot\x86_64-pc-windows-msvc"
$winSysrootLib = Join-Path $winSysroot "lib"
$rustMsvcBin = Join-Path $toolsRoot "rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin"
$linkerExe = Join-Path $rustMsvcBin "rust-lld.exe"
$buildScript = Join-Path $repoRoot "scripts\rust_build_x64_win_native.ps1"
$generatorCommand = ".\scripts\build_win_link_inputs.ps1"

$script:Failures = New-Object 'System.Collections.Generic.List[string]'

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Failures.Add($Message)
    Write-Host "    FAIL  $Message"
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    ok    $Message"
}

function Test-InsideToolkit {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-ManagedPathInsideRoot -Root $repoRoot -Path $full)) { return $false }
    $rootFull = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')
    $relative = $full.Substring($rootFull.Length).TrimStart('\', '/')
    if (-not $relative) { return $true }
    try {
        $null = Resolve-ManagedRelativePath -Root $repoRoot -RelativePath $relative
        return $true
    }
    catch {
        return $false
    }
}

function Get-ExpectedToolkitSource {
    param([Parameter(Mandatory = $true)][string]$LibraryPath)
    $name = Split-Path -Leaf $LibraryPath
    return (Join-Path $winSysrootLib $name)
}

function Get-ArchiveDefinedSymbols {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    # Read the archive's own linker symbol directory: the first member is named
    # "/" and holds a big-endian symbol count, one offset per symbol, then the
    # names. This check reads it independently of the generator on purpose - the
    # point is to verify the shipped file, not to trust the script that wrote it.
    $bytes = [System.IO.File]::ReadAllBytes($ArchivePath)
    if ($bytes.Length -lt 68 -or
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "!<arch>" + [char]10) {
        throw "Not a COFF archive: $ArchivePath"
    }

    $memberSize = [int]([System.Text.Encoding]::ASCII.GetString($bytes, 8 + 48, 10).Trim())
    $data = 8 + 60
    $limit = $data + $memberSize
    if ($limit -gt $bytes.Length) {
        throw "Truncated archive symbol directory in $ArchivePath"
    }

    $count = ($bytes[$data] -shl 24) -bor ($bytes[$data + 1] -shl 16) -bor `
        ($bytes[$data + 2] -shl 8) -bor $bytes[$data + 3]

    $symbols = New-Object 'System.Collections.Generic.HashSet[string]'
    $cursor = $data + 4 + ($count * 4)
    for ($i = 0; $i -lt $count -and $cursor -lt $limit; $i++) {
        $end = $cursor
        while ($end -lt $limit -and $bytes[$end] -ne 0) { $end++ }
        [void]$symbols.Add([System.Text.Encoding]::ASCII.GetString($bytes, $cursor, $end - $cursor))
        $cursor = $end + 1
    }
    return $symbols
}

function Invoke-BuildWithScrubbedEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    # Poison rather than merely clear the host MSVC variables: if anything in the
    # build consults them, it fails loudly instead of silently finding real files.
    $poisoned = @{}
    foreach ($name in @("LIB", "INCLUDE", "VCINSTALLDIR", "VSINSTALLDIR", "WindowsSdkDir", "UniversalCRTSdkDir")) {
        $poisoned[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
        [System.Environment]::SetEnvironmentVariable($name, (Join-Path $repoRoot ".no-host-msvc"), "Process")
    }

    try {
        $output = & $buildScript -ProjectPath $ProjectPath 2>&1
        $exitCode = $LASTEXITCODE
        return @{ Output = $output; ExitCode = $exitCode }
    }
    finally {
        foreach ($name in $poisoned.Keys) {
            if ($null -eq $poisoned[$name]) {
                [System.Environment]::SetEnvironmentVariable($name, $null, "Process")
            }
            else {
                [System.Environment]::SetEnvironmentVariable($name, $poisoned[$name], "Process")
            }
        }
    }
}

# --- The linker the build uses -----------------------------------------------

Write-Section "Linker"
if (-not (Test-Path -LiteralPath $linkerExe -PathType Leaf)) {
    Add-Failure "Bundled linker not found at $linkerExe. Run .\scripts\rust_setup.ps1 first."
}
else {
    Write-Host "    linker: $linkerExe"
    if (Test-InsideToolkit -Path $linkerExe) {
        Write-Pass "linker resolves inside the toolkit root"
    }
    else {
        Add-Failure "Linker $linkerExe is outside the toolkit root $repoRoot."
    }
}

# --- Link inputs --------------------------------------------------------------

Write-Section "Windows link inputs"
$requiredLibraries = @(
    "kernel32.lib", "ntdll.lib", "userenv.lib", "ws2_32.lib",
    "dbghelp.lib", "msvcrt.lib", "rpc_winshim.lib"
)
$missingLibraries = @($requiredLibraries | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $winSysrootLib $_) -PathType Leaf)
})

if ($missingLibraries.Count -gt 0) {
    Add-Failure "Missing Windows link inputs under ${winSysrootLib}: $($missingLibraries -join ', ').`n          Regenerate them with: $generatorCommand"
}
else {
    Write-Pass "all $($requiredLibraries.Count) required link inputs present in $winSysrootLib"
}

# --- Symbols the shim has to supply -------------------------------------------

Write-Section "Compiler-runtime shim symbols"
$shimLib = Join-Path $winSysrootLib "rpc_winshim.lib"
$provenanceFile = Join-Path $winSysroot "PROVENANCE.json"
if (-not (Test-Path -LiteralPath $shimLib -PathType Leaf)) {
    Add-Failure "rpc_winshim.lib is missing; regenerate it with: $generatorCommand"
}
elseif (-not (Test-Path -LiteralPath $provenanceFile -PathType Leaf)) {
    Add-Failure "Missing $provenanceFile, which records the symbols the shim must define.`n          Regenerate the sysroot with: $generatorCommand"
}
else {
    # The generator records the set it asserted; this check re-reads the shipped
    # archive against it rather than keeping a second list that can drift. The two
    # stack-probe spellings are named explicitly so an emptied record cannot make
    # this pass vacuously - the GNU-targeted C compiler calls ___chkstk_ms, and
    # nothing else on an MSVC link line defines it.
    $provenance = Get-Content -LiteralPath $provenanceFile -Raw | ConvertFrom-Json
    $required = @($provenance.requiredShimSymbols)
    $floor = @("__chkstk", "___chkstk_ms")
    $unrecorded = @($floor | Where-Object { $required -notcontains $_ })

    if ($unrecorded.Count -gt 0) {
        Add-Failure "$provenanceFile does not record $($unrecorded -join ', ') as a required shim symbol.`n          Add it to `$script:RequiredShimSymbols in scripts\build_win_link_inputs.ps1 and regenerate."
    }

    try {
        $defined = Get-ArchiveDefinedSymbols -ArchivePath $shimLib
        $missingSymbols = @($required | Where-Object { -not $defined.Contains($_) })
        if ($missingSymbols.Count -gt 0) {
            Add-Failure "rpc_winshim.lib does not define $($missingSymbols -join ', ').`n          Regenerate it with: $generatorCommand"
        }
        else {
            Write-Pass "rpc_winshim.lib defines all $($required.Count) required symbols"
        }
    }
    catch {
        Add-Failure "Could not read the symbols in ${shimLib}: $($_.Exception.Message)"
    }
}

# --- Where the linker actually resolved its libraries -------------------------

Write-Section "Link input provenance"
$probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rust-portable-cross-selfcontained-probe"
if (Test-Path -LiteralPath $probeRoot) {
    Remove-Item -LiteralPath $probeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null

try {
    $probeSource = Join-Path $probeRoot "probe.rs"
    Set-Content -LiteralPath $probeSource -Encoding ASCII -Value @'
fn main() {
    let mut v: Vec<String> = (0..8).map(|i| format!("{i}")).collect();
    v.sort();
    println!("{}", v.join(","));
}
'@

    $envSnapshot = @{}
    foreach ($name in @("CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "PATH")) {
        $envSnapshot[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        $env:CARGO_HOME = Join-Path $toolsRoot "cargo-home"
        $env:RUSTUP_HOME = Join-Path $toolsRoot "rustup-home"
        $env:RUSTUP_TOOLCHAIN = "1.98.0-x86_64-pc-windows-msvc"
        $env:PATH = "$(Join-Path $toolsRoot 'cargo-home\bin');$rustMsvcBin;$env:PATH"

        $probeExe = Join-Path $probeRoot "probe.exe"
        $provenanceSentinel = "__rust_portable_cross_provenance_probe__.lib"
        $rustcArgs = @(
            "--target", "x86_64-pc-windows-msvc",
            "--edition", "2021",
            "-C", "linker=rust-lld",
            "-C", "linker-flavor=lld-link",
            "-C", "link-arg=/LIBPATH:$winSysrootLib",
            "-C", "link-arg=rpc_winshim.lib",
            "-C", "link-arg=/verbose",
            "-C", "link-arg=$provenanceSentinel",
            $probeSource,
            "-o", $probeExe
        )
        # rustc only returns rust-lld's /verbose output if linking fails. The
        # sentinel is deliberately missing, so it exposes the paths lld resolved.
        # Decode as UTF-8 so a legacy console code page cannot merge its records.
        $previousOutputEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $verboseOutput = & (Join-Path $toolsRoot "cargo-home\bin\rustc.exe") @rustcArgs 2>&1 | Out-String
            $probeExitCode = $LASTEXITCODE
        }
        finally {
            [Console]::OutputEncoding = $previousOutputEncoding
        }

        if ($probeExitCode -eq 0) {
            Add-Failure "The provenance probe unexpectedly linked successfully; it must fail on $provenanceSentinel to expose the linker's /verbose output."
        }
        elseif ($verboseOutput -notlike "*could not open '$provenanceSentinel'*") {
            Add-Failure "The provenance probe failed before the expected $provenanceSentinel error, so the linker inputs could not be verified.`n$verboseOutput"
        }
        else {
            # Only .lib inputs matter here: object files and rlibs come from the
            # build's own temporary and target directories.
            # Tempered so a malformed capture cannot silently span records: the
            # path stops at the first ".lib", may not contain a control character,
            # and may not swallow the start of the next "rust-lld:" record.
            $readingPattern = '(?i)Reading[ \t]+([A-Za-z]:\\(?:(?!rust-lld)[^\x00-\x1F<>|*?"]){0,300}?\.lib)(?![A-Za-z0-9])'
            $resolved = @([regex]::Matches($verboseOutput, $readingPattern) |
                ForEach-Object { $_.Groups[1].Value.Trim() } |
                Sort-Object -Unique)

            if ($resolved.Count -eq 0) {
                Add-Failure "Could not determine which libraries the linker read; /verbose produced no resolvable paths."
            }

            # A captured path that is not a real file means the parse went wrong,
            # not that the build leaked. Say so, rather than accusing the build.
            $unreadable = @($resolved | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
            foreach ($path in $unreadable) {
                $shown = if ($path.Length -gt 200) { $path.Substring(0, 200) + " ...[truncated]" } else { $path }
                Add-Failure "Could not parse the linker's /verbose output: '$shown' is not an existing file. This is a defect in this check, not a host dependency."
            }

            $outside = @($resolved | Where-Object {
                (Test-Path -LiteralPath $_ -PathType Leaf) -and (-not (Test-InsideToolkit -Path $_))
            })
            foreach ($path in $outside) {
                Add-Failure "Linker resolved $path from outside the toolkit root.`n          Expected it to come from: $(Get-ExpectedToolkitSource -LibraryPath $path)"
            }

            if ($outside.Count -eq 0) {
                Write-Pass "all $($resolved.Count) resolved libraries came from the toolkit root"
                foreach ($path in $resolved) {
                    Write-Host "          $path"
                }
            }
        }
    }
    finally {
        foreach ($name in $envSnapshot.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $envSnapshot[$name], "Process")
        }
    }
}
finally {
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Build and run, with the host toolchain scrubbed --------------------------

$projects = @(
    @{ Path = Join-Path $repoRoot "sample"; Name = "sample"; Expect = $null },
    @{ Path = Join-Path $repoRoot "test\fixtures\win_selfcontained"; Name = "win_selfcontained"; Expect = "SELFCONTAINED OK" }
)

foreach ($project in $projects) {
    Write-Section "Building $($project.Name) with the host MSVC environment scrubbed"

    if (-not (Test-Path -LiteralPath $project.Path -PathType Container)) {
        Add-Failure "Project not found: $($project.Path)"
        continue
    }

    $result = Invoke-BuildWithScrubbedEnvironment -ProjectPath $project.Path -Label $project.Name
    if ($result.ExitCode -ne 0) {
        Add-Failure "Building $($project.Name) failed with exit code $($result.ExitCode).`n$($result.Output | Out-String)"
        continue
    }
    Write-Pass "$($project.Name) built"

    $exePath = Join-Path $project.Path "target\x86_64-pc-windows-msvc\release\$($project.Name).exe"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        Add-Failure "Expected executable was not produced: $exePath"
        continue
    }

    if ($null -ne $project.Expect) {
        $runOutput = & $exePath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "$($project.Name).exe exited with code ${LASTEXITCODE}:`n$runOutput"
        }
        elseif ($runOutput -notmatch [regex]::Escape($project.Expect)) {
            Add-Failure "$($project.Name).exe did not report '$($project.Expect)':`n$runOutput"
        }
        else {
            Write-Pass "$($project.Name).exe ran and reported '$($project.Expect)'"
        }
    }
    else {
        & $exePath --help > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "$($project.Name).exe exited with code $LASTEXITCODE."
        }
        else {
            Write-Pass "$($project.Name).exe ran"
        }
    }
}

# --- Diagnostics when the link inputs are missing -----------------------------

if (-not $SkipNegativeTest -and $missingLibraries.Count -eq 0) {
    Write-Section "Diagnostics with the link inputs removed"

    $stashed = "$winSysrootLib.stashed"
    if (Test-Path -LiteralPath $stashed) {
        Remove-Item -LiteralPath $stashed -Recurse -Force
    }

    Move-Item -LiteralPath $winSysrootLib -Destination $stashed
    try {
        # The build is expected to fail here: a missing sysroot is a hard error, not
        # a fallback to host Visual Studio. Catch it so this check can inspect the
        # message rather than dying on it.
        $output = ""
        $failedAsExpected = $false
        try {
            $output = (& $buildScript -ProjectPath (Join-Path $repoRoot "test\fixtures\win_selfcontained") *>&1 | Out-String)
        }
        catch {
            $failedAsExpected = $true
            $output = ($_ | Out-String)
        }

        if (-not $failedAsExpected) {
            Add-Failure "With the link inputs removed, the build did not fail. It must not silently fall back to host Visual Studio libraries."
        }
        else {
            Write-Pass "fails instead of falling back to the host toolchain"
        }

        if ($output -notmatch [regex]::Escape("build_win_link_inputs.ps1")) {
            Add-Failure "With the link inputs removed, the build did not name the regeneration command."
        }
        else {
            Write-Pass "names the regeneration command"
        }

        $misleading = @(
            @("Visual Studio", "link\.exe", "MSVC linker", "Windows SDK") |
                Where-Object { $output -match $_ }
        )
        if ($misleading.Count -gt 0) {
            Add-Failure "With the link inputs removed, the diagnostics mentioned: $($misleading -join ', '). The problem is missing link inputs, not a missing linker."
        }
        else {
            Write-Pass "does not blame the linker, Visual Studio or the Windows SDK"
        }
    }
    finally {
        if (Test-Path -LiteralPath $winSysrootLib) {
            Remove-Item -LiteralPath $winSysrootLib -Recurse -Force
        }
        Move-Item -LiteralPath $stashed -Destination $winSysrootLib
    }
}

# --- Result -------------------------------------------------------------------

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "==> Self-containment check FAILED ($($script:Failures.Count) problem(s))"
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure"
    }
    exit 1
}

Write-Host "==> Self-containment check passed: x86_64-pc-windows-msvc builds use only toolkit files."
exit 0

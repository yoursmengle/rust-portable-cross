[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixturePath = Join-Path $PSScriptRoot 'fixtures/interface_contract.json'
$contract = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

function Assert-SameSequence {
    param([string]$Label, [object[]]$Actual, [object[]]$Expected)

    $actualJson = ConvertTo-Json -InputObject @($Actual) -Depth 8 -Compress
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Depth 8 -Compress
    if ($actualJson -cne $expectedJson) {
        throw "$Label changed.`nExpected: $expectedJson`nActual:   $actualJson"
    }
}

function Get-ParsedScript {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing public entrypoint: $Path"
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Cannot inspect $Path because it does not parse: $($parseErrors[0].Message)"
    }
    return $ast
}

function Get-ParameterContract {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)

    if ($null -eq $Ast.ParamBlock) { return @() }

    $parameters = New-Object 'System.Collections.Generic.List[object]'
    foreach ($parameter in $Ast.ParamBlock.Parameters) {
        $typeConstraint = @($parameter.Attributes | Where-Object {
            $_ -is [System.Management.Automation.Language.TypeConstraintAst]
        } | Select-Object -First 1)
        $typeName = if ($typeConstraint.Count -gt 0) { $typeConstraint[0].TypeName.FullName } else { '' }

        $defaultValue = $null
        if ($null -ne $parameter.DefaultValue) {
            $defaultValue = $parameter.DefaultValue.SafeGetValue()
        }

        $allowed = @()
        foreach ($attribute in $parameter.Attributes) {
            if ($attribute -is [System.Management.Automation.Language.AttributeAst] -and
                $attribute.TypeName.FullName -eq 'ValidateSet') {
                $allowed = @($attribute.PositionalArguments | ForEach-Object { $_.SafeGetValue() })
            }
        }

        $parameters.Add([pscustomobject]@{
            name = $parameter.Name.VariablePath.UserPath
            type = $typeName
            default = $defaultValue
            validateSet = @($allowed)
        })
    }
    return $parameters.ToArray()
}

function Assert-ScriptSignature {
    param([string]$Label, [object[]]$Expected, [System.Management.Automation.Language.ScriptBlockAst]$Ast)

    $actual = @(Get-ParameterContract -Ast $Ast)
    if ($actual.Count -ne $Expected.Count) {
        throw "$Label parameters changed: expected $($Expected.Count), actual $($actual.Count)."
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        $actualParam = $actual[$i]
        $expectedParam = $Expected[$i]
        if ($actualParam.name -cne $expectedParam.name -or $actualParam.type -cne $expectedParam.type -or
            $actualParam.default -cne $expectedParam.default) {
            throw "$Label parameter $($expectedParam.name) changed: expected $(ConvertTo-Json -InputObject $expectedParam -Compress), actual $(ConvertTo-Json -InputObject $actualParam -Compress)."
        }
        Assert-SameSequence -Label "$Label parameter $($expectedParam.name) ValidateSet" `
            -Actual @($actualParam.validateSet) -Expected @($expectedParam.validateSet)
    }
}

function Get-HashtableKeys {
    param([string]$SourcePath, [string]$Marker)

    $ast = Get-ParsedScript -Path (Join-Path $repoRoot $SourcePath)
    $matches = @()
    foreach ($node in $ast.FindAll({ param($candidate)
        $candidate -is [System.Management.Automation.Language.HashtableAst]
    }, $true)) {
        $keys = @($node.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
        if ($keys -ccontains $Marker) { $matches += ,$keys }
    }
    if ($matches.Count -ne 1) {
        throw "Expected one JSON constructor with '$Marker' in $SourcePath; found $($matches.Count)."
    }
    return @($matches[0])
}

function Assert-SourceContains {
    param([string]$Label, [string]$SourcePath, [string]$Needle)

    $source = Get-Content -LiteralPath (Join-Path $repoRoot $SourcePath) -Raw -Encoding UTF8
    if (-not $source.Contains($Needle)) {
        throw "$Label changed: '$Needle' is absent from $SourcePath."
    }
}

function Assert-PublishedPath {
    param([string]$RelativePath)

    switch -CaseSensitive ($RelativePath) {
        'config/.cargo/config.toml' {
            if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $RelativePath) -PathType Leaf)) {
                throw "Published path missing: $RelativePath"
            }
        }
        'tools/cargo-home/bin/cargo.exe' { Assert-SourceContains 'cargo executable path' 'scripts/rust_env.ps1' 'bin\cargo.exe' }
        'tools/cargo-home/bin/rustc.exe' { Assert-SourceContains 'rustc executable path' 'scripts/rust_env.ps1' 'bin\rustc.exe' }
        'tools/cargo-home/bin/rustup.exe' { Assert-SourceContains 'rustup executable path' 'scripts/rust_env.ps1' 'bin\rustup.exe' }
        'tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc' {
            Assert-SourceContains 'pinned toolchain path' 'scripts/rust_env.ps1' '1.98.0-x86_64-pc-windows-msvc'
        }
        'tools/zig/zig.exe' { Assert-SourceContains 'Zig executable path' 'scripts/rust_env.ps1' 'zig.exe' }
        'tools/sysroot/x86_64-pc-windows-msvc/lib' {
            Assert-SourceContains 'Windows sysroot path' 'scripts/rust_build_isolation.ps1' 'tools\sysroot\x86_64-pc-windows-msvc\lib'
        }
        'tools/sysroot/x86_64-pc-windows-msvc/PROVENANCE.json' {
            Assert-SourceContains 'Windows provenance path' 'scripts/build_win_link_inputs.ps1' 'PROVENANCE.json'
        }
        default { throw "Unexpected published path in baseline: $RelativePath" }
    }
}

function Assert-JsonShape {
    param([string]$Label, [object]$Document, [object]$Expected)

    Assert-SameSequence -Label "$Label keys" -Actual @($Document.PSObject.Properties.Name) `
        -Expected @($Expected.PSObject.Properties.Name)
    foreach ($property in $Expected.PSObject.Properties) {
        $value = $Document.PSObject.Properties[$property.Name].Value
        $kind = if ($value -is [string] -or $value -is [datetime]) { 'string' }
            elseif ($value -is [array]) { 'array' }
            elseif ($value -is [pscustomobject]) { 'object' }
            elseif ($value -is [ValueType]) { 'number' }
            else { 'unexpected' }
        if ($kind -cne $property.Value) {
            throw "$Label.$($property.Name) changed type: expected $($property.Value), actual $kind."
        }
    }
}

foreach ($entrypoint in $contract.entrypoints.PSObject.Properties) {
    $ast = Get-ParsedScript -Path (Join-Path $repoRoot $entrypoint.Name)
    Assert-ScriptSignature -Label $entrypoint.Name -Expected @($entrypoint.Value) -Ast $ast
}

foreach ($schema in $contract.jsonFields.PSObject.Properties) {
    $marker = switch ($schema.Name) {
        'scripts/prepare_offline_release.ps1' { 'productVersion' }
        'scripts/finalize_offline_install.ps1' { 'installScope' }
        'scripts/build_win_link_inputs.ps1' { 'requiredShimSymbols' }
        'build.ps1' { 'originalFileName' }
        default { throw "Unknown JSON constructor in baseline: $($schema.Name)" }
    }
    $constructorSource = $schema.Name
    if ($schema.Name -eq 'build.ps1') {
        Assert-SourceContains 'publication helper loading' 'build.ps1' 'scripts\release_publish.ps1'
        Assert-SourceContains 'publication helper call' 'build.ps1' 'Invoke-SplitPublication'
        $constructorSource = 'scripts/release_publish.ps1'
    }
    $actualKeys = @(Get-HashtableKeys -SourcePath $constructorSource -Marker $marker)
    Assert-SameSequence -Label "$($schema.Name) JSON fields" -Actual $actualKeys -Expected @($schema.Value)
}

$shapeSources = @{
    installLayout = 'scripts/prepare_offline_release.ps1'
    installManifest = 'scripts/finalize_offline_install.ps1'
    sysrootProvenance = 'scripts/build_win_link_inputs.ps1'
    splitDownloadManifest = 'build.ps1'
}
foreach ($shape in $contract.jsonShapes.PSObject.Properties) {
    $source = $shapeSources[$shape.Name]
    if (-not $source) { throw "Unknown JSON shape in baseline: $($shape.Name)" }
    Assert-SameSequence -Label "$($shape.Name) fixture keys" `
        -Actual @($shape.Value.PSObject.Properties.Name) -Expected @($contract.jsonFields.$source)
}

$previousSkip = [Environment]::GetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN', 'Process')
try {
    $env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN = '1'
    . (Join-Path $repoRoot 'scripts/prepare_offline_release.ps1')
    $sampleLayout = New-InstallLayout -Version '1.2.3' -ComponentFiles @{
        core = @('tools/sysroot/x86_64-pc-windows-msvc/lib/kernel32.lib')
        armv7 = @('scripts/rust_build_armv7.ps1')
        aarch64 = @('scripts/rust_build_aarch64.ps1')
        thumbv7em = @('scripts/rust_build_thumbv7em.ps1')
    }
    $serializedLayout = $sampleLayout | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    Assert-JsonShape -Label 'install-layout.json' -Document $serializedLayout -Expected $contract.jsonShapes.installLayout
    Assert-SameSequence -Label 'layout default components' -Actual @($serializedLayout.defaultComponents) `
        -Expected @($contract.installer.layoutDefaultComponents)
}
finally {
    [Environment]::SetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN', $previousSkip, 'Process')
}

$previousSkip = [Environment]::GetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN', 'Process')
$manifestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rpc-contract-' + [guid]::NewGuid().ToString('N'))
try {
    $env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN = '1'
    . (Join-Path $repoRoot 'scripts/finalize_offline_install.ps1')
    New-Item -ItemType Directory -Path $manifestRoot | Out-Null
    New-InstallManifest -InstallRoot $manifestRoot -Layout $serializedLayout `
        -SelectedComponents @('armv7') -InstallScope 'perUser'
    $installedManifest = Get-Content -LiteralPath (Join-Path $manifestRoot 'install-manifest.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-JsonShape -Label 'install-manifest.json' -Document $installedManifest -Expected $contract.jsonShapes.installManifest
    Assert-SameSequence -Label 'finalize subset' -Actual @($installedManifest.installedComponents) `
        -Expected @('core', 'armv7')
}
finally {
    [Environment]::SetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN', $previousSkip, 'Process')
    $manifestFile = Join-Path $manifestRoot 'install-manifest.json'
    if (Test-Path -LiteralPath $manifestFile -PathType Leaf) { Remove-Item -LiteralPath $manifestFile -Force }
    if (Test-Path -LiteralPath $manifestRoot -PathType Container) { Remove-Item -LiteralPath $manifestRoot -Force }
}

. (Join-Path $repoRoot 'scripts/rust_target_payload.ps1')
$definitions = Get-RustTargetPayloadDefinitions
Assert-SameSequence -Label 'target names' -Actual @($definitions.Keys) -Expected @($contract.targets.PSObject.Properties.Name)
foreach ($target in $contract.targets.PSObject.Properties) {
    $actual = $definitions[$target.Name]
    if ($actual.Triple -cne $target.Value.triple -or [bool]$actual.RequiresStd -ne [bool]$target.Value.requiresStd) {
        throw "Target $($target.Name) changed: expected $($target.Value.triple), requiresStd=$($target.Value.requiresStd)."
    }
}

Assert-SourceContains 'toolchain name' 'scripts/rust_env.ps1' $contract.toolchain
Assert-SourceContains 'Zig version' 'scripts/rust_setup.ps1' ('zigVersion = "{0}"' -f $contract.zigVersion)
foreach ($wrapper in $contract.wrappers) {
    $path = Join-Path $repoRoot "tools/wrappers/$wrapper"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required wrapper missing: $wrapper" }
    Assert-SourceContains "wrapper $wrapper" 'scripts/rust_setup.ps1' ($wrapper -replace '\.cmd$', '')
}
foreach ($name in $contract.publicEnvironment) {
    Assert-SourceContains "public environment variable $name" 'scripts/rust_env.ps1' $name
}
foreach ($name in $contract.downloadEnvironment) {
    Assert-SourceContains "download environment variable $name" 'scripts/rust_setup.ps1' $name
}
foreach ($source in $contract.diagnosticAnchors.PSObject.Properties) {
    foreach ($anchor in $source.Value) {
        Assert-SourceContains "diagnostic anchor $anchor" $source.Name $anchor
    }
}
foreach ($path in $contract.publishedPaths) { Assert-PublishedPath -RelativePath $path }

$installer = Get-Content -LiteralPath (Join-Path $repoRoot 'packaging/inno/rust_portable_cross.iss') -Raw -Encoding UTF8
if (-not $installer.Contains($contract.installer.appId)) { throw 'Installer AppId changed.' }
$selected = [regex]::Match($installer, "(?s)function GetSelectedComponents\(.*?Result := '([^']+)';")
if (-not $selected.Success) { throw 'Installer component selection could not be found.' }
Assert-SameSequence -Label 'installer selected components' -Actual @($selected.Groups[1].Value.Split(',')) `
    -Expected @($contract.installer.selectedComponents)
foreach ($location in $contract.installer.defaultDrivePreference) {
    if (-not $installer.Contains($location)) { throw "Installer default directory changed: $location" }
}
Assert-SourceContains 'layout default components' 'scripts/prepare_offline_release.ps1' `
    ('$script:DefaultComponents = @("{0}")' -f ($contract.installer.layoutDefaultComponents -join '","'))
Assert-SameSequence -Label 'installation scopes' -Actual @($contract.installer.scopeValues) `
    -Expected @($contract.entrypoints.'scripts/finalize_offline_install.ps1'[2].validateSet)

# Verify that representative drifts are rejected without mutating repository files.
$token = $null
$errors = $null
$changedSignature = [System.Management.Automation.Language.Parser]::ParseInput(
    'param([string]$ProjectPath = "changed", [switch]$DebugBuild)', [ref]$token, [ref]$errors)
$detected = $false
try {
    Assert-ScriptSignature -Label 'scripts/rust_build_x64_win_native.ps1' `
        -Expected @($contract.entrypoints.'scripts/rust_build_x64_win_native.ps1') -Ast $changedSignature
}
catch { $detected = $_.Exception.Message.Contains('ProjectPath') }
if (-not $detected) { throw 'The parameter regression probe was not detected.' }

$detected = $false
try { Assert-SameSequence -Label 'build.ps1 JSON fields' -Actual @('wrongField') -Expected @($contract.jsonFields.'build.ps1') }
catch { $detected = $_.Exception.Message.Contains('build.ps1 JSON fields') }
if (-not $detected) { throw 'The JSON field regression probe was not detected.' }

$detected = $false
try { Assert-PublishedPath -RelativePath 'tools/sysroot/x86_64-pc-windows-msvc/renamed' }
catch { $detected = $_.Exception.Message.Contains('published path') }
if (-not $detected) { throw 'The published-path regression probe was not detected.' }

Write-Host 'interface_contract tests passed.'

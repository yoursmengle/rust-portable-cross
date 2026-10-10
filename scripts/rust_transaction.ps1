Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'rust_path_boundary.ps1')

function Get-ToolkitOperationKey {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Scope)

    $normalized = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/')).ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Scope`n$normalized")
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Enter-ToolkitOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Operation,
        [int]$TimeoutSeconds = 600
    )

    $key = Get-ToolkitOperationKey -Root $Root -Scope $Scope
    $mutex = New-Object System.Threading.Mutex($false, "Local\RustPortableCross-$key")
    $metadataRoot = Join-Path ([IO.Path]::GetTempPath()) 'rust-portable-cross-locks'
    $metadataPath = Join-Path $metadataRoot "$key.json"
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            $owner = if (Test-Path -LiteralPath $metadataPath) { Get-Content -LiteralPath $metadataPath -Raw } else { 'unknown' }
            throw "Timed out waiting for toolkit operation '$Operation' at $Root. Last owner: $owner"
        }
        New-Item -ItemType Directory -Path $metadataRoot -Force | Out-Null
        $token = [guid]::NewGuid().ToString('N')
        $process = Get-Process -Id $PID
        $processStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        $previousMetadata = $null
        if (Test-Path -LiteralPath $metadataPath) {
            try {
                $priorText = Get-Content -LiteralPath $metadataPath -Raw
                $prior = $priorText | ConvertFrom-Json
                $priorStartUtc = if ($prior.processStartUtc -is [DateTime]) {
                    $prior.processStartUtc.ToUniversalTime().ToString('o')
                }
                else { [string]$prior.processStartUtc }
                if ($prior.pid -eq $PID -and $priorStartUtc -eq $processStartUtc) {
                    $previousMetadata = $priorText
                }
            }
            catch {}
        }
        [ordered]@{
            token = $token
            pid = $PID
            processStartUtc = $processStartUtc
            acquiredUtc = [DateTime]::UtcNow.ToString('o')
            root = [IO.Path]::GetFullPath($Root)
            scope = $Scope
            operation = $Operation
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        return [pscustomobject]@{ Mutex = $mutex; MetadataPath = $metadataPath; Token = $token; PreviousMetadata = $previousMetadata }
    }
    catch {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        throw
    }
}

function Exit-ToolkitOperation {
    param([AllowNull()][object]$Handle)
    if ($null -eq $Handle) { return }
    try {
        if (Test-Path -LiteralPath $Handle.MetadataPath) {
            $record = Get-Content -LiteralPath $Handle.MetadataPath -Raw | ConvertFrom-Json
            if ($record.token -eq $Handle.Token) {
                if ($Handle.PreviousMetadata) {
                    Set-Content -LiteralPath $Handle.MetadataPath -Value $Handle.PreviousMetadata -Encoding UTF8
                }
                else { Remove-Item -LiteralPath $Handle.MetadataPath -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    finally {
        try { $Handle.Mutex.ReleaseMutex() }
        finally { $Handle.Mutex.Dispose() }
    }
}

function Assert-TransactionChildPath {
    param([string]$ManagedRoot, [string]$Path)
    $root = Assert-ManagedRootIsOrdinary -Path $ManagedRoot
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-ManagedPathInsideRoot -Root $root -Path $full) -or
        [string]::Equals($root.TrimEnd('\', '/'), $full.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Transaction path is outside managed root: $Path"
    }
    $relative = $full.Substring($root.TrimEnd('\', '/').Length).TrimStart('\', '/')
    $null = Resolve-ManagedRelativePath -Root $root -RelativePath $relative
    return $full
}

function Remove-TransactionDirectory {
    param([string]$ManagedRoot, [string]$Path)
    $full = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path $Path
    Remove-ManagedTree -Path $full
}

function Move-TransactionDirectory {
    param([string]$ManagedRoot, [string]$SourcePath, [string]$DestinationPath)

    $source = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path $SourcePath
    $destination = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path $DestinationPath
    for ($attempt = 1; ; $attempt++) {
        try {
            [IO.Directory]::Move($source, $destination)
            return
        }
        catch {
            # Windows can briefly retain a lock after validation runs an executable
            # or a scanner opens its files. PowerShell wraps the native exception.
            $exception = $_.Exception.GetBaseException()
            $nativeError = $exception.HResult -band 0xFFFF
            if ($attempt -ge 10 -or
                ($exception -isnot [IO.IOException] -and $exception -isnot [UnauthorizedAccessException]) -or
                $nativeError -notin @(5, 32, 33)) {
                throw
            }
            Write-Verbose "Waiting for directory lock before moving '$source' to '$destination' (attempt $attempt of 10)."
            Start-Sleep -Milliseconds 300
        }
    }
}

function Restore-PreviousManagedDirectory {
    param([string]$ManagedRoot, [string]$ActivePath)
    $active = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path $ActivePath
    $previous = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path ($active + '.previous')
    if (-not (Test-Path -LiteralPath $active) -and (Test-Path -LiteralPath $previous)) {
        Move-TransactionDirectory -ManagedRoot $ManagedRoot -SourcePath $previous -DestinationPath $active
    }
}

function Promote-ManagedDirectory {
    param([string]$ManagedRoot, [string]$ActivePath, [string]$CandidatePath)

    $active = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path $ActivePath
    $candidate = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path $CandidatePath
    $previous = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path ($active + '.previous')
    $retired = Assert-TransactionChildPath -ManagedRoot $ManagedRoot -Path ($previous + '.retired.' + [guid]::NewGuid().ToString('N'))
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw "Missing candidate directory: $candidate" }
    Restore-PreviousManagedDirectory -ManagedRoot $ManagedRoot -ActivePath $active

    $retiredOldPrevious = $false
    $movedActive = $false
    try {
        if (Test-Path -LiteralPath $previous) {
            Move-TransactionDirectory -ManagedRoot $ManagedRoot -SourcePath $previous -DestinationPath $retired
            $retiredOldPrevious = $true
        }
        if (Test-Path -LiteralPath $active) {
            Move-TransactionDirectory -ManagedRoot $ManagedRoot -SourcePath $active -DestinationPath $previous
            $movedActive = $true
        }
        Move-TransactionDirectory -ManagedRoot $ManagedRoot -SourcePath $candidate -DestinationPath $active
    }
    catch {
        if ($movedActive -and -not (Test-Path -LiteralPath $active) -and (Test-Path -LiteralPath $previous)) {
            Move-TransactionDirectory -ManagedRoot $ManagedRoot -SourcePath $previous -DestinationPath $active
        }
        if ($retiredOldPrevious -and -not (Test-Path -LiteralPath $previous) -and (Test-Path -LiteralPath $retired)) {
            Move-TransactionDirectory -ManagedRoot $ManagedRoot -SourcePath $retired -DestinationPath $previous
        }
        throw
    }
    if ($retiredOldPrevious) {
        try { Remove-TransactionDirectory -ManagedRoot $ManagedRoot -Path $retired }
        catch { Write-Warning "New directory is active, but old recovery cleanup remains at ${retired}: $($_.Exception.Message)" }
    }
}

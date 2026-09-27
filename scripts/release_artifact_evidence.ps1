# Internal release-only checks for the exact artifacts produced by the smoke builds.
Set-StrictMode -Version Latest

function Assert-ArtifactRange {
    param([byte[]]$Bytes, [long]$Offset, [long]$Count, [string]$Label)
    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt ([long]$Bytes.Length - $Count)) {
        throw "Truncated or malformed $Label at byte offset $Offset"
    }
}

function Get-ArtifactBytes {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Label artifact: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -eq 0 -or $item.Length -gt 268435456) { throw "Invalid $Label artifact size: $($item.Length)" }
    return [IO.File]::ReadAllBytes($item.FullName)
}

function Read-ArtifactU16 {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ArtifactRange -Bytes $Bytes -Offset $Offset -Count 2 -Label $Label
    return [BitConverter]::ToUInt16($Bytes, [int]$Offset)
}

function Read-ArtifactU32 {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ArtifactRange -Bytes $Bytes -Offset $Offset -Count 4 -Label $Label
    return [BitConverter]::ToUInt32($Bytes, [int]$Offset)
}

function Read-ArtifactU64 {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ArtifactRange -Bytes $Bytes -Offset $Offset -Count 8 -Label $Label
    $value = [BitConverter]::ToUInt64($Bytes, [int]$Offset)
    if ($value -gt [long]::MaxValue) { throw "Invalid $Label offset" }
    return [long]$value
}

function Get-PEFileOffset {
    param([byte[]]$Bytes, [long]$SectionTable, [int]$SectionCount, [long]$Rva, [string]$Label)
    for ($i = 0; $i -lt $SectionCount; $i++) {
        $section = $SectionTable + $i * 40
        Assert-ArtifactRange -Bytes $Bytes -Offset $section -Count 40 -Label 'PE section table'
        $virtualSize = [long](Read-ArtifactU32 -Bytes $Bytes -Offset ($section + 8) -Label $Label)
        $virtualAddress = [long](Read-ArtifactU32 -Bytes $Bytes -Offset ($section + 12) -Label $Label)
        $rawSize = [long](Read-ArtifactU32 -Bytes $Bytes -Offset ($section + 16) -Label $Label)
        $rawOffset = [long](Read-ArtifactU32 -Bytes $Bytes -Offset ($section + 20) -Label $Label)
        if ($Rva -ge $virtualAddress -and $Rva -lt ($virtualAddress + [Math]::Max($virtualSize, $rawSize))) {
            $offset = $rawOffset + ($Rva - $virtualAddress)
            Assert-ArtifactRange -Bytes $Bytes -Offset $offset -Count 1 -Label $Label
            return $offset
        }
    }
    throw "PE $Label RVA 0x$('{0:X}' -f $Rva) is outside file sections"
}

function Read-ArtifactAsciiZ {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ArtifactRange -Bytes $Bytes -Offset $Offset -Count 1 -Label $Label
    $end = $Offset
    while ($end -lt $Bytes.Length -and $Bytes[[int]$end] -ne 0 -and ($end - $Offset) -lt 260) { $end++ }
    if ($end -ge $Bytes.Length -or ($end - $Offset) -ge 260) { throw "Unterminated PE $Label" }
    return [Text.Encoding]::ASCII.GetString($Bytes, [int]$Offset, [int]($end - $Offset))
}

function Assert-WindowsReleaseArtifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = Get-ArtifactBytes -Path $Path -Label 'Windows PE'
    Assert-ArtifactRange -Bytes $bytes -Offset 0 -Count 64 -Label 'Windows PE DOS header'
    if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Windows artifact is not PE/MZ: $Path" }
    $pe = [long](Read-ArtifactU32 -Bytes $bytes -Offset 0x3c -Label 'Windows PE offset')
    Assert-ArtifactRange -Bytes $bytes -Offset $pe -Count 24 -Label 'Windows PE header'
    if ($bytes[[int]$pe] -ne 0x50 -or $bytes[[int]($pe+1)] -ne 0x45 -or
        $bytes[[int]($pe+2)] -ne 0 -or $bytes[[int]($pe+3)] -ne 0) {
        throw "Windows artifact has an invalid PE signature: $Path"
    }
    $machine = Read-ArtifactU16 -Bytes $bytes -Offset ($pe + 4) -Label 'Windows PE machine'
    if ($machine -ne 0x8664) { throw "Windows artifact has wrong architecture 0x$('{0:X}' -f $machine); expected x64 PE: $Path" }
    $sections = Read-ArtifactU16 -Bytes $bytes -Offset ($pe + 6) -Label 'Windows PE section count'
    $optionalSize = Read-ArtifactU16 -Bytes $bytes -Offset ($pe + 20) -Label 'Windows PE optional size'
    $optional = $pe + 24
    if ($sections -lt 1 -or $sections -gt 96 -or $optionalSize -lt 128) { throw "Invalid Windows PE section/optional header: $Path" }
    Assert-ArtifactRange -Bytes $bytes -Offset $optional -Count $optionalSize -Label 'Windows PE optional header'
    if ((Read-ArtifactU16 -Bytes $bytes -Offset $optional -Label 'Windows PE magic') -ne 0x20b) {
        throw "Windows artifact is not PE32+ x64: $Path"
    }
    $sectionTable = $optional + $optionalSize
    Assert-ArtifactRange -Bytes $bytes -Offset $sectionTable -Count ($sections * 40) -Label 'Windows PE sections'
    $importRva = [long](Read-ArtifactU32 -Bytes $bytes -Offset ($optional + 120) -Label 'Windows PE import directory')
    if ($importRva -eq 0) { throw "Windows artifact has no imported runtime DLLs: $Path" }
    $allowed = @('kernel32.dll', 'bcryptprimitives.dll', 'ws2_32.dll', 'ntdll.dll',
        'api-ms-win-core-synch-l1-2-0.dll', 'bcrypt.dll', 'advapi32.dll', 'ucrtbase.dll')
    $imports = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt 128; $i++) {
        $descriptor = Get-PEFileOffset -Bytes $bytes -SectionTable $sectionTable -SectionCount $sections -Rva ($importRva + $i * 20) -Label 'import descriptor'
        Assert-ArtifactRange -Bytes $bytes -Offset $descriptor -Count 20 -Label 'PE import descriptor'
        $nameRva = [long](Read-ArtifactU32 -Bytes $bytes -Offset ($descriptor + 12) -Label 'PE import name')
        $firstThunk = Read-ArtifactU32 -Bytes $bytes -Offset ($descriptor + 16) -Label 'PE import thunk'
        if ($nameRva -eq 0 -and $firstThunk -eq 0) { break }
        if ($nameRva -eq 0) { throw "Malformed PE import descriptor: $Path" }
        $nameOffset = Get-PEFileOffset -Bytes $bytes -SectionTable $sectionTable -SectionCount $sections -Rva $nameRva -Label 'import DLL name'
        $name = Read-ArtifactAsciiZ -Bytes $bytes -Offset $nameOffset -Label 'import DLL name'
        if ($allowed -notcontains $name.ToLowerInvariant()) { throw "Unexpected Windows runtime DLL import '$name' in $Path" }
        $imports.Add($name.ToLowerInvariant())
    }
    if ($imports.Count -eq 0 -or $imports.Count -ge 128 -or $imports -notcontains 'ucrtbase.dll') {
        throw "Windows artifact lacks the expected UCRT/system import set: $Path"
    }
    Write-Host "Verified x64 PE and system DLL imports: $Path"
}

function Get-ReleaseElfInfo {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = Get-ArtifactBytes -Path $Path -Label 'ELF'
    Assert-ArtifactRange -Bytes $bytes -Offset 0 -Count 52 -Label 'ELF header'
    if ($bytes[0] -ne 0x7f -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4c -or $bytes[3] -ne 0x46 -or
        $bytes[5] -ne 1) { throw "Artifact is not little-endian ELF: $Path" }
    $class = [int]$bytes[4]
    if ($class -notin @(1, 2)) { throw "Unsupported ELF class $class in $Path" }
    $minimum = if ($class -eq 1) { 52 } else { 64 }
    Assert-ArtifactRange -Bytes $bytes -Offset 0 -Count $minimum -Label 'ELF header'
    $kind = Read-ArtifactU16 -Bytes $bytes -Offset 16 -Label 'ELF type'
    $machine = Read-ArtifactU16 -Bytes $bytes -Offset 18 -Label 'ELF machine'
    if ($class -eq 1) {
        $entry = [long](Read-ArtifactU32 -Bytes $bytes -Offset 24 -Label 'ELF entry')
        $programOffset = [long](Read-ArtifactU32 -Bytes $bytes -Offset 28 -Label 'ELF program offset')
        $flags = Read-ArtifactU32 -Bytes $bytes -Offset 36 -Label 'ELF flags'
        $entrySize = Read-ArtifactU16 -Bytes $bytes -Offset 42 -Label 'ELF program entry size'
        $programCount = Read-ArtifactU16 -Bytes $bytes -Offset 44 -Label 'ELF program count'
        $minimumEntrySize = 32
    }
    else {
        $entry = Read-ArtifactU64 -Bytes $bytes -Offset 24 -Label 'ELF entry'
        $programOffset = Read-ArtifactU64 -Bytes $bytes -Offset 32 -Label 'ELF program offset'
        $flags = Read-ArtifactU32 -Bytes $bytes -Offset 48 -Label 'ELF flags'
        $entrySize = Read-ArtifactU16 -Bytes $bytes -Offset 54 -Label 'ELF program entry size'
        $programCount = Read-ArtifactU16 -Bytes $bytes -Offset 56 -Label 'ELF program count'
        $minimumEntrySize = 56
    }
    if ($programCount -lt 1 -or $programCount -gt 256 -or $entrySize -lt $minimumEntrySize) {
        throw "Invalid ELF program header table: $Path"
    }
    Assert-ArtifactRange -Bytes $bytes -Offset $programOffset -Count ([long]$entrySize * $programCount) -Label 'ELF program headers'
    $programTypes = New-Object 'System.Collections.Generic.List[uint32]'
    for ($i = 0; $i -lt $programCount; $i++) {
        $programTypes.Add((Read-ArtifactU32 -Bytes $bytes -Offset ($programOffset + $i * $entrySize) -Label 'ELF program type'))
    }
    return [pscustomobject]@{
        Path = $Path; Bytes = $bytes; Class = $class; Kind = $kind
        Machine = $machine; Entry = $entry; Flags = $flags; ProgramTypes = $programTypes.ToArray()
    }
}

function Assert-LinuxReleaseArtifact {
    param([Parameter(Mandatory = $true)][string]$Path,
          [Parameter(Mandatory = $true)][ValidateSet('armv7', 'aarch64')][string]$Target)
    $elf = Get-ReleaseElfInfo -Path $Path
    $expectedClass = if ($Target -eq 'armv7') { 1 } else { 2 }
    $expectedMachine = if ($Target -eq 'armv7') { 40 } else { 183 }
    if ($elf.Class -ne $expectedClass -or $elf.Machine -ne $expectedMachine -or $elf.Kind -ne 2) {
        throw "Wrong ELF architecture/type for $Target in $Path (class $($elf.Class), machine $($elf.Machine), type $($elf.Kind))"
    }
    if ($Target -eq 'armv7' -and ($elf.Flags -band 0x400) -eq 0) {
        throw "ARMv7 ELF lacks the hard-float ABI flag: $Path"
    }
    if ($elf.ProgramTypes -contains 3 -or $elf.ProgramTypes -contains 2) {
        throw "Linux $Target ELF adds a dynamic interpreter or dependency segment: $Path"
    }
    Write-Host "Verified static $Target ELF architecture and ABI: $Path"
}

function Assert-FirmwareReleaseArtifacts {
    param([Parameter(Mandatory = $true)][string]$ElfPath,
          [Parameter(Mandatory = $true)][string]$BinPath,
          [Parameter(Mandatory = $true)][string]$HexPath)
    $flashStart = [long]0x08008000
    $flashEnd = [long]0x08040000
    $elf = Get-ReleaseElfInfo -Path $ElfPath
    if ($elf.Class -ne 1 -or $elf.Machine -ne 40 -or $elf.Kind -ne 2 -or
        ($elf.Flags -band 0x400) -eq 0 -or $elf.Entry -lt $flashStart -or
        $elf.Entry -ge $flashEnd -or ($elf.Entry -band 1) -eq 0) {
        throw "Firmware ELF has wrong Thumbv7EM architecture, ABI, or entry point: $ElfPath"
    }
    $bin = Get-ArtifactBytes -Path $BinPath -Label 'firmware BIN'
    if ($bin.Length -lt 8 -or $bin.Length -gt ($flashEnd - $flashStart)) {
        throw "Firmware BIN exceeds the 224 KiB active-app slot: $BinPath"
    }
    $stack = [long](Read-ArtifactU32 -Bytes $bin -Offset 0 -Label 'firmware initial stack pointer')
    $reset = [long](Read-ArtifactU32 -Bytes $bin -Offset 4 -Label 'firmware reset vector')
    if ($stack -ne 0x20030000 -or $reset -ne $elf.Entry -or $reset -lt $flashStart -or
        $reset -ge $flashEnd -or ($reset -band 1) -eq 0) {
        throw "Firmware vector table has invalid stack/reset address (SP 0x$('{0:X8}' -f $stack), Reset 0x$('{0:X8}' -f $reset)): $BinPath"
    }
    if (-not (Test-Path -LiteralPath $HexPath -PathType Leaf)) { throw "Missing firmware HEX artifact: $HexPath" }
    $upper = [long]0
    $dataCount = 0
    $startAddress = $null
    $seenEof = $false
    $firstBytes = New-Object bool[] 8
    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($HexPath))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($seenEof) { throw "Firmware HEX has records after EOF: $HexPath" }
        if ($line -notmatch '^:([0-9A-Fa-f]+)$' -or ($Matches[1].Length % 2) -ne 0) {
            throw "Malformed firmware HEX record: $HexPath"
        }
        $hexBytes = New-Object byte[] ([int]($Matches[1].Length / 2))
        for ($i = 0; $i -lt $hexBytes.Length; $i++) {
            $hexBytes[$i] = [Convert]::ToByte($Matches[1].Substring($i * 2, 2), 16)
        }
        if ($hexBytes.Length -lt 5 -or $hexBytes.Length -ne ([int]$hexBytes[0] + 5)) {
            throw "Firmware HEX record length mismatch: $HexPath"
        }
        $sum = 0
        foreach ($value in $hexBytes) { $sum += [int]$value }
        if (($sum -band 255) -ne 0) { throw "Firmware HEX checksum mismatch: $HexPath" }
        $count = [int]$hexBytes[0]
        $offset = ([int]$hexBytes[1] -shl 8) + [int]$hexBytes[2]
        $type = [int]$hexBytes[3]
        switch ($type) {
            0 {
                $address = ($upper -shl 16) + $offset
                for ($i = 0; $i -lt $count; $i++) {
                    $at = $address + $i
                    if ($at -lt $flashStart -or $at -ge $flashEnd -or ($at - $flashStart) -ge $bin.Length) {
                        throw "Firmware HEX data address 0x$('{0:X8}' -f $at) is outside the active-app image: $HexPath"
                    }
                    $index = [int]($at - $flashStart)
                    if ($hexBytes[4 + $i] -ne $bin[$index]) { throw "Firmware HEX/BIN byte mismatch at 0x$('{0:X8}' -f $at)" }
                    if ($index -lt 8) { $firstBytes[$index] = $true }
                    $dataCount++
                }
            }
            1 {
                if ($count -ne 0 -or $offset -ne 0) { throw "Invalid firmware HEX EOF record: $HexPath" }
                $seenEof = $true
            }
            4 {
                if ($count -ne 2 -or $offset -ne 0) { throw "Invalid firmware HEX extended address: $HexPath" }
                $upper = ([long]$hexBytes[4] -shl 8) + [long]$hexBytes[5]
            }
            5 {
                if ($count -ne 4 -or $offset -ne 0) { throw "Invalid firmware HEX start address: $HexPath" }
                $startAddress = ([long]$hexBytes[4] -shl 24) + ([long]$hexBytes[5] -shl 16) +
                    ([long]$hexBytes[6] -shl 8) + [long]$hexBytes[7]
            }
            default { throw "Unsupported firmware HEX record type $type in $HexPath" }
        }
    }
    if (-not $seenEof -or $dataCount -eq 0 -or $startAddress -ne $elf.Entry -or
        @($firstBytes | Where-Object { -not $_ }).Count -ne 0) {
        throw "Firmware HEX lacks EOF, vector data, or the ELF entry point: $HexPath"
    }
    Write-Host "Verified Thumbv7EM ELF/BIN/HEX vector and active-app addresses: $ElfPath"
}

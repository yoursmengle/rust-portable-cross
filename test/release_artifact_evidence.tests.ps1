Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\release_artifact_evidence.ps1')

function Put-U16 { param([byte[]]$Bytes, [int]$At, [uint16]$Value) [BitConverter]::GetBytes($Value).CopyTo($Bytes, $At) }
function Put-U32 { param([byte[]]$Bytes, [int]$At, [uint32]$Value) [BitConverter]::GetBytes($Value).CopyTo($Bytes, $At) }
function Put-U64 { param([byte[]]$Bytes, [int]$At, [uint64]$Value) [BitConverter]::GetBytes($Value).CopyTo($Bytes, $At) }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action }
    catch { $message = $_.Exception.Message }
    if ($message -notmatch $Pattern) { throw "Expected /$Pattern/, got: $message" }
}
function New-HexRecord {
    param([byte]$Type, [uint16]$Offset, [byte[]]$Data)
    $values = New-Object 'System.Collections.Generic.List[byte]'
    $values.Add([byte]$Data.Length)
    $values.Add([byte]($Offset -shr 8))
    $values.Add([byte]($Offset -band 255))
    $values.Add($Type)
    foreach ($byte in $Data) { $values.Add($byte) }
    $sum = 0
    foreach ($byte in $values) { $sum += [int]$byte }
    $values.Add([byte]((-$sum) -band 255))
    return ':' + (($values | ForEach-Object { '{0:X2}' -f $_ }) -join '')
}

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dist'))
$work = Join-Path $root ('u10-artifact-tests-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $pe = New-Object byte[] 1024
    $pe[0] = 0x4d; $pe[1] = 0x5a
    Put-U32 $pe 0x3c 0x80
    $pe[0x80] = 0x50; $pe[0x81] = 0x45
    Put-U16 $pe 0x84 0x8664
    Put-U16 $pe 0x86 1
    Put-U16 $pe 0x94 0xf0
    Put-U16 $pe 0x98 0x20b
    Put-U32 $pe 0x110 0x1000
    Put-U32 $pe 0x190 0x200
    Put-U32 $pe 0x194 0x1000
    Put-U32 $pe 0x198 0x200
    Put-U32 $pe 0x19c 0x200
    Put-U32 $pe 0x20c 0x1040
    Put-U32 $pe 0x210 0x1060
    [Text.Encoding]::ASCII.GetBytes('ucrtbase.dll').CopyTo($pe, 0x240)
    $pePath = Join-Path $work 'host.exe'
    [IO.File]::WriteAllBytes($pePath, $pe)
    Assert-WindowsReleaseArtifact -Path $pePath
    Put-U16 $pe 0x84 0x14c
    [IO.File]::WriteAllBytes($pePath, $pe)
    Assert-Throws -Action { Assert-WindowsReleaseArtifact -Path $pePath } -Pattern 'wrong architecture'
    Put-U16 $pe 0x84 0x8664
    [Text.Encoding]::ASCII.GetBytes("private.dll`0").CopyTo($pe, 0x240)
    [IO.File]::WriteAllBytes($pePath, $pe)
    Assert-Throws -Action { Assert-WindowsReleaseArtifact -Path $pePath } -Pattern 'Unexpected Windows runtime DLL'

    $arm = New-Object byte[] 128
    $arm[0] = 0x7f; $arm[1] = 0x45; $arm[2] = 0x4c; $arm[3] = 0x46
    $arm[4] = 1; $arm[5] = 1
    Put-U16 $arm 16 2
    Put-U16 $arm 18 40
    Put-U32 $arm 24 0x08008191
    Put-U32 $arm 28 52
    Put-U32 $arm 36 0x400
    Put-U16 $arm 42 32
    Put-U16 $arm 44 1
    Put-U32 $arm 52 1
    $armPath = Join-Path $work 'arm.elf'
    [IO.File]::WriteAllBytes($armPath, $arm)
    Assert-LinuxReleaseArtifact -Path $armPath -Target armv7
    Put-U32 $arm 36 0
    [IO.File]::WriteAllBytes($armPath, $arm)
    Assert-Throws -Action { Assert-LinuxReleaseArtifact -Path $armPath -Target armv7 } -Pattern 'hard-float ABI'
    Put-U32 $arm 36 0x400
    Put-U32 $arm 52 3
    [IO.File]::WriteAllBytes($armPath, $arm)
    Assert-Throws -Action { Assert-LinuxReleaseArtifact -Path $armPath -Target armv7 } -Pattern 'dynamic interpreter'
    Put-U32 $arm 52 1
    [IO.File]::WriteAllBytes($armPath, $arm)

    $aarch = New-Object byte[] 128
    [Array]::Copy($arm, $aarch, 6)
    $aarch[4] = 2
    Put-U16 $aarch 16 2
    Put-U16 $aarch 18 183
    Put-U64 $aarch 24 0x118bc80
    Put-U64 $aarch 32 64
    Put-U16 $aarch 54 56
    Put-U16 $aarch 56 1
    Put-U32 $aarch 64 1
    $aarchPath = Join-Path $work 'aarch64.elf'
    [IO.File]::WriteAllBytes($aarchPath, $aarch)
    Assert-LinuxReleaseArtifact -Path $aarchPath -Target aarch64
    Put-U16 $aarch 18 40
    [IO.File]::WriteAllBytes($aarchPath, $aarch)
    Assert-Throws -Action { Assert-LinuxReleaseArtifact -Path $aarchPath -Target aarch64 } -Pattern 'Wrong ELF architecture'

    $bin = New-Object byte[] 16
    Put-U32 $bin 0 0x20030000
    Put-U32 $bin 4 0x08008191
    $binPath = Join-Path $work 'firmware.bin'
    $hexPath = Join-Path $work 'firmware.hex'
    [IO.File]::WriteAllBytes($binPath, $bin)
    $hex = @(
        (New-HexRecord -Type 4 -Offset 0 -Data ([byte[]]@(0x08, 0x00))),
        (New-HexRecord -Type 0 -Offset 0x8000 -Data $bin),
        (New-HexRecord -Type 5 -Offset 0 -Data ([byte[]]@(0x08, 0x00, 0x81, 0x91))),
        (New-HexRecord -Type 1 -Offset 0 -Data ([byte[]]@()))
    )
    [IO.File]::WriteAllLines($hexPath, $hex)
    Assert-FirmwareReleaseArtifacts -ElfPath $armPath -BinPath $binPath -HexPath $hexPath
    Put-U32 $bin 4 0x08040001
    [IO.File]::WriteAllBytes($binPath, $bin)
    Assert-Throws -Action { Assert-FirmwareReleaseArtifacts -ElfPath $armPath -BinPath $binPath -HexPath $hexPath } -Pattern 'invalid stack/reset'
    Put-U32 $bin 4 0x08008191
    [IO.File]::WriteAllBytes($binPath, $bin)
    $hex[1] = New-HexRecord -Type 0 -Offset 0 -Data $bin
    [IO.File]::WriteAllLines($hexPath, $hex)
    Assert-Throws -Action { Assert-FirmwareReleaseArtifacts -ElfPath $armPath -BinPath $binPath -HexPath $hexPath } -Pattern 'outside the active-app image'
    $hex[1] = New-HexRecord -Type 0 -Offset 0x8000 -Data $bin
    $hex[1] = $hex[1].Substring(0, $hex[1].Length - 2) + '00'
    [IO.File]::WriteAllLines($hexPath, $hex)
    Assert-Throws -Action { Assert-FirmwareReleaseArtifacts -ElfPath $armPath -BinPath $binPath -HexPath $hexPath } -Pattern 'checksum mismatch'
    'release_artifact_evidence tests passed.'
}
finally {
    if (Test-Path -LiteralPath $work) {
        $resolved = [IO.Path]::GetFullPath($work)
        if (-not $resolved.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove artifact test directory outside dist: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

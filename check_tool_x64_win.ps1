Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSCommandPath
Push-Location $repoRoot
try {
	Push-Location .\sample
	try {
        ..\scripts\rust_build_x64_win_native.ps1 
	}
	finally {
		Pop-Location
	}
}
finally {
	Pop-Location
}

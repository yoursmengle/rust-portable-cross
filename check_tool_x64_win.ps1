Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSCommandPath
Push-Location $repoRoot
try {
	. .\scripts\rust_env.ps1
	Push-Location .\sample
	try {
		..\scripts\rust_build_x64_win.ps1
	}
	finally {
		Pop-Location
	}
}
finally {
	Pop-Location
}

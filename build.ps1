param(
	[switch]$StubLibs
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$buildDir = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$out = Join-Path $buildDir "odysseus.exe"
$buildArgs = @("build", ".", "-out:$out")

# This Odin nightly has no -config: flag. Bindings switch themselves:
# STUB_LIBS is true until vendor/*/lib/*.lib exists.
if ($StubLibs) {
	Write-Warning "ODYSSEUS_STUB_LIBS is no longer a compiler flag. Remove vendor/*/lib/*.lib to stub."
}

Push-Location $root
try {
	& odin @buildArgs
	if ($LASTEXITCODE -ne 0) {
		exit $LASTEXITCODE
	}
} finally {
	Pop-Location
}

Copy-Item "$root\vendor\ffmpeg\bin\*.dll" $buildDir -Force -ErrorAction SilentlyContinue
Copy-Item "$root\vendor\libdatachannel\bin\*.dll" $buildDir -Force -ErrorAction SilentlyContinue

# Previous builds dropped the exe and DLLs in the repo root.
Get-ChildItem $root -File -ErrorAction SilentlyContinue |
	Where-Object { $_.Name -eq "odysseus.exe" -or $_.Name -eq "odysseus.pdb" -or $_.Extension -eq ".dll" } |
	Remove-Item -Force

Write-Host "Built $out (DLLs copied to build\)"

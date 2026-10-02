<#
.SYNOPSIS
  Runs the unit tests of every package that has *_test.odin files.

.EXAMPLE
  tests\run.ps1                    # all packages
  tests\run.ps1 core server        # only these (names under src\)
  $env:ODIN_TEST_NAMES = "core.test_pick_level_table"; tests\run.ps1 core
  $env:ODIN_FLAGS = "-debug"; tests\run.ps1

  Exit code 0 when every package compiled and passed, 1 otherwise. Leaked
  memory in a test counts as a failure.

  The test binaries are written to build\: that is where the FFmpeg and
  libdatachannel DLLs live (src\core, src\server and src\network link them), so
  they are found next to the executable without touching PATH. On Linux/macOS
  (pwsh) the libraries come from the system.
#>
param(
	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]]$Packages
)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Get-Command odin -ErrorAction SilentlyContinue)) {
	Write-Error "odin not found on PATH"
	exit 2
}

$exe = ""
if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $exe = ".exe" }

New-Item -ItemType Directory -Force -Path (Join-Path $root "build") | Out-Null

if (-not $Packages -or $Packages.Count -eq 0) {
	$Packages = @(Get-ChildItem -Directory (Join-Path $root "src") |
		Where-Object { Get-ChildItem -Path $_.FullName -Filter "*_test.odin" -File -ErrorAction SilentlyContinue } |
		ForEach-Object { $_.Name } | Sort-Object)
}
if ($Packages.Count -eq 0) {
	Write-Error "no test packages found"
	exit 2
}

$extra = @()
if ($env:ODIN_TEST_NAMES) { $extra += "-define:ODIN_TEST_NAMES=$($env:ODIN_TEST_NAMES)" }
if ($env:ODIN_FLAGS) { $extra += ($env:ODIN_FLAGS -split '\s+' | Where-Object { $_ }) }

# Native stderr (odin logs there) must not turn into terminating errors on Windows PowerShell 5.1.
$ErrorActionPreference = "Continue"

$failedPkgs = @()
$summary = @()
$total = 0
$totalFailed = 0

foreach ($pkg in $Packages) {
	Write-Host "=== $pkg"
	if (-not (Test-Path (Join-Path $root "src/$pkg") -PathType Container)) {
		Write-Host "no such package: src/$pkg"
		$failedPkgs += $pkg
		$summary += ("{0,-10} missing" -f $pkg)
		continue
	}

	$odinArgs = @(
		"test", "src/$pkg", "-out:build/test_$pkg$exe",
		"-define:ODIN_TEST_FANCY=false",
		"-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true"
	) + $extra

	$lines = @(& odin @odinArgs 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } })
	$rc = $LASTEXITCODE
	$lines | ForEach-Object { Write-Host $_ }

	$finished = $lines | Where-Object { $_ -match '^Finished \d+ tests? in ' } | Select-Object -Last 1
	$n = 0
	$f = 0
	if ($finished) {
		if ($finished -match '^Finished (\d+) tests? in ') { $n = [int]$Matches[1] }
		if ($finished -match ' (\d+) tests? failed\.') { $f = [int]$Matches[1] }
	}
	$total += $n
	$totalFailed += $f

	if ($rc -ne 0 -or $f -ne 0 -or -not $finished) {
		$failedPkgs += $pkg
		if (-not $finished) {
			$summary += ("{0,-10} did not build/run (exit {1})" -f $pkg, $rc)
		} else {
			$summary += ("{0,-10} {1,4} tests, {2} failed (exit {3})" -f $pkg, $n, $f, $rc)
		}
	} else {
		$summary += ("{0,-10} {1,4} tests, 0 failed" -f $pkg, $n)
	}
}

Write-Host ""
Write-Host "=== summary"
$summary | ForEach-Object { Write-Host $_ }
Write-Host "total: $total tests, $totalFailed failed"

if ($failedPkgs.Count -gt 0) {
	Write-Host "FAILED: $($failedPkgs -join ' ')"
	exit 1
}
Write-Host "OK"
exit 0

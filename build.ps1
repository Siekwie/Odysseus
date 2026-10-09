<#
.SYNOPSIS
  Builds Odysseus on Windows into build\odysseus.exe and copies the vendored
  FFmpeg / libdatachannel DLLs next to it.

.EXAMPLE
  .\build.ps1            # optimized build
  .\build.ps1 debug      # debug build (no optimization, debug info)
  .\build.ps1 test       # unit tests (tests\run.ps1)
  .\build.ps1 check      # type-check every supported target without linking
#>
param(
	[ValidateSet("release", "debug", "test", "check")]
	[string]$Mode = "release"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$buildDir = Join-Path $root "build"

if (-not (Get-Command odin -ErrorAction SilentlyContinue)) {
	Write-Error "The Odin compiler is not on PATH (https://odin-lang.org/docs/install/)"
	exit 1
}

function Copy-RuntimeDlls {
	New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
	Copy-Item "$root\vendor\ffmpeg\bin\*.dll" $buildDir -Force
	Copy-Item "$root\vendor\libdatachannel\bin\*.dll" $buildDir -Force
}

Push-Location $root
try {
	switch ($Mode) {
		"test" {
			Copy-RuntimeDlls
			& "$root\tests\run.ps1"
			exit $LASTEXITCODE
		}
		"check" {
			foreach ($target in "windows_amd64", "linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64", "freebsd_amd64") {
				Write-Host "check $target"
				& odin check . "-target:$target"
				if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
			}
			& odin check . -target:linux_amd64 -define:ODYSSEUS_PIPEWIRE=true
			if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
			& odin check . -target:darwin_arm64 -define:ODYSSEUS_SCK=true
			exit $LASTEXITCODE
		}
	}

	if (-not (Test-Path "$root\vendor\ffmpeg\lib\avcodec.lib") -or -not (Test-Path "$root\vendor\libdatachannel\lib\datachannel.lib")) {
		Write-Error "The vendored libraries are missing under vendor\. See scripts\fetch-libs.ps1."
		exit 1
	}

	Copy-RuntimeDlls
	$out = Join-Path $buildDir "odysseus.exe"
	$buildArgs = @("build", ".", "-out:$out")
	if ($Mode -eq "debug") {
		$buildArgs += @("-o:none", "-debug")
	} else {
		$buildArgs += "-o:speed"
	}
	& odin @buildArgs
	if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
	Write-Host "Built $out"
} finally {
	Pop-Location
}

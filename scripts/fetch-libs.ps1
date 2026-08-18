# Fetch / rebuild native libs used by Odysseus (Windows x64).
# Runtime artifacts that belong in git live under:
#   vendor/ffmpeg/{bin,lib}
#   vendor/libdatachannel/{bin,lib}
# Source trees (vendor/mbedtls, vendor/libdatachannel/upstream) are gitignored.

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Mingw = "C:\Users\Jannik.Wiest\scoop\apps\mingw\current\bin"
$env:PATH = "$Mingw;C:\Program Files\CMake\bin;" + $env:PATH

Write-Host "FFmpeg n8.1 win64 gpl-shared is already under vendor/ffmpeg."
Write-Host "  Source: https://github.com/BtbN/FFmpeg-Builds/releases (ffmpeg-n8.1-latest-win64-gpl-shared-8.1)"

$ldcSrc = Join-Path $Root "vendor\libdatachannel\upstream"
$ldcBuild = Join-Path $Root "vendor\libdatachannel\build"
$mbedtls = Join-Path $Root "vendor\mbedtls"
$mbedtlsInstall = Join-Path $mbedtls "install"
$mbedtlsStamp = Join-Path $mbedtlsInstall ".odysseus-mbedtls-config"
$mbedtlsWanted = "srtp=1 tls13=0 threading=1 v2"

function Set-MbedtlsDefine {
	param(
		[string]$Path,
		[string]$Name,
		[bool]$Enable
	)
	$raw = Get-Content $Path -Raw
	if ($Enable) {
		$raw = [regex]::Replace($raw, "(?m)^//#define $Name\s*$", "#define $Name")
	} else {
		$raw = [regex]::Replace($raw, "(?m)^#define $Name\s*$", "//#define $Name")
	}
	Set-Content -Path $Path -Value $raw -NoNewline
}

if (-not (Test-Path (Join-Path $ldcSrc "CMakeLists.txt"))) {
	Write-Host "Cloning libdatachannel (recursive)..."
	git clone --depth 1 --recursive https://github.com/paullouisageneau/libdatachannel.git $ldcSrc
}

if (-not (Test-Path (Join-Path $mbedtls "CMakeLists.txt"))) {
	git clone --depth 1 --branch v3.6.4 https://github.com/Mbed-TLS/mbedtls.git $mbedtls
	git -C $mbedtls submodule update --init --recursive --depth 1
}

$cfg = Join-Path $mbedtls "include\mbedtls\mbedtls_config.h"
Set-MbedtlsDefine $cfg "MBEDTLS_SSL_DTLS_SRTP" $true
Set-MbedtlsDefine $cfg "MBEDTLS_SSL_PROTO_TLS1_3" $false
Set-MbedtlsDefine $cfg "MBEDTLS_THREADING_C" $true
Set-MbedtlsDefine $cfg "MBEDTLS_THREADING_PTHREAD" $true

$needMbedtls = $true
if ((Test-Path (Join-Path $mbedtlsInstall "lib\libmbedtls.a")) -and
	((Get-Content $mbedtlsStamp -ErrorAction SilentlyContinue) -eq $mbedtlsWanted)) {
	$needMbedtls = $false
}

if ($needMbedtls) {
	Write-Host "Building Mbed TLS (DTLS-SRTP, TLS 1.2 only, pthread)..."
	cmake -S $mbedtls -B (Join-Path $mbedtls "build") -G "MinGW Makefiles" `
		-DCMAKE_BUILD_TYPE=Release -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF `
		("-DCMAKE_INSTALL_PREFIX=" + $mbedtlsInstall)
	cmake --build (Join-Path $mbedtls "build") --target install -j 8
	New-Item -ItemType Directory -Force -Path $mbedtlsInstall | Out-Null
	Set-Content -Path $mbedtlsStamp -Value $mbedtlsWanted
}

Write-Host "Building libdatachannel..."
cmake -S $ldcSrc -B $ldcBuild -G "MinGW Makefiles" `
	-DCMAKE_BUILD_TYPE=Release -DUSE_MBEDTLS=ON -DUSE_NICE=OFF `
	-DNO_EXAMPLES=ON -DNO_TESTS=ON -DBUILD_SHARED_LIBS=ON -DNO_WEBSOCKET=ON `
	-DENABLE_WARNINGS_AS_ERRORS=OFF ("-DCMAKE_PREFIX_PATH=" + $mbedtlsInstall)
cmake --build $ldcBuild --config Release -j 8

$bin = Join-Path $Root "vendor\libdatachannel\bin"
$lib = Join-Path $Root "vendor\libdatachannel\lib"
New-Item -ItemType Directory -Force -Path $bin,$lib | Out-Null
Copy-Item (Join-Path $ldcBuild "libdatachannel.dll") (Join-Path $bin "libdatachannel.dll") -Force
foreach ($dll in @("libstdc++-6.dll","libgcc_s_seh-1.dll","libwinpthread-1.dll")) {
	Copy-Item (Join-Path $Mingw $dll) (Join-Path $bin $dll) -Force
}
Push-Location $bin
gendef libdatachannel.dll
dlltool -d libdatachannel.def -l (Join-Path $lib "datachannel.lib") -D libdatachannel.dll -k
Remove-Item libdatachannel.def -ErrorAction SilentlyContinue
Pop-Location
Write-Host "Vendored libdatachannel into vendor/libdatachannel/{bin,lib}"

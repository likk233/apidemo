param([ValidateSet('x64','ARM64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $ProjectRoot ".build/windows-$Architecture"
$OutputRoot = Join-Path $ProjectRoot "dist/windows-$($Architecture.ToLower())"
cmake -S (Join-Path $ProjectRoot 'Windows') -B $BuildRoot -A $Architecture
if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed' }
cmake --build $BuildRoot --config Release
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
$HostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($Architecture -eq 'ARM64' -and $HostArchitecture -ne 'Arm64') {
    Write-Host 'ARM64 tests were compiled; execute them on an ARM64 Windows device.'
} else {
    ctest --test-dir $BuildRoot -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Offline tests failed' }
}
New-Item -ItemType Directory -Force $OutputRoot | Out-Null
Copy-Item (Join-Path $BuildRoot 'Release/UsageBar.exe') $OutputRoot
Copy-Item (Join-Path $ProjectRoot 'LICENSE'), (Join-Path $ProjectRoot 'THIRD_PARTY_NOTICES.txt'), (Join-Path $ProjectRoot 'Windows/vendor/JSON-LICENSE.txt') $OutputRoot
Copy-Item (Join-Path $ProjectRoot 'Windows/README.md') (Join-Path $OutputRoot 'README.txt')
Copy-Item (Join-Path $ProjectRoot 'Windows/vendor/licenses') $OutputRoot -Recurse -Force
$Archive = Join-Path $ProjectRoot "dist/UsageBar-Windows-$($Architecture.ToLower()).zip"
$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ("UsageBarPackage-" + [Guid]::NewGuid())
try {
    $Package = Join-Path $Stage 'UsageBar-Windows'
    New-Item -ItemType Directory -Force (Join-Path $Package 'licenses') | Out-Null
    foreach ($Name in @('UsageBar.exe', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'JSON-LICENSE.txt', 'README.txt')) {
        Copy-Item (Join-Path $OutputRoot $Name) $Package
    }
    foreach ($Name in @('LLVM-LICENSE.txt', 'MINGW-RUNTIME.txt', 'WINPTHREADS-LICENSE.txt')) {
        Copy-Item (Join-Path $OutputRoot "licenses/$Name") (Join-Path $Package 'licenses')
    }
    Compress-Archive -Path $Package -DestinationPath $Archive -Force
} finally {
    if (Test-Path $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
}
Write-Host "Built: $OutputRoot/UsageBar.exe"
Write-Host "Archive: $Archive"

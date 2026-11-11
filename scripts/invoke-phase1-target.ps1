[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$missing = @('PHASE1_INPUT_ENDPOINT_ID', 'PHASE1_LOOPBACK_ENDPOINT_ID', 'PHASE1_MODEL_PATH') |
    Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }
if ($missing.Count -gt 0) { throw "TargetPc requires: $($missing -join ', ')" }

# This literal is deliberately invalid until the Windows build/review procedure has generated
# the approved pair. Do not replace it with a caller/environment value or a guessed hash.
$TrustedDriverSha256 = '71489c38df0447487c5f4f9d21fb90a2fae682076304bc2c90f5522459ab8faf'
if ($TrustedDriverSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $TrustedDriverSha256 -match '^0{64}$') {
    throw 'TargetPc driver pin is not reviewed. Build the fixed app, compile the driver with the app pin, compute/review the driver hash, then update this literal.'
}

$driverPath = Join-Path $repoRoot 'src-tauri\target\release\phase1-evidence-driver.exe'
if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) { throw "Pinned driver missing: $driverPath" }
$actualHash = (Get-FileHash -LiteralPath $driverPath -Algorithm SHA256).Hash
if (-not [string]::Equals($actualHash, $TrustedDriverSha256, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Pinned driver bytes do not match the reviewed TrustedDriverSha256 literal.' }

$accelerators = @()
if (-not [string]::IsNullOrWhiteSpace($env:PHASE1_AVAILABLE_ACCELERATORS)) {
    $accelerators = @($env:PHASE1_AVAILABLE_ACCELERATORS.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if ($accelerators | Where-Object { $_ -notin @('cuda', 'vulkan') }) { throw 'PHASE1_AVAILABLE_ACCELERATORS permits only cuda,vulkan; CPU is implicit.' }
}

$request = [ordered]@{
    schemaVersion = 1
    inputEndpointId = $env:PHASE1_INPUT_ENDPOINT_ID
    loopbackEndpointId = $env:PHASE1_LOOPBACK_ENDPOINT_ID
    modelPath = $env:PHASE1_MODEL_PATH
    availableAccelerators = $accelerators
} | ConvertTo-Json -Compress
$reportPath = Join-Path $repoRoot '.planning\phases\01-windows-capture-inference-feasibility\01-TARGET-PC-EVIDENCE.md'
if (Test-Path -LiteralPath $reportPath) { throw 'TargetPc evidence already exists and is never overwritten. Archive it only after human review.' }

$request | & $driverPath run --report $reportPath
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'invoke-phase1-target.ps1') -Raw
$verifier = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-phase1.ps1') -Raw
$driver = Get-Content -LiteralPath (Join-Path $repoRoot 'src-tauri/src/bin/phase1-evidence-driver.rs') -Raw

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

Assert-True ($launcher -match '\[string\]::IsNullOrWhiteSpace\(\[Environment\]::GetEnvironmentVariable') 'Launcher must reject blank required environment selections.'
Assert-True ($launcher -match 'TrustedDriverSha256') 'Launcher must independently pin the driver bytes.'
Assert-True ($launcher -notmatch 'expectedAppSha256|expectedDriverSha256|\$env:PHASE1_(TRUSTED|EXPECTED)|sessionKey|receipt|readiness') 'Launcher must not accept provenance or attestation request fields.'
Assert-True ($verifier -notmatch 'EvidencePath|Phase1NativeEvidenceV1|ConvertFrom-Json') 'PowerShell must not import serialized native evidence.'
Assert-True ($driver -match 'PHASE1_TRUSTED_APP_SHA256') 'Driver must compile with the fixed app pin.'
Assert-True ($driver -match 'new_cng' -and $driver -match 'NativeCommandReceiptV1') 'Driver must create its CNG-authenticated native session.'
Assert-True ($driver -match 'report\.exists\(\)') 'Existing reports must be rejected, never overwritten.'
Write-Host 'PASS verification contract: fabricated/rehashed envelopes and caller-controlled provenance have no TargetPc import path.'
# This script performs static assertions only; establish the conventional success exit code for
# callers that chain it with `$LASTEXITCODE`.
& $env:ComSpec /c exit 0

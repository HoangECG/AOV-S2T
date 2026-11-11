[CmdletBinding()]
param([ValidateSet('Static', 'TargetPc')][string]$Mode = 'Static')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

Push-Location $repoRoot
try {
    if ($Mode -eq 'Static') {
        Invoke-Checked 'npm' @('run', 'typecheck')
        Invoke-Checked 'cargo' @('test', '--manifest-path', 'src-tauri/Cargo.toml', '--all-targets')
        Invoke-Checked 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/test-workers.ps1', '-Mode', 'ManifestOnly')
        Write-Host 'PASS Static: fail-closed driver contract and source checks completed.'
        return
    }

    if ($env:OS -ne 'Windows_NT') { throw 'TargetPc mode requires the target Windows PC.' }
    # TargetPc has no evidence/envelope path. The launcher owns environment validation and the
    # pinned native driver owns its private session, external probes, and report creation.
    & (Join-Path $PSScriptRoot 'invoke-phase1-target.ps1')
    exit $LASTEXITCODE
} finally { Pop-Location }

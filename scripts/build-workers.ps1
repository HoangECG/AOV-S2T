[CmdletBinding()]
param(
    [ValidateSet('cpu', 'cuda', 'vulkan', 'all')]
    [string]$Backend = 'all',
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..\\.cache\\whisper.cpp'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\\workers\\out'),
    [ValidatePattern('^\d+(;\d+)*$')]
    [string]$CudaArchitectures
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $repoRoot 'workers\\manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$workerProject = Join-Path $repoRoot 'workers'
$vadModelName = 'ggml-silero-v6.2.0.bin'
$vadModelSha256 = '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987'

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required to build workers."
    }
}

function Add-VisualStudioCmakeToPath {
    if (Get-Command cmake -ErrorAction SilentlyContinue) { return }
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return }
    $installation = [string](& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath)
    $installation = $installation.Trim()
    if ([string]::IsNullOrWhiteSpace($installation)) { return }
    $cmake = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (Test-Path -LiteralPath $cmake -PathType Leaf) {
        $env:Path = "$(Split-Path -Parent $cmake);$env:Path"
    }
}

if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::Is64BitProcess -eq $false) {
    throw 'Worker builds require a 64-bit Windows build host.'
}
Require-Command git
Add-VisualStudioCmakeToPath
Require-Command cmake

if (-not (Test-Path (Join-Path $SourceRoot '.git'))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SourceRoot -Parent) | Out-Null
    & git clone --filter=blob:none $manifest.source.repository $SourceRoot
}

& git -C $SourceRoot fetch --depth 1 origin $manifest.source.revision
& git -C $SourceRoot checkout --detach $manifest.source.revision
if ((& git -C $SourceRoot rev-parse HEAD).Trim() -ne $manifest.source.revision) {
    throw 'whisper.cpp source revision did not resolve to the pinned manifest revision.'
}

$requested = if ($Backend -eq 'all') { @('cpu', 'cuda', 'vulkan') } elseif ($Backend -eq 'cpu') { @('cpu') } else { @('cpu', $Backend) }
$sealedWorkers = @()
$buildFailures = @()
foreach ($kind in $requested | Select-Object -Unique) {
    $worker = @($manifest.workers | Where-Object kind -eq $kind)[0]
    if ($null -eq $worker) { throw "No $kind worker is declared in the manifest." }
    $buildDir = Join-Path $repoRoot ".cache\\worker-build-$kind"
    $destination = Join-Path $OutputRoot "x86_64-pc-windows-msvc\\$kind"
    try {
        $vadModel = Join-Path $SourceRoot 'models\for-tests-silero-v6.2.0-ggml.bin'
        if (-not (Test-Path -LiteralPath $vadModel -PathType Leaf)) {
            throw 'Pinned Silero VAD model is missing from whisper.cpp source.'
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $vadModel).Hash.ToLowerInvariant() -ne $vadModelSha256) {
            throw 'Pinned Silero VAD model checksum mismatch.'
        }
        $flags = @(
            "-DWHISPER_CPP_SOURCE_DIR=$SourceRoot",
            "-DWORKER_BACKEND=$kind",
            "-DWORKER_BUILD_ID=$($worker.buildId)",
            "-DWORKER_MODEL_REVISION=$($worker.modelRevision)"
        ) + @($worker.cmakeFlags)
        if ($kind -eq 'cuda' -and $CudaArchitectures) {
            $flags += "-DCMAKE_CUDA_ARCHITECTURES=$CudaArchitectures"
        }
        & cmake -S $workerProject -B $buildDir -A x64 @flags
        if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $kind." }
        & cmake --build $buildDir --config Release --target live-subtitle-worker
        if ($LASTEXITCODE -ne 0) { throw "CMake build failed for $kind." }
        $binary = Get-ChildItem -LiteralPath $buildDir -Filter (Split-Path $worker.executable -Leaf) -Recurse | Select-Object -First 1
        if ($null -eq $binary) { throw "Repository worker executable was not produced for $kind." }
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $destination $binary.Name) -Force
        Copy-Item -LiteralPath $vadModel -Destination (Join-Path $destination $vadModelName) -Force
        @(
            $binary.DirectoryName
            (Join-Path $buildDir 'bin\Release')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter '*.dll' -File | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destination $_.Name) -Force
            }
        }
        if ($kind -eq 'cuda') {
            $cudaBin = Join-Path (Split-Path (Get-Command nvcc -ErrorAction Stop).Source -Parent) 'x64'
            foreach ($runtimePattern in 'cublas64_*.dll', 'cublasLt64_*.dll') {
                $runtime = Get-ChildItem -Path (Join-Path $cudaBin $runtimePattern) -File | Select-Object -First 1
                if ($null -eq $runtime) { throw "CUDA runtime $runtimePattern was not found." }
                Copy-Item -LiteralPath $runtime.FullName -Destination (Join-Path $destination $runtime.Name) -Force
            }
        }
        $files = Get-ChildItem -LiteralPath $destination -File | ForEach-Object {
            [pscustomobject]@{
                path = ('workers/out/x86_64-pc-windows-msvc/{0}/{1}' -f $kind, $_.Name)
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            }
        }
        if (-not (@($files.path) -contains $worker.executable)) { throw "Sealed inventory is missing $kind executable." }
        if (-not (@($files.path) -contains "workers/out/x86_64-pc-windows-msvc/$kind/$vadModelName")) { throw "Sealed inventory is missing $kind VAD model." }
        $worker.files = @($files)
        $sealedWorkers += $worker
        Write-Host "Built repository-owned $kind protocol worker."
    } catch {
        $buildFailures += "${kind}: $($_.Exception.Message)"
        Write-Warning "Worker $kind was not sealed: $($_.Exception.Message)"
    }
}

$sealed = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$sealed.packageState = 'sealed'
$sealed.workers = @($sealedWorkers)
$sealedPath = Join-Path $OutputRoot 'x86_64-pc-windows-msvc\\manifest.json'
New-Item -ItemType Directory -Force -Path (Split-Path $sealedPath -Parent) | Out-Null
[IO.File]::WriteAllText($sealedPath, ($sealed | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
if ($sealedWorkers.Count -eq 0 -or $buildFailures.Count -gt 0) {
    throw "Worker sealing incomplete: $($buildFailures -join '; ')"
}
Write-Host 'Generated sealed release inventory. Build outputs are deliberately not committed; run scripts/test-workers.ps1 -Mode Candidate with the pinned model on the target PC.'

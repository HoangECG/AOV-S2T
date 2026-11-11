[CmdletBinding()]
param(
    [string]$ModelPath,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'com.local.livesubtitletool'),
    [string]$WorkRoot = (Join-Path $env:LOCALAPPDATA 'com.local.livesubtitletool\phowhisper-build')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $repoRoot 'src-tauri\resources\model-manifest.json'
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-VerifiedFile([string]$Path, [Int64]$ExpectedBytes, [string]$ExpectedSha256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $ExpectedBytes) { return $false }
    return (Get-Sha256 $Path) -eq $ExpectedSha256.ToLowerInvariant()
}

function Assert-VerifiedFile([string]$Path, [Int64]$ExpectedBytes, [string]$ExpectedSha256) {
    Assert-That (Test-Path -LiteralPath $Path -PathType Leaf) "Missing file: $Path"
    $actualBytes = (Get-Item -LiteralPath $Path).Length
    Assert-That ($actualBytes -eq $ExpectedBytes) "Unexpected size for $Path. Expected $ExpectedBytes bytes, got $actualBytes."
    $actualSha256 = Get-Sha256 $Path
    Assert-That ($actualSha256 -eq $ExpectedSha256.ToLowerInvariant()) "SHA-256 mismatch for $Path."
}

function Get-HfResolveUri([string]$Repository, [string]$Revision, [string]$Name) {
    return "https://huggingface.co/$Repository/resolve/$Revision/$Name?download=true"
}

function Get-RawGithubUri([string]$Repository, [string]$Revision, [string]$Path) {
    return "https://raw.githubusercontent.com/$Repository/$Revision/$Path"
}

function Download-PinnedFile([string]$Uri, [string]$Destination, [Int64]$ExpectedBytes, [string]$ExpectedSha256) {
    if (Test-VerifiedFile $Destination $ExpectedBytes $ExpectedSha256) {
        Write-Host "Verified existing $Destination"
        return
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Remove-Item -LiteralPath $Destination -Force
    }
    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    $temporary = "$Destination.part"
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary -Force
    }
    Write-Host "Downloading $Uri"
    & curl.exe --fail --location --retry 3 --retry-delay 2 --output $temporary $Uri
    if ($LASTEXITCODE -ne 0) { throw "Download failed for $Uri" }
    Assert-VerifiedFile $temporary $ExpectedBytes $ExpectedSha256
    Move-Item -LiteralPath $temporary -Destination $Destination
}

function Get-AvailableBytes([string]$Path) {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)).TrimEnd('\\')
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$root'"
    Assert-That ($null -ne $disk) "Cannot determine free space for $Path."
    return [Int64]$disk.FreeSpace
}

function Install-VerifiedModel([string]$Artifact, [bool]$MoveArtifact, [string]$Destination) {
    Assert-VerifiedFile $Artifact $manifest.expectedBytes $manifest.sha256
    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    if (Test-VerifiedFile $Destination $manifest.expectedBytes $manifest.sha256) {
        Write-Host "Verified PhoWhisper GGML is already installed at $Destination"
        return
    }
    $temporary = "$Destination.part"
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary -Force
    }
    if ($MoveArtifact) {
        Move-Item -LiteralPath $Artifact -Destination $temporary
    } else {
        Copy-Item -LiteralPath $Artifact -Destination $temporary
    }
    Assert-VerifiedFile $temporary $manifest.expectedBytes $manifest.sha256
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backup = "$Destination.backup"
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force
        }
        [IO.File]::Replace($temporary, $Destination, $backup, $true)
        Remove-Item -LiteralPath $backup -Force
    } else {
        [IO.File]::Move($temporary, $Destination)
    }
    Assert-VerifiedFile $Destination $manifest.expectedBytes $manifest.sha256
    Write-Host "Installed verified PhoWhisper GGML at $Destination"
}

Assert-That ($manifest.modelId -eq 'ggml-phowhisper-large') 'Unexpected model manifest.'
Assert-That ($manifest.installationMode -eq 'local-conversion') 'Model manifest must use local conversion.'
Assert-That ($manifest.source.repository -eq 'vinai/PhoWhisper-large') 'Unexpected source repository.'
Assert-That ($manifest.source.revision -eq $manifest.revision) 'Source revision must match the model revision.'
Assert-That ($manifest.source.checkpoint -eq 'pytorch_model.bin') 'Unexpected source checkpoint.'
Assert-That ($manifest.converter.repository -eq 'ggml-org/whisper.cpp') 'Unexpected converter repository.'
Assert-That ($manifest.melFilters.repository -eq 'openai/whisper') 'Unexpected mel filter repository.'

$destination = Join-Path $InstallRoot "models\$($manifest.modelId)\$($manifest.revision)\$($manifest.artifactName)"
if ($ModelPath) {
    $existingArtifact = (Resolve-Path -LiteralPath $ModelPath -ErrorAction Stop).Path
    Install-VerifiedModel $existingArtifact $false $destination
    exit 0
}

$sourceRoot = Join-Path $WorkRoot 'source'
$newSourceBytes = 0L
foreach ($file in @($manifest.source.files)) {
    $path = Join-Path $sourceRoot $file.name
    if (-not (Test-VerifiedFile $path $file.expectedBytes $file.sha256)) {
        $newSourceBytes += [Int64]$file.expectedBytes
    }
}
$requiredBytes = [Int64]$manifest.expectedBytes + $newSourceBytes + 1GB
$availableBytes = Get-AvailableBytes $InstallRoot
Assert-That ($availableBytes -ge $requiredBytes) "Need at least $requiredBytes bytes free on the install drive; only $availableBytes bytes are available."

# All network requests are public, read-only downloads. This script never invokes hf auth or hf upload.
foreach ($file in @($manifest.source.files)) {
    $sourceUri = Get-HfResolveUri $manifest.source.repository $manifest.source.revision $file.name
    Download-PinnedFile $sourceUri (Join-Path $sourceRoot $file.name) $file.expectedBytes $file.sha256
}

$converterPath = Join-Path $WorkRoot 'tools\convert-h5-to-ggml.py'
$converterUri = Get-RawGithubUri $manifest.converter.repository $manifest.converter.revision $manifest.converter.script
Download-PinnedFile $converterUri $converterPath $manifest.converter.expectedBytes $manifest.converter.sha256

$openAiRoot = Join-Path $WorkRoot 'openai-whisper'
$melPath = Join-Path $openAiRoot $manifest.melFilters.path
$melUri = Get-RawGithubUri $manifest.melFilters.repository $manifest.melFilters.revision $manifest.melFilters.path
Download-PinnedFile $melUri $melPath $manifest.melFilters.expectedBytes $manifest.melFilters.sha256

$python = Get-Command python -ErrorAction Stop
$pythonVersion = [Version](& $python.Source -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
Assert-That ($pythonVersion -ge [Version]'3.10') 'Python 3.10 or newer is required for local conversion.'
$venvRoot = Join-Path $WorkRoot 'venv'
$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    & $python.Source -m venv $venvRoot
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the conversion virtual environment.' }
}
& $venvPython -m pip install --disable-pip-version-check --no-input 'torch==2.5.1' 'transformers==4.31.0' 'numpy==1.26.4'
if ($LASTEXITCODE -ne 0) { throw 'Could not install the pinned conversion dependencies.' }

$destinationDirectory = Split-Path -Parent $destination
New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
$converted = Join-Path $destinationDirectory 'ggml-model.bin'
if (Test-Path -LiteralPath $converted -PathType Leaf) {
    Remove-Item -LiteralPath $converted -Force
}
& $venvPython $converterPath $sourceRoot $openAiRoot $destinationDirectory
if ($LASTEXITCODE -ne 0) { throw 'PhoWhisper GGML conversion failed.' }
Install-VerifiedModel $converted $true $destination

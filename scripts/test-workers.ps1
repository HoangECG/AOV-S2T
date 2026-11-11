[CmdletBinding()]
param(
    [ValidateSet('ManifestOnly', 'Candidate')]
    [string]$Mode = 'ManifestOnly',
    [ValidateSet('cpu', 'cuda', 'vulkan')]
    [string]$Candidate,
    [string]$ModelPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $repoRoot 'workers\\manifest.json'
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$runtimeManifestPath = Join-Path $repoRoot 'workers\\out\\x86_64-pc-windows-msvc\\manifest.json'
$modelManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'src-tauri\\resources\\model-manifest.json') | ConvertFrom-Json

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-NormalizedTranscript([string]$Value) {
    if ($null -eq $Value) { return '' }
    $normalized = $Value.Trim().ToLowerInvariant() -replace '[.,!?;:]+$', ''
    return (($normalized -replace '\s+', ' ').Trim())
}

function Get-WavFormat([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-That ($bytes.Length -ge 44) 'Fixture WAV is too short.'
    Assert-That ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'RIFF') 'Fixture is not RIFF.'
    Assert-That ([Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq 'WAVE') 'Fixture is not WAVE.'
    Assert-That ([Text.Encoding]::ASCII.GetString($bytes, 12, 4) -eq 'fmt ') 'Fixture has no PCM fmt chunk.'
    return [pscustomobject]@{
        Format = [BitConverter]::ToUInt16($bytes, 20)
        Channels = [BitConverter]::ToUInt16($bytes, 22)
        SampleRate = [BitConverter]::ToUInt32($bytes, 24)
        BitsPerSample = [BitConverter]::ToUInt16($bytes, 34)
    }
}

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($stream)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
    }
}

function Assert-Manifest {
    Assert-That ($manifest.schemaVersion -eq 1) 'Unsupported worker manifest schema.'
    Assert-That ($manifest.packageState -in @('build-required', 'sealed')) 'Unknown worker package state.'
    Assert-That ($manifest.releaseTarget.architecture -eq 'x86_64') 'Worker target architecture must be x86_64.'
    Assert-That ($manifest.source.repository -eq 'https://github.com/ggml-org/whisper.cpp.git') 'Worker source repository is not approved.'
    Assert-That ($manifest.source.revision -match '^[0-9a-f]{40}$') 'Worker source revision must be a pinned commit.'
    Assert-That ($manifest.model.modelRevision -eq $modelManifest.revision) 'Worker/model revision mismatch.'
    Assert-That ($modelManifest.workerCompatibility -eq "ggml-org/whisper.cpp@$($manifest.source.revision)") 'Model does not declare this worker source revision.'
    $expectedKinds = if ($manifest.packageState -eq 'build-required') { @('cpu', 'cuda', 'vulkan') } else { @($manifest.workers | ForEach-Object kind) }
    if ($manifest.packageState -eq 'build-required') {
        Assert-That (@($manifest.workers).Count -eq 3) 'Build declaration must declare CPU, CUDA, and Vulkan.'
    } else {
        Assert-That (@($manifest.workers | Where-Object kind -eq 'cpu').Count -eq 1) 'Sealed inventory must include CPU.'
        Assert-That (@($manifest.workers).Count -le 3) 'Sealed inventory has an unsupported backend.'
    }
    foreach ($kind in $expectedKinds) {
        $entry = @($manifest.workers | Where-Object kind -eq $kind)
        Assert-That ($entry.Count -eq 1) "Worker inventory has duplicate or missing $kind entries."
        Assert-That ($entry[0].backend -eq $kind) "$kind backend identity is inconsistent."
        Assert-That ($entry[0].sourceRevision -eq $manifest.source.revision) "$kind source revision mismatch."
        Assert-That ($entry[0].modelRevision -eq $manifest.model.modelRevision) "$kind model revision mismatch."
        Assert-That ($entry[0].architecture -eq 'x86_64') "$kind architecture mismatch."
        Assert-That ($entry[0].executable -match '^workers/out/x86_64-pc-windows-msvc/(cpu|cuda|vulkan)/worker-(cpu|cuda|vulkan)\.exe$') "$kind executable is outside the fixed worker path."
        if ($manifest.packageState -eq 'sealed') {
            Assert-That (@($entry[0].files).Count -gt 0) "Sealed $kind worker has no checksummed inventory."
            foreach ($file in @($entry[0].files)) {
                Assert-That ($file.path -match '^workers/out/x86_64-pc-windows-msvc/') "Worker inventory path escapes workers/out."
                Assert-That ($file.sha256 -match '^[0-9a-f]{64}$') "Worker inventory checksum is invalid."
                $absolute = Join-Path $repoRoot $file.path
                Assert-That (Test-Path -LiteralPath $absolute -PathType Leaf) "Listed worker file is missing: $($file.path)"
                Assert-That ((Get-Sha256 $absolute) -eq $file.sha256) "Worker checksum mismatch: $($file.path)"
            }
        } else {
            Assert-That (@($entry[0].files).Count -eq 0) "Unsealed $kind worker must not claim checksums."
        }
    }
    $fixturePath = Join-Path $repoRoot $manifest.fixture.audioPath
    $expectedPath = Join-Path $repoRoot $manifest.fixture.expectedAssetPath
    Assert-That ((Get-Sha256 $fixturePath) -eq $manifest.fixture.audioSha256) 'Fixture audio checksum mismatch.'
    Assert-That ((Get-Sha256 $expectedPath) -eq $manifest.fixture.expectedAssetSha256) 'Expected asset checksum mismatch.'
    $format = Get-WavFormat $fixturePath
    Assert-That ($format.Format -eq 1 -and $format.Channels -eq 1 -and $format.SampleRate -eq 16000 -and $format.BitsPerSample -eq 16) 'Fixture must be 16 kHz mono signed 16-bit PCM.'
    $expected = Get-Content -Raw -Encoding UTF8 -LiteralPath $expectedPath | ConvertFrom-Json
    Assert-That ($expected.fixtureId -eq $manifest.fixture.fixtureId) 'Fixture identity mismatch.'
    Assert-That ((Get-NormalizedTranscript $expected.spokenPhrase) -eq $expected.normalizedTranscript) 'Expected transcript does not follow the documented normalizer.'
    $transcriptBytes = [Text.Encoding]::UTF8.GetBytes($expected.normalizedTranscript)
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($transcriptBytes)).Replace('-', '').ToLowerInvariant()
    Assert-That ($hash -eq $manifest.fixture.expectedTranscriptSha256 -and $hash -eq $expected.expectedTranscriptSha256) 'Expected transcript checksum mismatch.'
    Assert-That (-not [string]::IsNullOrWhiteSpace($expected.source.contributor)) 'Fixture contributor is missing.'
    Assert-That ($expected.source.license -eq 'CC0-1.0' -and $expected.source.licenseUrl -eq 'https://creativecommons.org/publicdomain/zero/1.0/') 'Fixture redistribution license is incomplete.'
    Assert-That (-not [string]::IsNullOrWhiteSpace($expected.source.redistributionGrant)) 'Fixture redistribution grant is missing.'
}

Assert-Manifest
if ($Mode -eq 'ManifestOnly') {
    Assert-That ($manifest.packageState -eq 'build-required') 'ManifestOnly accepts only the reproducible build declaration, never a runtime inventory.'
    Write-Host 'PASS build declaration contract; no candidate is admitted by this mode.'
    exit 0
}

Assert-That (-not [string]::IsNullOrWhiteSpace($Candidate)) 'Candidate mode requires -Candidate cpu, cuda, or vulkan.'
Assert-That ([Environment]::Is64BitOperatingSystem) 'not present: this host is not x64 Windows.'
Assert-That (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf) "not verified: $Candidate has no generated sealed inventory."
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $runtimeManifestPath | ConvertFrom-Json
Assert-Manifest
Assert-That ($manifest.packageState -eq 'sealed') "not verified: $Candidate inventory is not sealed."
$worker = @($manifest.workers | Where-Object kind -eq $Candidate)[0]
Assert-That ($null -ne $worker) "not verified: requested $Candidate worker is absent from the sealed inventory."
$workerPath = Join-Path $repoRoot $worker.executable
Assert-That (Test-Path -LiteralPath $workerPath -PathType Leaf) "not verified: requested $Candidate worker is not packaged on this target PC."
Assert-That ($ModelPath -and (Test-Path -LiteralPath $ModelPath -PathType Leaf)) 'Candidate mode requires the verified pinned model path.'
$fixturePath = Join-Path $repoRoot $manifest.fixture.audioPath
$output = & $workerPath --model $ModelPath --language vi --input $fixturePath --json 2>$null
$json = $output | Out-String
Assert-That ([Text.Encoding]::UTF8.GetByteCount($json) -le 65536) 'Candidate output exceeded the protocol cap.'
try { $result = $json | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Candidate returned malformed JSON.' }
$properties = @($result.PSObject.Properties.Name | Sort-Object)
$expectedProperties = @('backend', 'workerBuild', 'modelRevision', 'elapsedMs', 'transcript', 'exitStatus', 'diagnostics' | Sort-Object)
Assert-That (($properties -join ',') -eq ($expectedProperties -join ',')) 'Candidate JSON has unknown or missing fields.'
Assert-That ($result.backend -eq $Candidate -and $result.workerBuild -eq $worker.buildId) 'Candidate identity mismatch.'
Assert-That ($result.modelRevision -eq $manifest.model.modelRevision -and $result.exitStatus -eq 0 -and $result.elapsedMs -ge 0) 'Candidate result has invalid revision, exit status, or timing.'
$expected = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot $manifest.fixture.expectedAssetPath) | ConvertFrom-Json
Assert-That (-not [string]::IsNullOrWhiteSpace($result.transcript)) 'Candidate transcript is empty.'
Assert-That ((Get-NormalizedTranscript $result.transcript) -eq $expected.normalizedTranscript) 'Candidate transcript mismatch; nonempty output is not a pass.'
Write-Host "PASS candidate $Candidate exact fixture self-test. Benchmark admission remains a separate step."

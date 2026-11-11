use std::{
    fs::{self, File},
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::{Component, Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const MAX_WORKER_OUTPUT_BYTES: usize = 64 * 1024;
const MAX_DIAGNOSTIC_BYTES: usize = 4 * 1024;
const WORKER_TIMEOUT: Duration = Duration::from_secs(30);
const LIVE_WORKER_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_LIVE_WAV_BYTES: usize = 4 * 1024 * 1024;
const RUNTIME_MANIFEST_PATH: &str = "workers/out/x86_64-pc-windows-msvc/manifest.json";
const APPROVED_WORKER_SOURCE: &str = "https://github.com/ggml-org/whisper.cpp.git";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum WorkerKind {
    Cpu,
    Cuda,
    Vulkan,
}

impl WorkerKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Cpu => "cpu",
            Self::Cuda => "cuda",
            Self::Vulkan => "vulkan",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerFile {
    pub path: String,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerManifestEntry {
    pub kind: WorkerKind,
    pub build_id: String,
    pub executable: String,
    pub files: Vec<WorkerFile>,
    pub source_revision: String,
    pub model_revision: String,
    pub architecture: String,
    pub backend: String,
    #[serde(default)]
    pub cmake_flags: Vec<String>,
    #[serde(default)]
    pub admission: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SelfTestFixture {
    pub fixture_id: String,
    pub audio_path: String,
    pub audio_sha256: String,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub expected_asset_path: String,
    pub expected_asset_sha256: String,
    pub expected_transcript_sha256: String,
    #[serde(default)]
    pub encoding: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReleaseTarget {
    pub architecture: String,
    pub supported_windows: Vec<String>,
    #[serde(default)]
    pub required_runtime: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerSource {
    pub repository: String,
    pub revision: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompatibleModel {
    pub model_id: String,
    pub model_revision: String,
    pub worker_compatibility: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerManifest {
    #[serde(default)]
    pub schema_version: u32,
    pub package_state: String,
    pub release_target: ReleaseTarget,
    #[serde(default)]
    pub source: Option<WorkerSource>,
    #[serde(default)]
    pub model: Option<CompatibleModel>,
    pub fixture: SelfTestFixture,
    pub workers: Vec<WorkerManifestEntry>,
}

impl WorkerManifest {
    pub fn from_json(json: &str) -> Result<Self, RunnerFailure> {
        serde_json::from_str(json).map_err(|_| RunnerFailure::Manifest)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedModel {
    pub path: PathBuf,
    pub revision: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostInfo {
    pub architecture: String,
    pub windows_supported: bool,
}

impl HostInfo {
    pub fn supported_x64() -> Self {
        Self {
            architecture: "x86_64".to_owned(),
            windows_supported: true,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerDiagnostics {
    pub missing_hardware: Option<String>,
    pub driver: Option<String>,
    pub memory_bytes: Option<u64>,
    pub failure_code: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerResult {
    pub backend: WorkerKind,
    pub worker_build: String,
    pub model_revision: String,
    pub elapsed_ms: u64,
    pub transcript: String,
    pub exit_status: i32,
    pub diagnostics: WorkerDiagnostics,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RunnerFailure {
    Manifest,
    WorkerNotSealed,
    WorkerNotPresent(WorkerKind),
    HostArchitecture,
    UnsupportedWindows,
    ModelRevision,
    ModelPath,
    InventoryChecksum,
    FixtureChecksum,
    FixtureFormat,
    ExpectedAsset,
    ExpectedTranscriptChecksum,
    Timeout,
    OutputTooLarge,
    StderrTooLarge,
    NonZeroExit(i32),
    Protocol,
    WorkerIdentity,
    InvalidTiming,
    EmptyTranscript,
    TranscriptMismatch {
        expected_sha256: String,
        actual_sha256: String,
        backend: WorkerKind,
        worker_build: String,
    },
    Io,
}

impl std::fmt::Display for RunnerFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Manifest => "worker manifest is invalid",
            Self::WorkerNotSealed => "worker inventory is not sealed",
            Self::WorkerNotPresent(_) => "worker is not present",
            Self::HostArchitecture => "host architecture is unsupported",
            Self::UnsupportedWindows => "Windows version is unsupported",
            Self::ModelRevision => "verified model revision is incompatible",
            Self::ModelPath => "verified model path is unavailable",
            Self::InventoryChecksum => "worker inventory checksum mismatch",
            Self::FixtureChecksum => "self-test fixture checksum mismatch",
            Self::FixtureFormat => "self-test fixture format is invalid",
            Self::ExpectedAsset => "self-test expectation metadata is invalid",
            Self::ExpectedTranscriptChecksum => "expected transcript checksum mismatch",
            Self::Timeout => "worker timed out",
            Self::OutputTooLarge => "worker stdout exceeded the cap",
            Self::StderrTooLarge => "worker stderr exceeded the cap",
            Self::NonZeroExit(_) => "worker exited unsuccessfully",
            Self::Protocol => "worker protocol is invalid",
            Self::WorkerIdentity => "worker identity does not match the manifest",
            Self::InvalidTiming => "worker timing is invalid",
            Self::EmptyTranscript => "worker transcript is empty",
            Self::TranscriptMismatch { .. } => "worker transcript did not match the fixture",
            Self::Io => "worker process or artifact could not be read",
        })
    }
}

impl std::error::Error for RunnerFailure {}

#[derive(Clone, Debug)]
pub struct InferenceRunner {
    root: PathBuf,
    manifest: WorkerManifest,
    host: HostInfo,
}

impl InferenceRunner {
    pub fn new(root: PathBuf, manifest: WorkerManifest, host: HostInfo) -> Self {
        Self {
            root,
            manifest,
            host,
        }
    }

    pub fn from_runtime_inventory(root: PathBuf, host: HostInfo) -> Result<Self, RunnerFailure> {
        let executable_root = std::env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(Path::to_path_buf));
        let root = [
            root.clone(),
            root.join("_up_"),
            root.parent()
                .map(|parent| parent.join("_up_"))
                .unwrap_or_default(),
            executable_root
                .map(|path| path.join("_up_"))
                .unwrap_or_default(),
        ]
        .into_iter()
        .find(|candidate| candidate.join(RUNTIME_MANIFEST_PATH).is_file())
        .ok_or(RunnerFailure::WorkerNotSealed)?;
        let inventory = root.join(RUNTIME_MANIFEST_PATH);
        if !inventory.is_file() {
            return Err(RunnerFailure::WorkerNotSealed);
        }
        let manifest = WorkerManifest::from_json(
            &fs::read_to_string(inventory).map_err(|_| RunnerFailure::WorkerNotSealed)?,
        )?;
        if manifest.package_state != "sealed" {
            return Err(RunnerFailure::WorkerNotSealed);
        }
        Ok(Self::new(root, manifest, host))
    }

    pub fn preflight(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
    ) -> Result<WorkerManifestEntry, RunnerFailure> {
        if !self.host.windows_supported {
            return Err(RunnerFailure::UnsupportedWindows);
        }
        if self.host.architecture != "x86_64"
            || self.manifest.release_target.architecture != "x86_64"
        {
            return Err(RunnerFailure::HostArchitecture);
        }
        if self.manifest.package_state != "sealed" {
            return Err(RunnerFailure::WorkerNotSealed);
        }
        self.validate_manifest_identities()?;
        if !model.path.is_file() {
            return Err(RunnerFailure::ModelPath);
        }
        if self
            .manifest
            .model
            .as_ref()
            .expect("manifest model was validated")
            .model_revision
            != model.revision
        {
            return Err(RunnerFailure::ModelRevision);
        }
        let worker = self
            .manifest
            .workers
            .iter()
            .find(|entry| entry.kind == kind)
            .cloned()
            .ok_or(RunnerFailure::WorkerNotPresent(kind))?;
        if worker.backend != kind.as_str()
            || worker.architecture != "x86_64"
            || worker.model_revision != model.revision
            || worker.source_revision
                != self
                    .manifest
                    .source
                    .as_ref()
                    .expect("manifest source was validated")
                    .revision
            || worker.build_id.is_empty()
        {
            return Err(RunnerFailure::ModelRevision);
        }
        let worker_path = self.fixed_path(&worker.executable, kind)?;
        if !worker_path.is_file() || worker.files.is_empty() {
            return Err(RunnerFailure::WorkerNotPresent(kind));
        }
        let mut executable_listed = false;
        for file in &worker.files {
            let path = self.fixed_path(&file.path, kind)?;
            if !path.is_file() || !valid_sha256(&file.sha256) || sha256_file(&path)? != file.sha256
            {
                return Err(RunnerFailure::InventoryChecksum);
            }
            executable_listed |= path == worker_path;
        }
        if !executable_listed {
            return Err(RunnerFailure::InventoryChecksum);
        }
        Ok(worker)
    }

    pub fn run(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
    ) -> Result<WorkerResult, RunnerFailure> {
        let worker = self.preflight(kind, model)?;
        self.verify_fixture()?;
        let fixture = self.safe_path(&self.manifest.fixture.audio_path)?;
        let (output, exit) = self.execute(&worker, kind, model, &fixture)?;
        self.self_test(kind, model, &output, exit)
    }

    /// Executes a host-created benchmark WAV without relaxing worker admission or protocol checks.
    pub fn run_input(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
        input: &Path,
        transaction_dir: &Path,
    ) -> Result<WorkerResult, RunnerFailure> {
        let worker = self.preflight(kind, model)?;
        self.validate_transaction_input(input, transaction_dir)?;
        let (output, exit) = self.execute(&worker, kind, model, input)?;
        self.parse_result(kind, &output, exit)
    }

    /// Starts a sealed worker once and keeps its model loaded for live subtitle windows.
    /// Benchmark calls continue to use [`Self::run_input`] with the stricter one-shot timeout.
    pub fn start_live_worker(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
    ) -> Result<PersistentLiveWorker, RunnerFailure> {
        let worker = self.preflight(kind, model)?;
        let executable = self.fixed_path(&worker.executable, kind)?;
        let mut child = Command::new(executable)
            .arg("--model")
            .arg(&model.path)
            .arg("--language")
            .arg("vi")
            .arg("--serve")
            .arg("--json")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| RunnerFailure::Io)?;
        let stdin = child.stdin.take().ok_or(RunnerFailure::Io)?;
        let stdout = child.stdout.take().ok_or(RunnerFailure::Io)?;
        let mut live = PersistentLiveWorker {
            child,
            stdin: BufWriter::new(stdin),
            replies: read_json_lines(stdout),
            worker,
            kind,
        };
        if let Err(error) = live.validate_ready() {
            live.terminate();
            return Err(error);
        }
        Ok(live)
    }

    pub fn installed_workers(&self) -> Vec<WorkerKind> {
        self.manifest
            .workers
            .iter()
            .map(|worker| worker.kind)
            .collect()
    }

    pub fn fixture_evidence(&self) -> crate::inference::benchmark::FixtureEvidence {
        crate::inference::benchmark::FixtureEvidence {
            fixture_id: self.manifest.fixture.fixture_id.clone(),
            audio_sha256: self.manifest.fixture.audio_sha256.clone(),
            expected_transcript_sha256: self.manifest.fixture.expected_transcript_sha256.clone(),
            passed_at: "native-fixture-gate".to_owned(),
        }
    }

    fn execute(
        &self,
        worker: &WorkerManifestEntry,
        kind: WorkerKind,
        model: &VerifiedModel,
        input: &Path,
    ) -> Result<(Vec<u8>, i32), RunnerFailure> {
        let executable = self.fixed_path(&worker.executable, kind)?;
        let mut child = Command::new(executable)
            .arg("--model")
            .arg(&model.path)
            .arg("--language")
            .arg("vi")
            .arg("--input")
            .arg(input)
            .arg("--json")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| RunnerFailure::Io)?;
        let stdout = child.stdout.take().ok_or(RunnerFailure::Io)?;
        let stderr = child.stderr.take().ok_or(RunnerFailure::Io)?;
        let stdout_reader = read_capped(
            stdout,
            MAX_WORKER_OUTPUT_BYTES,
            RunnerFailure::OutputTooLarge,
        );
        let stderr_reader =
            read_capped(stderr, MAX_DIAGNOSTIC_BYTES, RunnerFailure::StderrTooLarge);
        let started = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|_| RunnerFailure::Io)? {
                break status;
            }
            if started.elapsed() >= WORKER_TIMEOUT {
                let _ = child.kill();
                let _ = child.wait();
                return Err(RunnerFailure::Timeout);
            }
            thread::sleep(Duration::from_millis(10));
        };
        let output = stdout_reader.recv().map_err(|_| RunnerFailure::Io)??;
        let diagnostic = stderr_reader.recv().map_err(|_| RunnerFailure::Io)??;
        if diagnostic.len() > MAX_DIAGNOSTIC_BYTES {
            return Err(RunnerFailure::StderrTooLarge);
        }
        let exit = status.code().unwrap_or(-1);
        Ok((output, exit))
    }

    pub fn parse_result(
        &self,
        kind: WorkerKind,
        output: &[u8],
        exit_status: i32,
    ) -> Result<WorkerResult, RunnerFailure> {
        let worker = self
            .manifest
            .workers
            .iter()
            .find(|entry| entry.kind == kind)
            .ok_or(RunnerFailure::WorkerNotPresent(kind))?;
        parse_worker_result(worker, kind, output, exit_status, WORKER_TIMEOUT, true)
    }

    pub fn self_test(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
        output: &[u8],
        exit_status: i32,
    ) -> Result<WorkerResult, RunnerFailure> {
        self.preflight(kind, model)?;
        let expected = self.verify_fixture()?;
        let result = self.parse_result(kind, output, exit_status)?;
        let normalized = normalize_transcript(&result.transcript);
        if normalized.is_empty() {
            return Err(RunnerFailure::EmptyTranscript);
        }
        let actual_sha256 = sha256_bytes(normalized.as_bytes());
        if actual_sha256 != expected.transcript_sha256 {
            return Err(RunnerFailure::TranscriptMismatch {
                expected_sha256: expected.transcript_sha256,
                actual_sha256,
                backend: result.backend,
                worker_build: result.worker_build,
            });
        }
        Ok(result)
    }

    fn verify_fixture(&self) -> Result<ExpectedFixture, RunnerFailure> {
        let fixture = &self.manifest.fixture;
        let audio = self.safe_path(&fixture.audio_path)?;
        let expected = self.safe_path(&fixture.expected_asset_path)?;
        if sha256_file(&audio)? != fixture.audio_sha256
            || sha256_file(&expected)? != fixture.expected_asset_sha256
        {
            return Err(RunnerFailure::FixtureChecksum);
        }
        verify_pcm_wav(&audio, fixture.sample_rate_hz, fixture.channels)?;
        let expected: ExpectedAsset =
            serde_json::from_slice(&fs::read(expected).map_err(|_| RunnerFailure::Io)?)
                .map_err(|_| RunnerFailure::ExpectedAsset)?;
        if expected.fixture_id != fixture.fixture_id
            || expected.language != "vi"
            || expected.spoken_phrase.trim().is_empty()
            || expected.normalizer
                != "trim, lowercase, remove terminal ASCII sentence punctuation, collapse internal Unicode whitespace to one ASCII space"
            || expected.source.contributor.trim().is_empty()
            || expected.source.name.trim().is_empty()
            || expected.source.source_url.trim().is_empty()
            || expected.source.original_filename.trim().is_empty()
            || expected.source.recording_date.trim().is_empty()
            || expected.source.license != "CC0-1.0"
            || expected.source.license_url != "https://creativecommons.org/publicdomain/zero/1.0/"
            || expected.source.redistribution_grant.trim().is_empty()
            || expected.transformation.tool.trim().is_empty()
            || expected.transformation.command.trim().is_empty()
            || expected.transformation.performed_on.trim().is_empty()
        {
            return Err(RunnerFailure::ExpectedAsset);
        }
        let normalized = normalize_transcript(&expected.normalized_transcript);
        if normalized.is_empty()
            || normalized != expected.normalized_transcript
            || sha256_bytes(normalized.as_bytes()) != fixture.expected_transcript_sha256
            || expected.expected_transcript_sha256 != fixture.expected_transcript_sha256
        {
            return Err(RunnerFailure::ExpectedTranscriptChecksum);
        }
        Ok(ExpectedFixture {
            transcript_sha256: fixture.expected_transcript_sha256.clone(),
        })
    }

    fn fixed_path(&self, relative: &str, kind: WorkerKind) -> Result<PathBuf, RunnerFailure> {
        let expected_prefix = format!("workers/out/x86_64-pc-windows-msvc/{}/", kind.as_str());
        if !relative.replace('\\', "/").starts_with(&expected_prefix) {
            return Err(RunnerFailure::Manifest);
        }
        self.safe_path(relative)
    }

    fn validate_transaction_input(
        &self,
        input: &Path,
        transaction_dir: &Path,
    ) -> Result<(), RunnerFailure> {
        let directory = fs::canonicalize(transaction_dir).map_err(|_| RunnerFailure::Io)?;
        let input = fs::canonicalize(input).map_err(|_| RunnerFailure::Io)?;
        if !input.is_file() || input.parent() != Some(directory.as_path()) {
            return Err(RunnerFailure::ModelPath);
        }
        verify_pcm_wav(&input, 16_000, 1)
    }

    fn validate_manifest_identities(&self) -> Result<(), RunnerFailure> {
        let source = self
            .manifest
            .source
            .as_ref()
            .ok_or(RunnerFailure::Manifest)?;
        let model = self
            .manifest
            .model
            .as_ref()
            .ok_or(RunnerFailure::Manifest)?;
        if self.manifest.schema_version != 1
            || source.repository != APPROVED_WORKER_SOURCE
            || !valid_revision(&source.revision)
            || model.model_id.is_empty()
            || model.model_revision.is_empty()
            || model.worker_compatibility != format!("ggml-org/whisper.cpp@{}", source.revision)
        {
            return Err(RunnerFailure::Manifest);
        }
        Ok(())
    }

    fn safe_path(&self, relative: &str) -> Result<PathBuf, RunnerFailure> {
        let path = Path::new(relative);
        if path.is_absolute()
            || path.components().any(|part| {
                matches!(
                    part,
                    Component::ParentDir | Component::RootDir | Component::Prefix(_)
                )
            })
        {
            return Err(RunnerFailure::Manifest);
        }
        Ok(self.root.join(path))
    }
}

/// A single sealed worker process that keeps the Whisper model in memory between windows.
pub struct PersistentLiveWorker {
    child: Child,
    stdin: BufWriter<ChildStdin>,
    replies: mpsc::Receiver<Result<Vec<u8>, RunnerFailure>>,
    worker: WorkerManifestEntry,
    kind: WorkerKind,
}

impl PersistentLiveWorker {
    pub fn transcribe_wav(&mut self, wav: &[u8]) -> Result<WorkerResult, RunnerFailure> {
        if wav.is_empty() || wav.len() > MAX_LIVE_WAV_BYTES {
            return Err(RunnerFailure::FixtureFormat);
        }
        let length = u32::try_from(wav.len()).map_err(|_| RunnerFailure::FixtureFormat)?;
        if self
            .stdin
            .write_all(&length.to_le_bytes())
            .and_then(|_| self.stdin.write_all(wav))
            .and_then(|_| self.stdin.flush())
            .is_err()
        {
            self.terminate();
            return Err(RunnerFailure::Io);
        }

        let response = match self.next_reply(LIVE_WORKER_TIMEOUT) {
            Ok(response) => response,
            Err(error) => {
                self.terminate();
                return Err(error);
            }
        };
        let result = parse_worker_result(
            &self.worker,
            self.kind,
            &response,
            0,
            LIVE_WORKER_TIMEOUT,
            false,
        );
        if result.is_err() {
            self.terminate();
        }
        result
    }

    fn validate_ready(&mut self) -> Result<(), RunnerFailure> {
        let response = self.next_reply(LIVE_WORKER_TIMEOUT)?;
        let ready: RawWorkerReady =
            serde_json::from_slice(&response).map_err(|_| RunnerFailure::Protocol)?;
        if ready.event != "ready"
            || ready.protocol_version != 1
            || ready.max_frame_bytes != MAX_LIVE_WAV_BYTES as u32
            || ready.backend != self.kind
            || ready.worker_build != self.worker.build_id
            || ready.model_revision != self.worker.model_revision
        {
            return Err(RunnerFailure::WorkerIdentity);
        }
        Ok(())
    }

    fn next_reply(&mut self, timeout: Duration) -> Result<Vec<u8>, RunnerFailure> {
        match self.replies.recv_timeout(timeout) {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(error)) => Err(error),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.terminate();
                Err(RunnerFailure::Timeout)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(RunnerFailure::Io),
        }
    }

    fn terminate(&mut self) {
        let _ = self.stdin.write_all(&0_u32.to_le_bytes());
        let _ = self.stdin.flush();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

impl Drop for PersistentLiveWorker {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn parse_worker_result(
    worker: &WorkerManifestEntry,
    kind: WorkerKind,
    output: &[u8],
    exit_status: i32,
    timeout: Duration,
    require_transcript: bool,
) -> Result<WorkerResult, RunnerFailure> {
    if exit_status != 0 {
        return Err(RunnerFailure::NonZeroExit(exit_status));
    }
    if output.len() > MAX_WORKER_OUTPUT_BYTES {
        return Err(RunnerFailure::OutputTooLarge);
    }
    let raw: RawWorkerResult =
        serde_json::from_slice(output).map_err(|_| RunnerFailure::Protocol)?;
    if raw.backend != kind || raw.exit_status != 0 || raw.elapsed_ms > timeout.as_millis() as u64 {
        return Err(RunnerFailure::InvalidTiming);
    }
    if raw.worker_build != worker.build_id || raw.model_revision != worker.model_revision {
        return Err(RunnerFailure::WorkerIdentity);
    }
    if require_transcript && raw.transcript.trim().is_empty() {
        return Err(RunnerFailure::EmptyTranscript);
    }
    if raw.diagnostics.encoded_len() > MAX_DIAGNOSTIC_BYTES {
        return Err(RunnerFailure::Protocol);
    }
    Ok(WorkerResult {
        backend: raw.backend,
        worker_build: raw.worker_build,
        model_revision: raw.model_revision,
        elapsed_ms: raw.elapsed_ms,
        transcript: raw.transcript,
        exit_status: raw.exit_status,
        diagnostics: raw.diagnostics.into(),
    })
}

fn read_json_lines<R: Read + Send + 'static>(
    reader: R,
) -> mpsc::Receiver<Result<Vec<u8>, RunnerFailure>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        loop {
            let mut line = Vec::new();
            match read_capped_line(&mut reader, &mut line) {
                Ok(false) => break,
                Ok(true) => {
                    if sender.send(Ok(line)).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = sender.send(Err(error));
                    break;
                }
            }
        }
    });
    receiver
}

fn read_capped_line<R: BufRead>(reader: &mut R, line: &mut Vec<u8>) -> Result<bool, RunnerFailure> {
    loop {
        let buffer = reader.fill_buf().map_err(|_| RunnerFailure::Io)?;
        if buffer.is_empty() {
            return Ok(!line.is_empty());
        }
        let length = buffer
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(buffer.len(), |position| position + 1);
        if line.len().saturating_add(length) > MAX_WORKER_OUTPUT_BYTES {
            return Err(RunnerFailure::OutputTooLarge);
        }
        line.extend_from_slice(&buffer[..length]);
        let completed = length < buffer.len() || buffer[length - 1] == b'\n';
        reader.consume(length);
        if completed {
            return Ok(true);
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawWorkerResult {
    backend: WorkerKind,
    worker_build: String,
    model_revision: String,
    elapsed_ms: u64,
    transcript: String,
    exit_status: i32,
    diagnostics: RawDiagnostics,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawWorkerReady {
    event: String,
    protocol_version: u32,
    max_frame_bytes: u32,
    backend: WorkerKind,
    worker_build: String,
    model_revision: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawDiagnostics {
    #[serde(default)]
    missing_hardware: Option<String>,
    #[serde(default)]
    driver: Option<String>,
    #[serde(default)]
    memory_bytes: Option<u64>,
    #[serde(default)]
    failure_code: Option<String>,
}

impl RawDiagnostics {
    fn encoded_len(&self) -> usize {
        self.missing_hardware.as_ref().map_or(0, String::len)
            + self.driver.as_ref().map_or(0, String::len)
            + self.failure_code.as_ref().map_or(0, String::len)
    }
}

impl From<RawDiagnostics> for WorkerDiagnostics {
    fn from(value: RawDiagnostics) -> Self {
        Self {
            missing_hardware: value.missing_hardware,
            driver: value.driver,
            memory_bytes: value.memory_bytes,
            failure_code: value.failure_code,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExpectedAsset {
    fixture_id: String,
    language: String,
    spoken_phrase: String,
    normalized_transcript: String,
    normalizer: String,
    expected_transcript_sha256: String,
    source: ExpectedSource,
    transformation: ExpectedTransformation,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExpectedSource {
    name: String,
    source_url: String,
    original_filename: String,
    contributor: String,
    recording_date: String,
    license: String,
    license_url: String,
    redistribution_grant: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExpectedTransformation {
    tool: String,
    command: String,
    performed_on: String,
    #[serde(rename = "attributionRequired")]
    _attribution_required: bool,
}

struct ExpectedFixture {
    transcript_sha256: String,
}

fn read_capped<R: Read + Send + 'static>(
    mut reader: R,
    max: usize,
    overflow: RunnerFailure,
) -> mpsc::Receiver<Result<Vec<u8>, RunnerFailure>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut output = Vec::new();
        let mut buffer = [0_u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    if output.len().saturating_add(read) > max {
                        let _ = sender.send(Err(overflow));
                        return;
                    }
                    output.extend_from_slice(&buffer[..read]);
                }
                Err(_) => {
                    let _ = sender.send(Err(RunnerFailure::Io));
                    return;
                }
            }
        }
        let _ = sender.send(Ok(output));
    });
    receiver
}

fn verify_pcm_wav(path: &Path, sample_rate_hz: u32, channels: u16) -> Result<(), RunnerFailure> {
    let bytes = fs::read(path).map_err(|_| RunnerFailure::Io)?;
    if bytes.len() < 44
        || &bytes[0..4] != b"RIFF"
        || &bytes[8..12] != b"WAVE"
        || &bytes[12..16] != b"fmt "
        || u16::from_le_bytes([bytes[20], bytes[21]]) != 1
        || u16::from_le_bytes([bytes[22], bytes[23]]) != channels
        || u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]) != sample_rate_hz
        || u16::from_le_bytes([bytes[34], bytes[35]]) != 16
    {
        return Err(RunnerFailure::FixtureFormat);
    }
    Ok(())
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_revision(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn sha256_file(path: &Path) -> Result<String, RunnerFailure> {
    let mut file = File::open(path).map_err(|_| RunnerFailure::Io)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|_| RunnerFailure::Io)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn sha256_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub fn normalize_transcript(value: &str) -> String {
    value
        .trim()
        .trim_end_matches(|character| matches!(character, '.' | ',' | '!' | '?' | ';' | ':'))
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

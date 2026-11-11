use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use super::{
    benchmark::{
        select_profile_with_fixture, BenchmarkCandidate, BenchmarkMeasurement, BenchmarkReport,
        FixtureEvidence, InferenceProfile,
    },
    runner::{
        InferenceRunner, PersistentLiveWorker, RunnerFailure, VerifiedModel, WorkerKind,
        WorkerResult,
    },
};

const SAMPLE_RATE_HZ: u64 = 16_000;
const MAX_SAMPLES: usize = SAMPLE_RATE_HZ as usize * 20;

pub trait BenchmarkRunner {
    fn fixture(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
    ) -> Result<WorkerResult, RunnerFailure>;
    fn input(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
        input: &Path,
        transaction_dir: &Path,
    ) -> Result<WorkerResult, RunnerFailure>;
    fn installed_workers(&self) -> Vec<WorkerKind>;
    fn fixture_evidence(&self) -> FixtureEvidence {
        FixtureEvidence::default()
    }
}

impl BenchmarkRunner for InferenceRunner {
    fn fixture(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
    ) -> Result<WorkerResult, RunnerFailure> {
        self.run(kind, model)
    }

    fn input(
        &self,
        kind: WorkerKind,
        model: &VerifiedModel,
        input: &Path,
        transaction_dir: &Path,
    ) -> Result<WorkerResult, RunnerFailure> {
        self.run_input(kind, model, input, transaction_dir)
    }

    fn installed_workers(&self) -> Vec<WorkerKind> {
        self.installed_workers()
    }

    fn fixture_evidence(&self) -> FixtureEvidence {
        self.fixture_evidence()
    }
}

pub struct BenchmarkTransaction<R> {
    runner: R,
    model: VerifiedModel,
}

impl<R: BenchmarkRunner> BenchmarkTransaction<R> {
    pub fn new(runner: R, model: VerifiedModel) -> Self {
        Self { runner, model }
    }

    pub fn run(&self, samples: Vec<i16>) -> Result<BenchmarkReport, BenchmarkTransactionError> {
        let sample = TemporarySample::create(samples)?;
        let duration_ms = sample.samples.len() as u64 * 1_000 / SAMPLE_RATE_HZ;
        let workers = self.runner.installed_workers();
        let candidates: Vec<_> = [WorkerKind::Cpu, WorkerKind::Cuda, WorkerKind::Vulkan]
            .into_iter()
            .map(|kind| self.run_candidate(kind, workers.contains(&kind), &sample, duration_ms))
            .collect();
        let cpu_fixture_passed = candidates
            .iter()
            .find(|candidate| candidate.worker == WorkerKind::Cpu)
            .is_some_and(|candidate| candidate.fixture_passed);
        let mut report = select_profile_with_fixture(
            "Đây là mẫu kiểm tra nhận diện tiếng Việt.",
            candidates,
            self.runner.fixture_evidence(),
        );
        if !cpu_fixture_passed {
            report.profile = None;
            report.fallback_reason =
                Some("CPU fixture failed, so no accelerated profile can be selected.".to_owned());
        }
        Ok(report)
    }

    /// Runs the fixed Vietnamese one-shot through the profile selected by the native benchmark.
    /// The result is intentionally dropped: setup retains only completion/failure, never text.
    pub fn run_one_shot(
        &self,
        profile: &InferenceProfile,
        samples: Vec<i16>,
    ) -> Result<(), BenchmarkTransactionError> {
        if profile.model_revision != self.model.revision {
            return Err(BenchmarkTransactionError::ProfileMismatch);
        }
        let sample = TemporarySample::create(samples)?;
        self.runner
            .input(profile.worker, &self.model, &sample.wav, &sample.directory)
            .map(|_| ())
            .map_err(|_| BenchmarkTransactionError::Inference)
    }

    fn run_candidate(
        &self,
        kind: WorkerKind,
        installed: bool,
        sample: &TemporarySample,
        duration_ms: u64,
    ) -> BenchmarkCandidate {
        if !installed {
            return unavailable(kind, "worker is not present in the sealed inventory");
        }
        let fixture = match self.runner.fixture(kind, &self.model) {
            Ok(result) => result,
            Err(error) => return failed_fixture(kind, error),
        };
        if let Err(error) = self
            .runner
            .input(kind, &self.model, &sample.wav, &sample.directory)
        {
            return failed_measurement(kind, fixture, error);
        }
        let mut elapsed = Vec::with_capacity(3);
        let mut final_result = fixture.clone();
        for _ in 0..3 {
            match self
                .runner
                .input(kind, &self.model, &sample.wav, &sample.directory)
            {
                Ok(result) => {
                    elapsed.push(result.elapsed_ms);
                    final_result = result;
                }
                Err(error) => return failed_measurement(kind, fixture, error),
            }
        }
        elapsed.sort_unstable();
        let p95_ms = elapsed[elapsed.len() * 95_usize.div_ceil(100) - 1];
        let rtf = p95_ms as f32 / duration_ms as f32;
        let hardware_fingerprint = fingerprint(kind, &final_result);
        BenchmarkCandidate {
            worker: kind,
            worker_build: final_result.worker_build,
            model_revision: final_result.model_revision,
            hardware_fingerprint,
            fixture_passed: true,
            measurement: Some(BenchmarkMeasurement {
                transcript: final_result.transcript,
                cold_load_ms: fixture.elapsed_ms,
                warm_rtf: rtf,
                warm_p95_ms: p95_ms,
                memory_bytes: final_result.diagnostics.memory_bytes,
                driver: final_result.diagnostics.driver,
            }),
            unavailable_reason: None,
        }
    }
}

pub fn transcribe_live_window(
    runner: InferenceRunner,
    model: VerifiedModel,
    profile: &InferenceProfile,
    samples: Vec<i16>,
) -> Result<String, BenchmarkTransactionError> {
    if profile.model_revision != model.revision {
        return Err(BenchmarkTransactionError::ProfileMismatch);
    }
    let sample = TemporarySample::create(samples)?;
    runner
        .run_input(profile.worker, &model, &sample.wav, &sample.directory)
        .map(|result| result.transcript.trim().to_owned())
        .map_err(|_| BenchmarkTransactionError::Inference)
}

/// Sends a fresh host-created WAV to a worker that already holds the Whisper model in memory.
pub fn transcribe_live_window_persistent(
    worker: &mut PersistentLiveWorker,
    model: &VerifiedModel,
    profile: &InferenceProfile,
    mut samples: Vec<i16>,
) -> Result<String, BenchmarkTransactionError> {
    if profile.model_revision != model.revision {
        samples.fill(0);
        return Err(BenchmarkTransactionError::ProfileMismatch);
    }

    if samples.is_empty() || samples.len() > MAX_SAMPLES {
        samples.fill(0);
        return Err(BenchmarkTransactionError::InvalidSample);
    }

    let mut wav = wav_bytes(&samples);
    samples.fill(0);
    let result = worker
        .transcribe_wav(&wav)
        .map(|result| result.transcript.trim().to_owned())
        .map_err(|_| BenchmarkTransactionError::Inference);
    wav.fill(0);
    result
}

fn unavailable(kind: WorkerKind, reason: &str) -> BenchmarkCandidate {
    BenchmarkCandidate {
        worker: kind,
        worker_build: "unavailable".to_owned(),
        model_revision: "unavailable".to_owned(),
        hardware_fingerprint: "unavailable".to_owned(),
        fixture_passed: true,
        measurement: None,
        unavailable_reason: Some(reason.to_owned()),
    }
}

fn failed_fixture(kind: WorkerKind, error: RunnerFailure) -> BenchmarkCandidate {
    BenchmarkCandidate {
        fixture_passed: false,
        unavailable_reason: Some(error.to_string()),
        ..unavailable(kind, "fixture execution failed")
    }
}

fn failed_measurement(
    kind: WorkerKind,
    fixture: WorkerResult,
    error: RunnerFailure,
) -> BenchmarkCandidate {
    let hardware_fingerprint = fingerprint(kind, &fixture);
    BenchmarkCandidate {
        worker: kind,
        worker_build: fixture.worker_build,
        model_revision: fixture.model_revision,
        hardware_fingerprint,
        fixture_passed: true,
        measurement: None,
        unavailable_reason: Some(error.to_string()),
    }
}

fn fingerprint(kind: WorkerKind, result: &WorkerResult) -> String {
    format!(
        "{:?}:{}:{}",
        kind,
        result.diagnostics.driver.as_deref().unwrap_or("unknown"),
        result.diagnostics.memory_bytes.unwrap_or(0)
    )
}

#[derive(Debug)]
pub enum BenchmarkTransactionError {
    InvalidSample,
    Storage,
    ProfileMismatch,
    Inference,
}

impl std::fmt::Display for BenchmarkTransactionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::InvalidSample => "benchmark sample is invalid",
            Self::Storage => "benchmark temporary storage is unavailable",
            Self::ProfileMismatch => "selected profile does not match the verified model",
            Self::Inference => "selected profile could not complete the local one-shot",
        })
    }
}

impl std::error::Error for BenchmarkTransactionError {}

struct TemporarySample {
    samples: Vec<i16>,
    directory: PathBuf,
    wav: PathBuf,
}

impl TemporarySample {
    fn create(mut samples: Vec<i16>) -> Result<Self, BenchmarkTransactionError> {
        if samples.is_empty() || samples.len() > MAX_SAMPLES {
            samples.fill(0);
            return Err(BenchmarkTransactionError::InvalidSample);
        }
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| BenchmarkTransactionError::Storage)?
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "live-subtitle-benchmark-{}-{nonce}",
            std::process::id()
        ));
        if fs::create_dir(&directory).is_err() {
            samples.fill(0);
            return Err(BenchmarkTransactionError::Storage);
        }
        let wav = directory.join("sample.wav");
        if write_wav(&wav, &samples).is_err() {
            samples.fill(0);
            let _ = fs::remove_dir_all(&directory);
            return Err(BenchmarkTransactionError::Storage);
        }
        Ok(Self {
            samples,
            directory,
            wav,
        })
    }
}

impl Drop for TemporarySample {
    fn drop(&mut self) {
        self.samples.fill(0);
        let _ = fs::remove_file(&self.wav);
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn write_wav(path: &Path, samples: &[i16]) -> std::io::Result<()> {
    let bytes = wav_bytes(samples);
    let mut file = fs::File::create(path)?;
    file.write_all(&bytes)?;
    file.sync_all()
}

fn wav_bytes(samples: &[i16]) -> Vec<u8> {
    let payload_bytes = (samples.len() as u32) * 2;
    let mut wav = Vec::with_capacity(44 + payload_bytes as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + payload_bytes).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE_HZ as u32).to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE_HZ as u32 * 2).to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&payload_bytes.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

#[cfg(test)]
mod tests {
    use super::wav_bytes;

    #[test]
    fn encodes_live_pcm_as_a_valid_16khz_mono_wav() {
        let wav = wav_bytes(&[0x1234, -2]);

        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(u16::from_le_bytes([wav[20], wav[21]]), 1);
        assert_eq!(u16::from_le_bytes([wav[22], wav[23]]), 1);
        assert_eq!(
            u32::from_le_bytes([wav[24], wav[25], wav[26], wav[27]]),
            16_000
        );
        assert_eq!(&wav[44..], &[0x34, 0x12, 0xfe, 0xff]);
    }
}

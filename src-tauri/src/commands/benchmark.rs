use serde::Serialize;

use tauri::{AppHandle, Manager, State};

use crate::audio::{
    capture::{BenchmarkSampleMetadata, CaptureController},
    source::AudioCommandError,
};
use crate::inference::benchmark::{
    BENCHMARK_PROMPT, MAX_WARM_P95_MS, MAX_WARM_RTF, MIN_CORRECTNESS,
};
use crate::inference::{
    benchmark::BenchmarkReport,
    download, manifest,
    runner::{HostInfo, InferenceRunner, VerifiedModel, WorkerKind},
    transaction::BenchmarkTransaction,
};
use crate::setup::state::SetupController;
use crate::{
    commands::verification::VerificationTransport,
    verification::{digest_for_native, ReceiptCommand, ReceiptOutcome},
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkPolicy {
    pub prompt: &'static str,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub maximum_sample_seconds: u16,
    pub minimum_correctness: f32,
    pub maximum_warm_rtf: f32,
    pub maximum_warm_p95_ms: u64,
    pub temporary_source_only: bool,
}

/// The UI uses this policy before asking the native capture path to retain a bounded temporary
/// sample. It intentionally exposes no captured PCM or recognized text over diagnostics IPC.
#[tauri::command]
pub fn benchmark_policy() -> BenchmarkPolicy {
    BenchmarkPolicy {
        prompt: BENCHMARK_PROMPT,
        sample_rate_hz: 16_000,
        channels: 1,
        maximum_sample_seconds: 20,
        minimum_correctness: MIN_CORRECTNESS,
        maximum_warm_rtf: MAX_WARM_RTF,
        maximum_warm_p95_ms: MAX_WARM_P95_MS,
        temporary_source_only: true,
    }
}

#[tauri::command]
pub fn start_benchmark_recording(
    app: AppHandle,
    capture: State<CaptureController>,
) -> Result<(), AudioCommandError> {
    capture.start_benchmark_sample(app)
}

#[tauri::command]
pub fn finish_benchmark_recording(
    capture: State<CaptureController>,
) -> Result<BenchmarkSampleMetadata, AudioCommandError> {
    capture.finish_benchmark_sample()
}

#[tauri::command]
pub fn discard_benchmark_recording(capture: State<CaptureController>) {
    capture.discard_benchmark_sample();
}

/// Runs the only IPC path that may consume a user-recorded benchmark sample. PCM and its
/// private WAV never cross the command boundary; only non-content benchmark evidence returns.
#[tauri::command]
pub fn finish_and_run_benchmark(
    app: AppHandle,
    capture: State<CaptureController>,
    setup: State<SetupController>,
    verification: State<VerificationTransport>,
) -> Result<BenchmarkReport, AudioCommandError> {
    let mut samples = capture.take_benchmark_sample()?;
    let result = (|| {
        let model_manifest = manifest::bundled_manifest().map_err(benchmark_error)?;
        let model_path = download::destination_for(&app, &model_manifest).map_err(install_error)?;
        download::verify_file(
            &model_path,
            model_manifest.expected_bytes,
            &model_manifest.sha256,
        )
        .map_err(install_error)?;
        let resources = app.path().resource_dir().map_err(benchmark_error)?;
        let runner = InferenceRunner::from_runtime_inventory(resources, HostInfo::supported_x64())
            .map_err(benchmark_error)?;
        BenchmarkTransaction::new(
            runner,
            VerifiedModel {
                path: model_path,
                revision: model_manifest.revision,
            },
        )
        .run(std::mem::take(&mut samples))
        .map_err(benchmark_error)
    })();
    samples.fill(0);
    let report = match result {
        Ok(report) => report,
        Err(error) => {
            verification.record(
                ReceiptCommand::PcmCleanup,
                digest_for_native("temporary-pcm"),
                ReceiptOutcome::Affirmative,
                digest_for_native("benchmark-running"),
                digest_for_native("temporary-pcm-discarded"),
                digest_for_native("native-benchmark-v1"),
            );
            verification.record(
                ReceiptCommand::CpuFixture,
                digest_for_native("cpu-fixture"),
                ReceiptOutcome::Failed,
                digest_for_native("benchmark-running"),
                digest_for_native("benchmark-failed"),
                digest_for_native("native-benchmark-v1"),
            );
            return Err(error);
        }
    };
    let profile = match report.profile.clone() {
        Some(profile) => profile,
        None => {
            verification.record(
                ReceiptCommand::PcmCleanup,
                digest_for_native("temporary-pcm"),
                ReceiptOutcome::Affirmative,
                digest_for_native("benchmark-running"),
                digest_for_native("temporary-pcm-discarded"),
                digest_for_native("native-benchmark-v1"),
            );
            verification.record(
                ReceiptCommand::CpuFixture,
                digest_for_native("cpu-fixture"),
                ReceiptOutcome::Failed,
                digest_for_native("benchmark-running"),
                digest_for_native("benchmark-no-profile"),
                digest_for_native("native-benchmark-v1"),
            );
            return Err(benchmark_error(
                "benchmark did not produce a passing profile",
            ));
        }
    };
    setup.accept_temporary_sample().map_err(benchmark_error)?;
    setup.retain_measured_profile(profile);
    let provenance = digest_for_native(&format!("{:?}", report.profile));
    verification.record(
        ReceiptCommand::CpuFixture,
        digest_for_native("cpu-fixture"),
        ReceiptOutcome::Affirmative,
        digest_for_native("benchmark-running"),
        digest_for_native("cpu-fixture-passed"),
        provenance.clone(),
    );
    for row in &report.rows {
        if row.worker != WorkerKind::Cpu
            && matches!(
                row.outcome,
                crate::inference::benchmark::BenchmarkOutcome::Passed
            )
        {
            verification.record(
                ReceiptCommand::AcceleratorFixture,
                digest_for_native(&format!("{:?}", row.worker)),
                ReceiptOutcome::Affirmative,
                digest_for_native("cpu-fixture-passed"),
                digest_for_native(&format!("accelerator-fixture:{:?}", row.worker)),
                digest_for_native(&format!("{:?}", row)),
            );
        }
    }
    verification.record(
        ReceiptCommand::BenchmarkProfile,
        digest_for_native("measured-profile"),
        ReceiptOutcome::Affirmative,
        digest_for_native("cpu-fixture-passed"),
        digest_for_native("profile-retained"),
        provenance.clone(),
    );
    verification.record(
        ReceiptCommand::PcmCleanup,
        digest_for_native("temporary-pcm"),
        ReceiptOutcome::Affirmative,
        digest_for_native("profile-retained"),
        digest_for_native("temporary-pcm-discarded"),
        provenance,
    );
    Ok(report)
}

#[tauri::command]
pub fn cancel_benchmark_transaction(
    capture: State<CaptureController>,
) -> Result<(), AudioCommandError> {
    let stopped = capture.stop();
    capture.discard_benchmark_sample();
    stopped
}

#[tauri::command]
pub fn retry_benchmark_recording(
    app: AppHandle,
    capture: State<CaptureController>,
) -> Result<(), AudioCommandError> {
    cancel_benchmark_transaction(capture.clone())?;
    capture.start_benchmark_sample(app)
}

fn benchmark_error(error: impl std::fmt::Display) -> AudioCommandError {
    AudioCommandError::Unavailable {
        technical_detail: error.to_string(),
    }
}

fn install_error(error: download::InstallError) -> AudioCommandError {
    AudioCommandError::Unavailable {
        technical_detail: error.ui_detail().1,
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkReadinessRow {
    pub backend: String,
    pub installed: bool,
    pub reason: Option<String>,
}

/// This is deliberately only a packaging/readiness check. A row becomes eligible for scoring
/// only after the runner's immutable fixture self-test succeeds against a sealed worker.
#[tauri::command]
pub fn benchmark_readiness(app: AppHandle) -> Vec<BenchmarkReadinessRow> {
    let installed_workers = app
        .path()
        .resource_dir()
        .ok()
        .and_then(|resources| {
            InferenceRunner::from_runtime_inventory(resources, HostInfo::supported_x64()).ok()
        })
        .map(|runner| runner.installed_workers())
        .unwrap_or_default();
    [WorkerKind::Cpu, WorkerKind::Cuda, WorkerKind::Vulkan]
        .into_iter()
        .map(|kind| {
            let backend = match kind {
                WorkerKind::Cpu => "CPU",
                WorkerKind::Cuda => "CUDA",
                WorkerKind::Vulkan => "Vulkan",
            }
            .to_owned();
            let installed = installed_workers.contains(&kind);
            BenchmarkReadinessRow {
                backend,
                installed,
                reason: (!installed).then(|| {
                    "Worker chưa được niêm phong hoặc không khả dụng trên máy này.".to_owned()
                }),
            }
        })
        .collect()
}

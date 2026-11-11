use serde::Serialize;
use tauri::{AppHandle, Manager, State};

use crate::{
    audio::{
        capture::CaptureController,
        source::{CaptureState, SourceSelection},
    },
    commands::verification::VerificationTransport,
    diagnostics::{DiagnosticSnapshot, ReadinessInputs, ReadinessSnapshot},
    inference::{
        download, manifest,
        runner::{HostInfo, InferenceRunner, VerifiedModel},
        transaction::BenchmarkTransaction,
        ModelInstallState,
    },
    setup::{
        config::{ModelReference, SetupConfigError},
        state::{SetupController, SetupStep},
    },
    verification::{digest_for_native, ReceiptCommand, ReceiptOutcome},
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupSnapshot {
    #[serde(flatten)]
    pub readiness: crate::diagnostics::ReadinessSnapshot,
    pub current_step: Option<SetupStep>,
    pub can_complete: bool,
}

/// Native state owns setup routing; React can request only an explicit wizard entry point.
#[tauri::command]
pub fn setup_readiness(
    setup: State<SetupController>,
    selection: State<SourceSelection>,
) -> ReadinessSnapshot {
    ReadinessSnapshot::assess(ReadinessInputs {
        config: setup.known_good(),
        evidence: setup.launch_evidence(),
        capture: selection.capture_state(),
        diagnostics: DiagnosticSnapshot::empty(),
    })
}

#[tauri::command]
pub fn begin_setup_reconfiguration(setup: State<SetupController>, step: SetupStep) {
    setup.begin_reconfiguration(step);
}

#[tauri::command]
pub fn cancel_setup_reconfiguration(
    setup: State<SetupController>,
    capture: State<CaptureController>,
) -> Result<(), String> {
    capture.stop().map_err(audio_error)?;
    capture.discard_benchmark_sample();
    setup.cancel();
    Ok(())
}

/// The setup transaction is the cleanup boundary used by the UI for cancellation and failures.
#[tauri::command]
pub fn cancel_setup_transaction(
    setup: State<SetupController>,
    capture: State<CaptureController>,
) -> Result<(), String> {
    cancel_setup_reconfiguration(setup, capture)
}

#[tauri::command]
pub fn acknowledge_verified_model(
    app: AppHandle,
    setup: State<SetupController>,
) -> Result<(), String> {
    if !matches!(download::status(&app), ModelInstallState::Ready) {
        return Err("Mô hình đã ghim chưa sẵn sàng hoặc chưa được xác minh.".to_owned());
    }
    let manifest = manifest::bundled_manifest().map_err(|error| error.to_string())?;
    setup
        .accept_verified_model(ModelReference {
            model_id: manifest.model_id,
            revision: manifest.revision,
            sha256: manifest.sha256,
        })
        .map_err(setup_error)
}

#[tauri::command]
pub fn accept_native_benchmark_profile(setup: State<SetupController>) -> Result<(), String> {
    setup.accept_retained_profile().map_err(setup_error)
}

#[tauri::command]
pub fn set_current_official_source(
    setup: State<SetupController>,
    selection: State<SourceSelection>,
    verification: State<VerificationTransport>,
) -> Result<(), String> {
    let before = digest_for_native(&format!("{:?}", setup.state()));
    let result = selection
        .selected()
        .ok_or_else(|| "Chọn nguồn âm thanh chính xác trước khi kiểm tra.".to_owned())
        .and_then(|source| setup.accept_official_source(source).map_err(setup_error));
    verification.record(
        ReceiptCommand::OfficialSource,
        digest_for_native(&format!("{:?}", selection.selected())),
        if result.is_ok() {
            ReceiptOutcome::Affirmative
        } else {
            ReceiptOutcome::Failed
        },
        before,
        digest_for_native(&format!("{:?}", setup.state())),
        digest_for_native("native-setup-v1"),
    );
    result
}

#[tauri::command]
pub fn start_official_source_test(
    app: AppHandle,
    setup: State<SetupController>,
    capture: State<CaptureController>,
    selection: State<SourceSelection>,
) -> Result<(), String> {
    if !matches!(
        setup.state(),
        crate::setup::state::SetupState::Wizard(SetupStep::OfficialSource)
    ) || selection.selected().is_none()
    {
        return Err("Nguồn chính thức chưa được xác nhận theo luồng thiết lập.".to_owned());
    }
    capture.start_benchmark_sample(app).map_err(audio_error)
}

#[tauri::command]
pub fn finish_official_source_test(
    app: AppHandle,
    setup: State<SetupController>,
    capture: State<CaptureController>,
    selection: State<SourceSelection>,
    verification: State<VerificationTransport>,
) -> Result<(), String> {
    let before = digest_for_native(&format!("{:?}", setup.state()));
    let has_signal = matches!(selection.capture_state(), CaptureState::Active);
    setup
        .record_official_signal(has_signal)
        .map_err(setup_error)?;
    let mut samples = capture.take_benchmark_sample().map_err(audio_error)?;
    let result = (|| {
        let profile = setup
            .selected_profile()
            .ok_or_else(|| "Chưa có profile benchmark được giữ ở native.".to_owned())?;
        let model_manifest = manifest::bundled_manifest().map_err(|error| error.to_string())?;
        let model_path = download::destination_for(&app, &model_manifest)
            .map_err(|error| error.ui_detail().1)?;
        download::verify_file(
            &model_path,
            model_manifest.expected_bytes,
            &model_manifest.sha256,
        )
        .map_err(|error| error.ui_detail().1)?;
        let resources = app
            .path()
            .resource_dir()
            .map_err(|error| error.to_string())?;
        let runner = InferenceRunner::from_runtime_inventory(resources, HostInfo::supported_x64())
            .map_err(|error| error.to_string())?;
        BenchmarkTransaction::new(
            runner,
            VerifiedModel {
                path: model_path,
                revision: model_manifest.revision,
            },
        )
        .run_one_shot(&profile, std::mem::take(&mut samples))
        .map_err(|error| error.to_string())
    })();
    samples.fill(0);
    result?;
    let result = setup.record_official_caption(true).map_err(setup_error);
    verification.record(
        ReceiptCommand::OfficialCaption,
        digest_for_native("official-one-shot-complete"),
        if result.is_ok() {
            ReceiptOutcome::Affirmative
        } else {
            ReceiptOutcome::Failed
        },
        before,
        digest_for_native(&format!("{:?}", setup.state())),
        digest_for_native("native-setup-v1"),
    );
    result
}

#[tauri::command]
pub fn complete_setup(
    setup: State<SetupController>,
    capture: State<CaptureController>,
    verification: State<VerificationTransport>,
) -> Result<(), String> {
    let before = digest_for_native(&format!("{:?}", setup.state()));
    capture.stop().map_err(audio_error)?;
    capture.discard_benchmark_sample();
    let result = setup.commit().map_err(setup_error);
    verification.record(
        ReceiptCommand::SetupCommit,
        digest_for_native("setup-commit"),
        if result.is_ok() {
            ReceiptOutcome::Affirmative
        } else {
            ReceiptOutcome::Failed
        },
        before,
        digest_for_native(&format!("{:?}", setup.state())),
        digest_for_native("native-setup-v1"),
    );
    result
}

#[tauri::command]
pub fn setup_snapshot(
    setup: State<SetupController>,
    selection: State<SourceSelection>,
) -> SetupSnapshot {
    let (current_step, can_complete) = setup.current_step_and_can_complete();
    SetupSnapshot {
        readiness: setup_readiness(setup, selection),
        current_step,
        can_complete,
    }
}

/// Startup has no IPC caller: it rechecks the persisted model/profile against the sealed worker
/// and the exact endpoint before restoring Ready. Any failed probe leaves native evidence false.
pub fn revalidate_loaded_setup(
    app: &AppHandle,
    setup: &SetupController,
    selection: &SourceSelection,
) {
    let Some(config) = setup.known_good() else {
        return;
    };
    let source_available = crate::audio::endpoints::enumerate_catalogues()
        .ok()
        .and_then(|catalogues| {
            crate::commands::audio::select_active_catalogue_source(
                config.official_source.clone(),
                catalogues,
            )
            .ok()
        })
        .is_some_and(|source| selection.select(source).is_ok());
    if !source_available {
        selection.mark_unavailable("saved endpoint is no longer available");
    }

    let mut evidence = crate::setup::state::ReadinessEvidence::default();
    let manifest = manifest::bundled_manifest().ok();
    let model_path = manifest
        .as_ref()
        .and_then(|manifest| download::destination_for(app, manifest).ok());
    evidence.model_current =
        manifest
            .as_ref()
            .zip(model_path.as_ref())
            .is_some_and(|(manifest, path)| {
                manifest.model_id == config.model.model_id
                    && manifest.revision == config.model.revision
                    && manifest.sha256 == config.model.sha256
                    && download::verify_file(path, manifest.expected_bytes, &manifest.sha256)
                        .is_ok()
            });
    let mut fingerprint = config.profile.hardware_fingerprint.clone();
    if evidence.model_current {
        let worker = match config.profile.backend.to_ascii_lowercase().as_str() {
            "cpu" => Some(crate::inference::runner::WorkerKind::Cpu),
            "cuda" => Some(crate::inference::runner::WorkerKind::Cuda),
            "vulkan" => Some(crate::inference::runner::WorkerKind::Vulkan),
            _ => None,
        };
        let quick_test = worker.zip(model_path).and_then(|(worker, path)| {
            let resources = app.path().resource_dir().ok()?;
            let runner =
                InferenceRunner::from_runtime_inventory(resources, HostInfo::supported_x64())
                    .ok()?;
            let result = runner
                .run(
                    worker,
                    &VerifiedModel {
                        path,
                        revision: config.model.revision.clone(),
                    },
                )
                .ok()?;
            Some((worker, result))
        });
        if let Some((worker, result)) = quick_test {
            evidence.profile_current = result.worker_build == config.profile.worker_build
                && result.model_revision == config.model.revision;
            evidence.fixture_identity_current = evidence.profile_current;
            evidence.fixture_transcript_matches = evidence.profile_current;
            fingerprint = format!(
                "{:?}:{}:{}",
                worker,
                result.diagnostics.driver.as_deref().unwrap_or("unknown"),
                result.diagnostics.memory_bytes.unwrap_or(0)
            );
        }
    }
    setup.revalidate_loaded(&fingerprint, evidence, source_available);
}

fn setup_error(error: SetupConfigError) -> String {
    error.to_string()
}
fn audio_error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

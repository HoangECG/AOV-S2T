use std::{
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

use live_subtitle_tool::{
    audio::source::{SelectedSource, SourceKind},
    inference::{
        benchmark::{FixtureEvidence, InferenceProfile},
        runner::WorkerKind,
    },
    setup::{
        config::{ModelReference, SetupConfigStore},
        state::{ReadinessEvidence, SetupController, SetupState, SetupStep},
    },
};

fn profile() -> InferenceProfile {
    InferenceProfile {
        worker: WorkerKind::Cpu,
        worker_build: "sealed-worker".to_owned(),
        model_revision: "a".repeat(40),
        hardware_fingerprint: "target-fingerprint".to_owned(),
        rtf: 0.5,
        p95_ms: 1_000,
        correctness: 0.95,
        fixture: FixtureEvidence {
            fixture_id: "fixture-id".to_owned(),
            audio_sha256: "fixture-audio".to_owned(),
            expected_transcript_sha256: "fixture-expected".to_owned(),
            passed_at: "native-gate".to_owned(),
        },
    }
}

#[test]
fn native_setup_route_commits_only_after_retained_evidence_and_official_check() {
    let path = std::env::temp_dir().join(format!(
        "live-subtitle-command-flow-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let store = SetupConfigStore::new(path.clone());
    let setup = SetupController::new(store.clone());

    assert!(setup.accept_retained_profile().is_err());
    setup
        .accept_verified_model(ModelReference {
            model_id: "ggml-phowhisper-large".to_owned(),
            revision: "a".repeat(40),
            sha256: "b".repeat(64),
        })
        .unwrap();
    setup.accept_temporary_sample().unwrap();
    setup.retain_measured_profile(profile());
    setup.accept_retained_profile().unwrap();
    setup
        .accept_official_source(SelectedSource {
            kind: SourceKind::DesktopLoopback,
            endpoint_id: "exact-render-id".to_owned(),
            display_name: "Loa".to_owned(),
        })
        .unwrap();
    assert!(
        setup.commit().is_err(),
        "signal and one-shot completion are native predicates"
    );
    setup.record_official_signal(true).unwrap();
    setup.record_official_caption(true).unwrap();
    setup.commit().unwrap();

    assert_eq!(setup.state(), SetupState::Ready);
    assert_eq!(
        store.load().unwrap().unwrap().official_source.endpoint_id,
        "exact-render-id"
    );
    fs::remove_file(path).unwrap();
}

#[test]
fn cancelling_a_candidate_keeps_existing_known_good_and_drops_retained_profile() {
    let path = std::env::temp_dir().join(format!(
        "live-subtitle-command-cancel-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let store = SetupConfigStore::new(path.clone());
    let setup = SetupController::new(store);
    setup.retain_measured_profile(profile());
    setup.cancel();
    assert!(setup.selected_profile().is_none());
    assert_eq!(setup.state(), SetupState::Empty);
}

#[test]
fn restart_requires_current_native_checks_or_returns_to_the_affected_step() {
    let path = std::env::temp_dir().join(format!(
        "live-subtitle-command-restart-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let store = SetupConfigStore::new(path.clone());
    let setup = SetupController::new(store.clone());
    setup
        .accept_verified_model(ModelReference {
            model_id: "ggml-phowhisper-large".to_owned(),
            revision: "a".repeat(40),
            sha256: "b".repeat(64),
        })
        .unwrap();
    setup.accept_temporary_sample().unwrap();
    setup.retain_measured_profile(profile());
    setup.accept_retained_profile().unwrap();
    setup
        .accept_official_source(SelectedSource {
            kind: SourceKind::Input,
            endpoint_id: "exact-input-id".to_owned(),
            display_name: "Mic".to_owned(),
        })
        .unwrap();
    setup.record_official_signal(true).unwrap();
    setup.record_official_caption(true).unwrap();
    setup.commit().unwrap();

    let restored = SetupController::from_store(&store).unwrap();
    restored.begin_reconfiguration(SetupStep::OfficialSource);
    assert_eq!(
        restored.selected_profile().unwrap().model_revision,
        "a".repeat(40)
    );
    assert_eq!(
        restored.revalidate_loaded("target-fingerprint", ReadinessEvidence::passing(), true),
        SetupState::Ready
    );
    assert_eq!(
        restored.revalidate_loaded("changed-fingerprint", ReadinessEvidence::passing(), true),
        SetupState::ConfirmationRequired
    );
    let stale_fixture = ReadinessEvidence {
        fixture_transcript_matches: false,
        ..ReadinessEvidence::passing()
    };
    assert_eq!(
        restored.revalidate_loaded("target-fingerprint", stale_fixture, true),
        SetupState::Wizard(SetupStep::Benchmark)
    );
    fs::remove_file(path).unwrap();
}

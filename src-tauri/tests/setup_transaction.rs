use std::{
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

use live_subtitle_tool::{
    audio::source::{SelectedSource, SourceKind},
    setup::{
        config::{KnownGoodConfig, ModelReference, ProfileEvidence, SetupConfigStore},
        state::{CandidateSetup, ReadinessEvidence, SetupMachine, SetupStep},
    },
};

fn source(id: &str) -> SelectedSource {
    SelectedSource {
        kind: SourceKind::Input,
        endpoint_id: id.to_owned(),
        display_name: "Nguồn thử".to_owned(),
    }
}

fn candidate() -> CandidateSetup {
    CandidateSetup {
        model: Some(ModelReference {
            model_id: "ggml-phowhisper-large".to_owned(),
            revision: "a".repeat(40),
            sha256: "b".repeat(64),
        }),
        temporary_sample_id: Some("temporary-only".to_owned()),
        profile: Some(ProfileEvidence::test_profile()),
        official_source: Some(source("official-id")),
        evidence: ReadinessEvidence::passing(),
    }
}

#[test]
fn temporary_sample_never_reaches_known_good_serialization() {
    let config = KnownGoodConfig::from_candidate(&candidate()).expect("passing candidate");
    let serialized = serde_json::to_string(&config).expect("serializes");
    assert!(!serialized.contains("temporary-only"));
    assert!(serialized.contains("official-id"));
}

#[test]
fn commit_is_atomic_and_failure_preserves_previous_bytes() {
    let path = std::env::temp_dir().join(format!(
        "live-subtitle-setup-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let old = b"{\"previous\":true}\n";
    fs::write(&path, old).expect("old config");
    let store = SetupConfigStore::new(path.clone());

    let mut machine =
        SetupMachine::with_known_good(KnownGoodConfig::from_candidate(&candidate()).unwrap());
    machine.begin_reconfiguration(SetupStep::OfficialSource);
    assert!(machine.commit(&store).is_err());
    assert_eq!(fs::read(&path).unwrap(), old);

    machine
        .accept_official_source(source("official-id"))
        .unwrap();
    machine.record_official_signal(true).unwrap();
    machine.record_official_caption(true).unwrap();
    machine.commit(&store).expect("full predicate set commits");
    assert_ne!(fs::read(&path).unwrap(), old);
    fs::remove_file(path).expect("remove test config");
}

#[test]
fn load_rejects_corrupt_or_incomplete_files_without_rewriting_them() {
    let path = std::env::temp_dir().join(format!(
        "live-subtitle-setup-load-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let corrupt = b"{not-json}";
    fs::write(&path, corrupt).expect("corrupt config");
    let store = SetupConfigStore::new(path.clone());

    assert!(store.load().is_err());
    assert_eq!(fs::read(&path).unwrap(), corrupt);

    fs::write(
        &path,
        br#"{"schemaVersion":1,"model":{},"profile":{},"officialSource":{},"committedAt":"now"}"#,
    )
    .unwrap();
    assert!(store.load().is_err());
    fs::remove_file(path).expect("remove test config");
}

#[test]
fn commit_clears_candidate_and_load_reconstructs_only_known_good() {
    let path = std::env::temp_dir().join(format!(
        "live-subtitle-setup-known-good-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let store = SetupConfigStore::new(path.clone());
    let mut machine = SetupMachine::new();
    *machine.candidate_mut() = candidate();

    machine.commit(&store).expect("commit known good");
    assert_eq!(
        machine.state(),
        live_subtitle_tool::setup::state::SetupState::Ready
    );
    assert!(machine.candidate_mut().temporary_sample_id.is_none());
    let loaded = store.load().expect("valid load").expect("known good");
    assert_eq!(loaded.official_source.endpoint_id, "official-id");
    assert!(!serde_json::to_string(&loaded)
        .unwrap()
        .contains("temporary-only"));
    fs::remove_file(path).expect("remove test config");
}

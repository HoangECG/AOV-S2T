use live_subtitle_tool::{
    audio::source::{SelectedSource, SourceKind},
    setup::{
        config::{ModelReference, ProfileEvidence},
        state::{CandidateSetup, ReadinessEvidence, SetupMachine, SetupState, SetupStep},
    },
};

fn source() -> SelectedSource {
    SelectedSource {
        kind: SourceKind::DesktopLoopback,
        endpoint_id: "loopback-id".to_owned(),
        display_name: "Loa".to_owned(),
    }
}

fn passing_candidate() -> CandidateSetup {
    CandidateSetup {
        model: Some(ModelReference {
            model_id: "ggml-phowhisper-large".to_owned(),
            revision: "a".repeat(40),
            sha256: "b".repeat(64),
        }),
        temporary_sample_id: Some("temporary".to_owned()),
        profile: Some(ProfileEvidence::test_profile()),
        official_source: Some(source()),
        evidence: ReadinessEvidence::passing(),
    }
}

#[test]
fn first_run_cannot_skip_model_sample_benchmark_or_official_source() {
    let mut machine = SetupMachine::new();
    assert_eq!(machine.state(), SetupState::Wizard(SetupStep::Model));
    assert!(machine.advance().is_err());
    machine.candidate_mut().model = passing_candidate().model;
    machine.advance().unwrap();
    assert_eq!(
        machine.state(),
        SetupState::Wizard(SetupStep::BenchmarkSample)
    );
    assert!(machine.advance().is_err());
    machine.candidate_mut().temporary_sample_id = Some("temporary".to_owned());
    machine.advance().unwrap();
    assert_eq!(machine.state(), SetupState::Wizard(SetupStep::Benchmark));
    assert!(machine.advance().is_err());
    machine.candidate_mut().profile = passing_candidate().profile;
    machine.advance().unwrap();
    assert_eq!(
        machine.state(),
        SetupState::Wizard(SetupStep::OfficialSource)
    );
}

#[test]
fn ready_requires_signal_caption_and_exact_fixture_match() {
    let mut candidate = passing_candidate();
    candidate.evidence.fixture_transcript_matches = false;
    assert!(!candidate.is_ready());
    candidate.evidence.fixture_transcript_matches = true;
    candidate.evidence.official_caption_complete = false;
    assert!(!candidate.is_ready());
    candidate.evidence.official_caption_complete = true;
    candidate.evidence.source_signal_current = false;
    assert!(!candidate.is_ready());
}

#[test]
fn changed_fingerprint_needs_confirmation_and_cancel_preserves_known_good() {
    let known_good =
        live_subtitle_tool::setup::config::KnownGoodConfig::from_candidate(&passing_candidate())
            .unwrap();
    let mut machine = SetupMachine::with_known_good(known_good.clone());
    machine.check_launch("different-fingerprint", &ReadinessEvidence::passing());
    assert_eq!(machine.state(), SetupState::ConfirmationRequired);
    machine.cancel();
    assert_eq!(machine.known_good(), Some(&known_good));
}

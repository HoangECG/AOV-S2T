use live_subtitle_tool::{
    audio::source::{CaptureState, SelectedSource, SourceKind},
    diagnostics::{DiagnosticSnapshot, ReadinessInputs, ReadinessSnapshot, ReadinessState},
    setup::{
        config::{KnownGoodConfig, ModelReference, ProfileEvidence},
        state::{CandidateSetup, ReadinessEvidence},
    },
};

fn config() -> KnownGoodConfig {
    KnownGoodConfig::from_candidate(&CandidateSetup {
        model: Some(ModelReference {
            model_id: "ggml-phowhisper-large".to_owned(),
            revision: "a".repeat(40),
            sha256: "b".repeat(64),
        }),
        profile: Some(ProfileEvidence::test_profile()),
        official_source: Some(SelectedSource {
            kind: SourceKind::Input,
            endpoint_id: "exact-id".to_owned(),
            display_name: "Nguồn chính".to_owned(),
        }),
        temporary_sample_id: Some("never-persisted".to_owned()),
        evidence: ReadinessEvidence::passing(),
    })
    .unwrap()
}

#[test]
fn every_stale_or_missing_predicate_is_not_ready() {
    for evidence in [
        ReadinessEvidence {
            model_current: false,
            ..ReadinessEvidence::passing()
        },
        ReadinessEvidence {
            profile_current: false,
            ..ReadinessEvidence::passing()
        },
        ReadinessEvidence {
            fixture_identity_current: false,
            ..ReadinessEvidence::passing()
        },
        ReadinessEvidence {
            fixture_transcript_matches: false,
            ..ReadinessEvidence::passing()
        },
        ReadinessEvidence {
            source_signal_current: false,
            ..ReadinessEvidence::passing()
        },
        ReadinessEvidence {
            official_caption_complete: false,
            ..ReadinessEvidence::passing()
        },
    ] {
        let snapshot = ReadinessSnapshot::assess(ReadinessInputs {
            config: Some(config()),
            evidence,
            capture: CaptureState::Active,
            diagnostics: DiagnosticSnapshot::empty(),
        });
        assert_ne!(snapshot.state, ReadinessState::Ready);
    }
}

#[test]
fn diagnostics_are_non_content_and_source_loss_preserves_identity() {
    let snapshot = ReadinessSnapshot::assess(ReadinessInputs {
        config: Some(config()),
        evidence: ReadinessEvidence::passing(),
        capture: CaptureState::Unavailable {
            reason: "removed".to_owned(),
        },
        diagnostics: DiagnosticSnapshot::empty(),
    });
    assert_eq!(snapshot.state, ReadinessState::SourceUnavailable);
    assert_eq!(snapshot.source.as_ref().unwrap().endpoint_id, "exact-id");
    let encoded = serde_json::to_string(&snapshot).unwrap();
    assert!(!encoded.contains("never-persisted"));
    assert!(!encoded.contains("transcript"));
    assert!(encoded.contains("modelId"));
    assert!(encoded.contains("endpointId"));
    assert!(encoded.contains("hardwareFingerprint"));
}

#[test]
fn saved_signal_and_caption_evidence_allow_idle_ready_after_revalidation() {
    let snapshot = ReadinessSnapshot::assess(ReadinessInputs {
        config: Some(config()),
        evidence: ReadinessEvidence::passing(),
        capture: CaptureState::Stopped,
        diagnostics: DiagnosticSnapshot::empty(),
    });
    assert_eq!(snapshot.state, ReadinessState::Ready);
}

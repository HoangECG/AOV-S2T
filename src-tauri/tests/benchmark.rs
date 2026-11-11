use live_subtitle_tool::inference::{
    benchmark::{
        select_profile, BenchmarkCandidate, BenchmarkFailure, BenchmarkMeasurement,
        BenchmarkOutcome, BENCHMARK_PROMPT,
    },
    runner::WorkerKind,
};

fn candidate(kind: WorkerKind, transcript: &str, rtf: f32, p95_ms: u64) -> BenchmarkCandidate {
    BenchmarkCandidate {
        worker: kind,
        worker_build: format!("{kind:?}-build"),
        model_revision: "pinned-model".to_owned(),
        hardware_fingerprint: "local-hardware".to_owned(),
        fixture_passed: true,
        measurement: Some(BenchmarkMeasurement {
            transcript: transcript.to_owned(),
            cold_load_ms: 900,
            warm_rtf: rtf,
            warm_p95_ms: p95_ms,
            memory_bytes: Some(1_024),
            driver: Some("driver-1".to_owned()),
        }),
        unavailable_reason: None,
    }
}

#[test]
fn cpu_is_always_measured_and_a_gpu_only_wins_when_its_warm_evidence_is_better() {
    let cpu = candidate(WorkerKind::Cpu, BENCHMARK_PROMPT, 0.65, 2_100);
    let cuda = candidate(WorkerKind::Cuda, BENCHMARK_PROMPT, 0.22, 900);

    let report = select_profile(BENCHMARK_PROMPT, vec![cuda, cpu]);

    assert_eq!(report.rows.len(), 3);
    assert!(report.rows.iter().any(|row| row.worker == WorkerKind::Cpu));
    assert_eq!(report.profile.as_ref().unwrap().worker, WorkerKind::Cuda);
    assert!(!report
        .profile
        .as_ref()
        .unwrap()
        .fixture
        .fixture_id
        .is_empty());
}

#[test]
fn rejected_fixture_or_wrong_user_transcript_never_reaches_profile_selection() {
    let mut mismatch = candidate(WorkerKind::Cuda, BENCHMARK_PROMPT, 0.1, 100);
    mismatch.fixture_passed = false;
    let wrong_text = candidate(WorkerKind::Cpu, "văn bản khác", 0.1, 100);

    let report = select_profile(BENCHMARK_PROMPT, vec![mismatch, wrong_text]);

    assert!(report.profile.is_none());
    assert!(report
        .rows
        .iter()
        .any(|row| row.failure == Some(BenchmarkFailure::TranscriptMismatch)));
    assert!(report
        .rows
        .iter()
        .any(|row| row.failure == Some(BenchmarkFailure::AccuracyBelowThreshold)));
}

#[test]
fn cold_load_is_not_used_for_admission_and_slow_or_unstable_workers_are_rejected() {
    let cold = candidate(WorkerKind::Cpu, BENCHMARK_PROMPT, 0.79, 2_999);
    let too_slow = candidate(WorkerKind::Vulkan, BENCHMARK_PROMPT, 0.81, 2_000);

    let report = select_profile(BENCHMARK_PROMPT, vec![cold, too_slow]);

    assert_eq!(report.profile.as_ref().unwrap().worker, WorkerKind::Cpu);
    let rejected = report
        .rows
        .iter()
        .find(|row| row.worker == WorkerKind::Vulkan)
        .unwrap();
    assert_eq!(rejected.outcome, BenchmarkOutcome::Rejected);
    assert_eq!(rejected.failure, Some(BenchmarkFailure::RealTimeFactor));
}

#[test]
fn missing_workers_and_profile_evidence_do_not_store_user_sample_or_transcript() {
    let mut unavailable = candidate(WorkerKind::Cuda, BENCHMARK_PROMPT, 0.1, 100);
    unavailable.measurement = None;
    unavailable.unavailable_reason = Some("worker is not present".to_owned());
    let cpu = candidate(WorkerKind::Cpu, BENCHMARK_PROMPT, 0.6, 1_000);

    let report = select_profile(BENCHMARK_PROMPT, vec![unavailable, cpu]);
    let profile = report.profile.unwrap();

    assert_eq!(
        report
            .rows
            .iter()
            .find(|row| row.worker == WorkerKind::Cuda)
            .unwrap()
            .outcome,
        BenchmarkOutcome::NotInstalled
    );
    let encoded = serde_json::to_string(&profile).unwrap();
    assert!(!encoded.contains(BENCHMARK_PROMPT));
    assert!(!encoded.contains("transcript"));
}

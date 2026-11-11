use serde::Serialize;

use super::runner::WorkerKind;

pub const BENCHMARK_PROMPT: &str = "Đây là mẫu kiểm tra nhận diện tiếng Việt.";
pub const MIN_CORRECTNESS: f32 = 0.85;
pub const MAX_WARM_RTF: f32 = 0.8;
pub const MAX_WARM_P95_MS: u64 = 3_000;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FixtureEvidence {
    pub fixture_id: String,
    pub audio_sha256: String,
    pub expected_transcript_sha256: String,
    pub passed_at: String,
}

impl Default for FixtureEvidence {
    fn default() -> Self {
        Self {
            fixture_id: "immutable-self-test".to_owned(),
            audio_sha256: "verified-by-runner".to_owned(),
            expected_transcript_sha256: "verified-by-runner".to_owned(),
            passed_at: "local-run".to_owned(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct BenchmarkMeasurement {
    /// Transient local data. It is deliberately not part of result/profile types.
    pub transcript: String,
    pub cold_load_ms: u64,
    pub warm_rtf: f32,
    pub warm_p95_ms: u64,
    pub memory_bytes: Option<u64>,
    pub driver: Option<String>,
}

#[derive(Clone, Debug)]
pub struct BenchmarkCandidate {
    pub worker: WorkerKind,
    pub worker_build: String,
    pub model_revision: String,
    pub hardware_fingerprint: String,
    pub fixture_passed: bool,
    pub measurement: Option<BenchmarkMeasurement>,
    pub unavailable_reason: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BenchmarkOutcome {
    Passed,
    Rejected,
    NotInstalled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BenchmarkFailure {
    TranscriptMismatch,
    AccuracyBelowThreshold,
    RealTimeFactor,
    P95Latency,
    WorkerUnavailable,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkResult {
    pub worker: WorkerKind,
    pub worker_build: String,
    pub model_revision: String,
    pub correctness: Option<f32>,
    pub cold_load_ms: Option<u64>,
    pub rtf: Option<f32>,
    pub p95_ms: Option<u64>,
    pub memory_bytes: Option<u64>,
    pub driver: Option<String>,
    pub outcome: BenchmarkOutcome,
    pub failure: Option<BenchmarkFailure>,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceProfile {
    pub worker: WorkerKind,
    pub worker_build: String,
    pub model_revision: String,
    pub hardware_fingerprint: String,
    pub rtf: f32,
    pub p95_ms: u64,
    pub correctness: f32,
    pub fixture: FixtureEvidence,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkReport {
    pub rows: Vec<BenchmarkResult>,
    pub profile: Option<InferenceProfile>,
    pub fallback_reason: Option<String>,
}

/// Scores only warmed full-pipeline measurements. The candidate's transcript is read here and
/// never copied into a result, diagnostic, or persisted profile.
pub fn select_profile(reference: &str, candidates: Vec<BenchmarkCandidate>) -> BenchmarkReport {
    select_profile_with_fixture(reference, candidates, FixtureEvidence::default())
}

pub fn select_profile_with_fixture(
    reference: &str,
    candidates: Vec<BenchmarkCandidate>,
    fixture: FixtureEvidence,
) -> BenchmarkReport {
    let mut rows = Vec::new();
    let mut passing = Vec::new();
    for worker in [WorkerKind::Cpu, WorkerKind::Cuda, WorkerKind::Vulkan] {
        let candidate = candidates
            .iter()
            .find(|candidate| candidate.worker == worker);
        let Some(candidate) = candidate else {
            rows.push(unavailable(worker, "worker is not packaged"));
            continue;
        };
        if !candidate.fixture_passed {
            rows.push(rejected(
                candidate,
                None,
                BenchmarkFailure::TranscriptMismatch,
            ));
            continue;
        }
        let Some(measurement) = &candidate.measurement else {
            rows.push(unavailable(
                worker,
                candidate
                    .unavailable_reason
                    .as_deref()
                    .unwrap_or("worker evidence is unavailable"),
            ));
            continue;
        };
        let correctness = correctness(reference, &measurement.transcript);
        let failure = if correctness < MIN_CORRECTNESS {
            Some(BenchmarkFailure::AccuracyBelowThreshold)
        } else if measurement.warm_rtf >= MAX_WARM_RTF {
            Some(BenchmarkFailure::RealTimeFactor)
        } else if measurement.warm_p95_ms > MAX_WARM_P95_MS {
            Some(BenchmarkFailure::P95Latency)
        } else {
            None
        };
        let row = result(candidate, Some(correctness), failure);
        if failure.is_none() {
            passing.push((candidate, correctness, row.clone()));
        }
        rows.push(row);
    }
    let selected = passing.into_iter().max_by(|left, right| {
        left.1
            .total_cmp(&right.1)
            .then_with(|| right.2.p95_ms.cmp(&left.2.p95_ms))
            .then_with(|| {
                right
                    .2
                    .rtf
                    .unwrap_or(f32::INFINITY)
                    .total_cmp(&left.2.rtf.unwrap_or(f32::INFINITY))
            })
    });
    let profile = selected.map(|(candidate, correctness, row)| InferenceProfile {
        worker: candidate.worker,
        worker_build: candidate.worker_build.clone(),
        model_revision: candidate.model_revision.clone(),
        hardware_fingerprint: candidate.hardware_fingerprint.clone(),
        rtf: row.rtf.expect("passing row has RTF"),
        p95_ms: row.p95_ms.expect("passing row has p95"),
        correctness,
        fixture,
    });
    let fallback_reason = profile.as_ref().and_then(|selected| {
        (selected.worker == WorkerKind::Cpu).then(|| {
            "CPU selected because no accelerated candidate had better passing warm evidence."
                .to_owned()
        })
    });
    BenchmarkReport {
        rows,
        profile,
        fallback_reason,
    }
}

fn result(
    candidate: &BenchmarkCandidate,
    correctness: Option<f32>,
    failure: Option<BenchmarkFailure>,
) -> BenchmarkResult {
    let measurement = candidate
        .measurement
        .as_ref()
        .expect("result only has a measurement");
    BenchmarkResult {
        worker: candidate.worker,
        worker_build: candidate.worker_build.clone(),
        model_revision: candidate.model_revision.clone(),
        correctness,
        cold_load_ms: Some(measurement.cold_load_ms),
        rtf: Some(measurement.warm_rtf),
        p95_ms: Some(measurement.warm_p95_ms),
        memory_bytes: measurement.memory_bytes,
        driver: measurement.driver.clone(),
        outcome: if failure.is_some() {
            BenchmarkOutcome::Rejected
        } else {
            BenchmarkOutcome::Passed
        },
        failure,
        reason: failure.map(reason).map(str::to_owned),
    }
}

fn rejected(
    candidate: &BenchmarkCandidate,
    correctness: Option<f32>,
    failure: BenchmarkFailure,
) -> BenchmarkResult {
    BenchmarkResult {
        worker: candidate.worker,
        worker_build: candidate.worker_build.clone(),
        model_revision: candidate.model_revision.clone(),
        correctness,
        cold_load_ms: None,
        rtf: None,
        p95_ms: None,
        memory_bytes: None,
        driver: None,
        outcome: BenchmarkOutcome::Rejected,
        failure: Some(failure),
        reason: Some(reason(failure).to_owned()),
    }
}

fn unavailable(worker: WorkerKind, message: &str) -> BenchmarkResult {
    BenchmarkResult {
        worker,
        worker_build: "Không có".to_owned(),
        model_revision: "Không có".to_owned(),
        correctness: None,
        cold_load_ms: None,
        rtf: None,
        p95_ms: None,
        memory_bytes: None,
        driver: None,
        outcome: BenchmarkOutcome::NotInstalled,
        failure: Some(BenchmarkFailure::WorkerUnavailable),
        reason: Some(message.to_owned()),
    }
}

fn reason(failure: BenchmarkFailure) -> &'static str {
    match failure {
        BenchmarkFailure::TranscriptMismatch => {
            "immutable fixture transcript did not exactly match"
        }
        BenchmarkFailure::AccuracyBelowThreshold => "correctness is below the documented threshold",
        BenchmarkFailure::RealTimeFactor => "warmed real-time factor is not below 0.8",
        BenchmarkFailure::P95Latency => "warmed p95 is above 3000 ms",
        BenchmarkFailure::WorkerUnavailable => "worker is unavailable",
    }
}

fn correctness(reference: &str, transcript: &str) -> f32 {
    let normalized_reference = normalize(reference);
    let normalized_transcript = normalize(transcript);
    let reference: Vec<_> = normalized_reference
        .split(' ')
        .filter(|word| !word.is_empty())
        .collect();
    let transcript: Vec<_> = normalized_transcript
        .split(' ')
        .filter(|word| !word.is_empty())
        .collect();
    if reference.is_empty() {
        return 0.0;
    }
    let matched = reference
        .iter()
        .filter(|word| transcript.contains(word))
        .count();
    matched as f32 / reference.len() as f32
}

fn normalize(value: &str) -> String {
    value
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn passing_candidate(worker: WorkerKind) -> BenchmarkCandidate {
        BenchmarkCandidate {
            worker,
            worker_build: "test-worker".to_owned(),
            model_revision: "test-model".to_owned(),
            hardware_fingerprint: "test-hardware".to_owned(),
            fixture_passed: true,
            measurement: Some(BenchmarkMeasurement {
                transcript: "xin chao".to_owned(),
                cold_load_ms: 1,
                warm_rtf: 0.1,
                warm_p95_ms: 100,
                memory_bytes: None,
                driver: None,
            }),
            unavailable_reason: None,
        }
    }

    #[test]
    fn selects_cuda_when_cpu_does_not_pass() {
        let report = select_profile("xin chao", vec![passing_candidate(WorkerKind::Cuda)]);

        assert_eq!(
            report.profile.map(|profile| profile.worker),
            Some(WorkerKind::Cuda)
        );
    }
}

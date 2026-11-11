use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use live_subtitle_tool::inference::{
    benchmark::{BenchmarkOutcome, BENCHMARK_PROMPT},
    runner::{RunnerFailure, VerifiedModel, WorkerDiagnostics, WorkerKind, WorkerResult},
    transaction::{BenchmarkRunner, BenchmarkTransaction},
};

#[derive(Clone)]
struct FakeRunner {
    inputs: Arc<Mutex<Vec<PathBuf>>>,
}

impl FakeRunner {
    fn result(kind: WorkerKind, elapsed_ms: u64) -> WorkerResult {
        WorkerResult {
            backend: kind,
            worker_build: format!("{kind:?}-build"),
            model_revision: "pinned-model".to_owned(),
            elapsed_ms,
            transcript: BENCHMARK_PROMPT.to_owned(),
            exit_status: 0,
            diagnostics: WorkerDiagnostics {
                missing_hardware: None,
                driver: Some("test-driver".to_owned()),
                memory_bytes: Some(1024),
                failure_code: None,
            },
        }
    }
}

impl BenchmarkRunner for FakeRunner {
    fn fixture(
        &self,
        kind: WorkerKind,
        _model: &VerifiedModel,
    ) -> Result<WorkerResult, RunnerFailure> {
        Ok(Self::result(kind, 100))
    }

    fn input(
        &self,
        kind: WorkerKind,
        _model: &VerifiedModel,
        input: &Path,
        _transaction_dir: &Path,
    ) -> Result<WorkerResult, RunnerFailure> {
        assert!(input.is_file());
        self.inputs.lock().unwrap().push(input.to_owned());
        Ok(Self::result(
            kind,
            if kind == WorkerKind::Cuda { 120 } else { 300 },
        ))
    }

    fn installed_workers(&self) -> Vec<WorkerKind> {
        vec![WorkerKind::Cpu, WorkerKind::Cuda]
    }
}

#[test]
fn accepted_sample_runs_fixture_then_warm_measurements_and_keeps_content_out_of_the_report() {
    let inputs = Arc::new(Mutex::new(Vec::new()));
    let runner = FakeRunner {
        inputs: Arc::clone(&inputs),
    };
    let transaction = BenchmarkTransaction::new(
        runner,
        VerifiedModel {
            path: PathBuf::from("verified-model.bin"),
            revision: "pinned-model".to_owned(),
        },
    );

    let report = transaction
        .run(vec![1_000; 16_000])
        .expect("accepted sample is benchmarked");

    assert_eq!(report.rows.len(), 3);
    assert_eq!(
        report.profile.as_ref().map(|profile| profile.worker),
        Some(WorkerKind::Cuda)
    );
    assert!(report.rows.iter().all(
        |row| row.outcome != BenchmarkOutcome::NotInstalled || row.worker == WorkerKind::Vulkan
    ));
    let encoded = serde_json::to_string(&report).unwrap();
    assert!(!encoded.contains(BENCHMARK_PROMPT));
    assert!(!encoded.contains("sample.wav"));
    let paths = inputs.lock().unwrap().clone();
    assert_eq!(
        paths.len(),
        8,
        "one warm-up plus three measurements per installed worker"
    );
    assert!(
        paths.iter().all(|path| !path.exists()),
        "RAII cleanup removes the WAV after completion"
    );
}

#[test]
fn cpu_fixture_failure_never_selects_an_accelerator_profile() {
    #[derive(Clone)]
    struct CpuFailure;
    impl BenchmarkRunner for CpuFailure {
        fn fixture(
            &self,
            kind: WorkerKind,
            _model: &VerifiedModel,
        ) -> Result<WorkerResult, RunnerFailure> {
            if kind == WorkerKind::Cpu {
                Err(RunnerFailure::Timeout)
            } else {
                Ok(FakeRunner::result(kind, 100))
            }
        }
        fn input(
            &self,
            kind: WorkerKind,
            _model: &VerifiedModel,
            _input: &Path,
            _dir: &Path,
        ) -> Result<WorkerResult, RunnerFailure> {
            Ok(FakeRunner::result(kind, 100))
        }
        fn installed_workers(&self) -> Vec<WorkerKind> {
            vec![WorkerKind::Cpu, WorkerKind::Cuda]
        }
    }
    let report = BenchmarkTransaction::new(
        CpuFailure,
        VerifiedModel {
            path: PathBuf::from("verified-model.bin"),
            revision: "pinned-model".to_owned(),
        },
    )
    .run(vec![1_000; 16_000])
    .expect("candidate failures are reported, not hidden");

    assert!(report.profile.is_none());
    assert_eq!(
        report
            .rows
            .iter()
            .find(|row| row.worker == WorkerKind::Cpu)
            .unwrap()
            .outcome,
        BenchmarkOutcome::Rejected
    );
}

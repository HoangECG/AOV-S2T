use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use live_subtitle_tool::audio::{capture::CaptureController, source::SourceSelection};
use live_subtitle_tool::inference::{
    runner::{RunnerFailure, VerifiedModel, WorkerDiagnostics, WorkerKind, WorkerResult},
    transaction::{BenchmarkRunner, BenchmarkTransaction},
};

#[derive(Clone)]
struct FailingRunner {
    paths: Arc<Mutex<Vec<PathBuf>>>,
    panic_after_input: bool,
}

impl BenchmarkRunner for FailingRunner {
    fn fixture(
        &self,
        kind: WorkerKind,
        _model: &VerifiedModel,
    ) -> Result<WorkerResult, RunnerFailure> {
        Ok(WorkerResult {
            backend: kind,
            worker_build: "cpu-test".to_owned(),
            model_revision: "model-test".to_owned(),
            elapsed_ms: 1,
            transcript: "fixture".to_owned(),
            exit_status: 0,
            diagnostics: WorkerDiagnostics {
                missing_hardware: None,
                driver: None,
                memory_bytes: None,
                failure_code: None,
            },
        })
    }

    fn input(
        &self,
        _kind: WorkerKind,
        _model: &VerifiedModel,
        input: &Path,
        _directory: &Path,
    ) -> Result<WorkerResult, RunnerFailure> {
        self.paths.lock().unwrap().push(input.to_owned());
        if self.panic_after_input {
            panic!("simulated worker unwind");
        }
        Err(RunnerFailure::Timeout)
    }

    fn installed_workers(&self) -> Vec<WorkerKind> {
        vec![WorkerKind::Cpu]
    }
}

fn transaction(runner: FailingRunner) -> BenchmarkTransaction<FailingRunner> {
    BenchmarkTransaction::new(
        runner,
        VerifiedModel {
            path: PathBuf::from("model.bin"),
            revision: "model-test".to_owned(),
        },
    )
}

#[test]
fn temporary_wav_is_removed_after_worker_failure() {
    let paths = Arc::new(Mutex::new(Vec::new()));
    let report = transaction(FailingRunner {
        paths: Arc::clone(&paths),
        panic_after_input: false,
    })
    .run(vec![700; 16_000])
    .expect("candidate failure is returned as evidence");

    assert!(report.profile.is_none());
    assert!(paths.lock().unwrap().iter().all(|path| !path.exists()));
}

#[test]
fn temporary_wav_is_removed_during_unwind() {
    let paths = Arc::new(Mutex::new(Vec::new()));
    let result = catch_unwind(AssertUnwindSafe(|| {
        transaction(FailingRunner {
            paths: Arc::clone(&paths),
            panic_after_input: true,
        })
        .run(vec![700; 16_000])
    }));

    assert!(result.is_err());
    assert!(paths.lock().unwrap().iter().all(|path| !path.exists()));
}

#[test]
fn invalid_sample_does_not_create_a_worker_input() {
    let paths = Arc::new(Mutex::new(Vec::new()));
    assert!(transaction(FailingRunner {
        paths: Arc::clone(&paths),
        panic_after_input: false
    })
    .run(Vec::new())
    .is_err());
    assert!(paths.lock().unwrap().is_empty());
}

#[test]
fn taking_a_rejected_sample_leaves_no_retained_pcm() {
    let capture = CaptureController::new(SourceSelection::default());
    assert!(capture.take_benchmark_sample().is_err());
    assert!(!capture.has_benchmark_sample());
}

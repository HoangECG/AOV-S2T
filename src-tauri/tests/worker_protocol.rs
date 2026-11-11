use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};

use live_subtitle_tool::inference::runner::{
    HostInfo, InferenceRunner, RunnerFailure, VerifiedModel, WorkerKind, WorkerManifest,
};
use serde_json::json;
use sha2::{Digest, Sha256};

static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);

fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn wav() -> Vec<u8> {
    let mut bytes = vec![0_u8; 44];
    bytes[0..4].copy_from_slice(b"RIFF");
    bytes[8..12].copy_from_slice(b"WAVE");
    bytes[12..16].copy_from_slice(b"fmt ");
    bytes[16..20].copy_from_slice(&16_u32.to_le_bytes());
    bytes[20..22].copy_from_slice(&1_u16.to_le_bytes());
    bytes[22..24].copy_from_slice(&1_u16.to_le_bytes());
    bytes[24..28].copy_from_slice(&16_000_u32.to_le_bytes());
    bytes[28..32].copy_from_slice(&32_000_u32.to_le_bytes());
    bytes[32..34].copy_from_slice(&2_u16.to_le_bytes());
    bytes[34..36].copy_from_slice(&16_u16.to_le_bytes());
    bytes[36..40].copy_from_slice(b"data");
    bytes
}

struct Fixture {
    root: PathBuf,
    manifest: WorkerManifest,
    model: VerifiedModel,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "worker-protocol-{}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("workers/fixtures")).unwrap();
        fs::create_dir_all(root.join("workers/out/x86_64-pc-windows-msvc/cpu")).unwrap();
        let audio = wav();
        fs::write(root.join("workers/fixtures/test.wav"), &audio).unwrap();
        let expected = json!({
            "fixtureId": "fixture-vi",
            "language": "vi",
            "spokenPhrase": "Xin Chào",
            "normalizedTranscript": "xin chào",
            "normalizer": "trim, lowercase, remove terminal ASCII sentence punctuation, collapse internal Unicode whitespace to one ASCII space",
            "expectedTranscriptSha256": sha256("xin chào".as_bytes()),
            "source": { "name": "Test recording", "sourceUrl": "https://example.test/fixture.wav", "originalFilename": "fixture.wav", "contributor": "Test contributor", "recordingDate": "2026-08-19", "license": "CC0-1.0", "licenseUrl": "https://creativecommons.org/publicdomain/zero/1.0/", "redistributionGrant": "CC0" },
            "transformation": { "tool": "test", "command": "test transform", "performedOn": "2026-08-19", "attributionRequired": false }
        });
        let expected_bytes = serde_json::to_vec(&expected).unwrap();
        fs::write(
            root.join("workers/fixtures/test.expected.json"),
            &expected_bytes,
        )
        .unwrap();
        let worker_path = root.join("workers/out/x86_64-pc-windows-msvc/cpu/fake-worker.cmd");
        fs::write(&worker_path, b"@echo off\r\necho {\"backend\":\"cpu\",\"workerBuild\":\"cpu-test\",\"modelRevision\":\"model-revision\",\"elapsedMs\":4,\"transcript\":\"Xin Chao\",\"exitStatus\":0,\"diagnostics\":{}}\r\n").unwrap();
        let worker_bytes = fs::read(&worker_path).unwrap();
        let model_path = root.join("model.bin");
        fs::write(&model_path, b"verified model").unwrap();
        let manifest = json!({
            "schemaVersion": 1,
            "packageState": "sealed",
            "releaseTarget": { "architecture": "x86_64", "supportedWindows": ["Windows 11"] },
            "source": { "repository": "https://github.com/ggml-org/whisper.cpp.git", "revision": "0123456789abcdef0123456789abcdef01234567" },
            "model": { "modelId": "test-model", "modelRevision": "model-revision", "workerCompatibility": "ggml-org/whisper.cpp@0123456789abcdef0123456789abcdef01234567" },
            "fixture": {
                "fixtureId": "fixture-vi", "audioPath": "workers/fixtures/test.wav", "audioSha256": sha256(&audio),
                "sampleRateHz": 16000, "channels": 1, "expectedAssetPath": "workers/fixtures/test.expected.json",
                "expectedAssetSha256": sha256(&expected_bytes), "expectedTranscriptSha256": sha256("xin chào".as_bytes())
            },
            "workers": [{
                "kind": "cpu", "buildId": "cpu-test", "executable": "workers/out/x86_64-pc-windows-msvc/cpu/fake-worker.cmd",
                "files": [{ "path": "workers/out/x86_64-pc-windows-msvc/cpu/fake-worker.cmd", "sha256": sha256(&worker_bytes) }],
                "sourceRevision": "0123456789abcdef0123456789abcdef01234567", "modelRevision": "model-revision", "architecture": "x86_64", "backend": "cpu"
            }]
        });
        Self {
            root,
            manifest: WorkerManifest::from_json(&serde_json::to_string(&manifest).unwrap())
                .unwrap(),
            model: VerifiedModel {
                path: model_path,
                revision: "model-revision".to_owned(),
            },
        }
    }

    fn runner(&self) -> InferenceRunner {
        InferenceRunner::new(
            self.root.clone(),
            self.manifest.clone(),
            HostInfo {
                architecture: "x86_64".to_owned(),
                windows_supported: true,
            },
        )
    }

    fn write_runtime_inventory(&self, package_state: &str) {
        let path = self
            .root
            .join("workers/out/x86_64-pc-windows-msvc/manifest.json");
        let mut inventory = serde_json::to_value(&self.manifest).unwrap();
        inventory["packageState"] = json!(package_state);
        fs::write(path, serde_json::to_vec(&inventory).unwrap()).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn only_fixed_manifest_listed_checksums_architecture_and_model_may_launch() {
    let fixture = Fixture::new();
    assert!(fixture
        .runner()
        .preflight(WorkerKind::Cpu, &fixture.model)
        .is_ok());

    let mut wrong_hash = fixture.manifest.clone();
    wrong_hash.workers[0].files[0].sha256 = "0".repeat(64);
    assert_eq!(
        InferenceRunner::new(fixture.root.clone(), wrong_hash, HostInfo::supported_x64())
            .preflight(WorkerKind::Cpu, &fixture.model)
            .unwrap_err(),
        RunnerFailure::InventoryChecksum
    );

    let wrong_model = VerifiedModel {
        revision: "other".to_owned(),
        ..fixture.model.clone()
    };
    assert!(matches!(
        fixture.runner().preflight(WorkerKind::Cpu, &wrong_model),
        Err(RunnerFailure::ModelRevision)
    ));
    assert!(matches!(
        InferenceRunner::new(
            fixture.root.clone(),
            fixture.manifest.clone(),
            HostInfo {
                architecture: "aarch64".to_owned(),
                windows_supported: true
            }
        )
        .preflight(WorkerKind::Cpu, &fixture.model),
        Err(RunnerFailure::HostArchitecture)
    ));
}

#[test]
fn strict_protocol_rejects_untrusted_or_invalid_worker_output() {
    let fixture = Fixture::new();
    let runner = fixture.runner();
    for output in [
        b"not json".as_slice(),
        br#"{"backend":"cpu","workerBuild":"cpu-test","modelRevision":"model-revision","elapsedMs":-1,"transcript":"xin chao","exitStatus":0,"diagnostics":{}}"#,
        br#"{"backend":"cpu","workerBuild":"cpu-test","modelRevision":"model-revision","elapsedMs":1,"transcript":"xin chao","exitStatus":0,"diagnostics":{},"path":"C:\\evil.exe"}"#,
        br#"{"backend":"cpu","workerBuild":"cpu-test","modelRevision":"wrong","elapsedMs":1,"transcript":"xin chao","exitStatus":0,"diagnostics":{}}"#,
    ] {
        assert!(runner.parse_result(WorkerKind::Cpu, output, 0).is_err());
    }
    assert!(matches!(
        runner.parse_result(WorkerKind::Cpu, &vec![b'x'; 65_537], 0),
        Err(RunnerFailure::OutputTooLarge)
    ));
    assert!(matches!(runner.parse_result(WorkerKind::Cpu, br#"{"backend":"cpu","workerBuild":"cpu-test","modelRevision":"model-revision","elapsedMs":1,"transcript":"xin chao","exitStatus":0,"diagnostics":{}}"#, 1), Err(RunnerFailure::NonZeroExit(1))));
}

#[test]
fn fixture_self_test_requires_exact_normalized_transcript_and_keeps_it_out_of_diagnostics() {
    let fixture = Fixture::new();
    let runner = fixture.runner();
    let pass = "{\"backend\":\"cpu\",\"workerBuild\":\"cpu-test\",\"modelRevision\":\"model-revision\",\"elapsedMs\":1,\"transcript\":\"  XIN CHÀO  \",\"exitStatus\":0,\"diagnostics\":{}}";
    assert!(runner
        .self_test(WorkerKind::Cpu, &fixture.model, pass.as_bytes(), 0)
        .is_ok());

    let mismatch = br#"{"backend":"cpu","workerBuild":"cpu-test","modelRevision":"model-revision","elapsedMs":1,"transcript":"xin tam biet","exitStatus":0,"diagnostics":{}}"#;
    assert!(matches!(
        runner.self_test(WorkerKind::Cpu, &fixture.model, mismatch, 0),
        Err(RunnerFailure::TranscriptMismatch { .. })
    ));

    let empty = br#"{"backend":"cpu","workerBuild":"cpu-test","modelRevision":"model-revision","elapsedMs":1,"transcript":" ","exitStatus":0,"diagnostics":{}}"#;
    assert!(matches!(
        runner.self_test(WorkerKind::Cpu, &fixture.model, empty, 0),
        Err(RunnerFailure::EmptyTranscript)
    ));
}

#[test]
fn bundled_worker_manifest_is_parseable_but_not_admitted_before_a_sealed_release_build() {
    let manifest = WorkerManifest::from_json(include_str!("../../workers/manifest.json")).unwrap();
    assert_eq!(manifest.package_state, "build-required");
    assert_eq!(manifest.workers.len(), 3);
}

#[test]
fn runtime_admission_reads_only_the_generated_sealed_inventory() {
    let fixture = Fixture::new();
    fs::write(
        fixture.root.join("workers/manifest.json"),
        include_str!("../../workers/manifest.json"),
    )
    .unwrap();

    assert_eq!(
        InferenceRunner::from_runtime_inventory(fixture.root.clone(), HostInfo::supported_x64())
            .unwrap_err(),
        RunnerFailure::WorkerNotSealed
    );

    fixture.write_runtime_inventory("build-required");
    assert_eq!(
        InferenceRunner::from_runtime_inventory(fixture.root.clone(), HostInfo::supported_x64())
            .unwrap_err(),
        RunnerFailure::WorkerNotSealed
    );

    fixture.write_runtime_inventory("sealed");
    let runner =
        InferenceRunner::from_runtime_inventory(fixture.root.clone(), HostInfo::supported_x64())
            .unwrap();
    assert!(runner.preflight(WorkerKind::Cpu, &fixture.model).is_ok());
    assert_eq!(
        runner
            .preflight(WorkerKind::Cuda, &fixture.model)
            .unwrap_err(),
        RunnerFailure::WorkerNotPresent(WorkerKind::Cuda)
    );
}

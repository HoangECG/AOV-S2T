use std::fs;

use live_subtitle_tool::inference::{
    download::{status_for_paths, temporary_path, verify_file, InstallError},
    manifest::{ManifestError, ModelManifest},
    ModelInstallState,
};
use sha2::{Digest, Sha256};

fn manifest() -> ModelManifest {
    serde_json::from_str(include_str!("../resources/model-manifest.json")).unwrap()
}

#[test]
fn immutable_manifest_rejects_untrusted_or_incomplete_phowhisper_sources() {
    let valid = manifest();
    assert!(valid.validate().is_ok());

    let mut invalid = valid.clone();
    invalid.source.repository = "example.invalid/PhoWhisper-large".to_owned();
    assert!(matches!(invalid.validate(), Err(ManifestError::Source(_))));

    let mut invalid = valid.clone();
    invalid.source.revision = "main".to_owned();
    assert!(matches!(invalid.validate(), Err(ManifestError::Revision)));

    let mut invalid = valid.clone();
    invalid.source.files.clear();
    assert!(matches!(invalid.validate(), Err(ManifestError::Source(_))));
}

#[test]
fn wrong_size_or_checksum_never_verifies_a_local_artifact() {
    let root = std::env::temp_dir().join(format!("manifest-test-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    let temporary = root.join("ggml-phowhisper-large.bin.part");
    let final_path = root.join("ggml-phowhisper-large.bin");
    fs::write(&temporary, b"partial model").unwrap();

    let error = verify_file(&temporary, 100, "00").unwrap_err();
    assert!(matches!(
        error,
        InstallError::Size {
            expected: 100,
            actual: 13
        }
    ));
    assert!(!final_path.exists());

    let expected_hash = format!("{:x}", Sha256::digest(b"verified model"));
    fs::write(&temporary, b"verified model").unwrap();
    verify_file(&temporary, 14, &expected_hash).unwrap();
    assert_eq!(fs::read(&temporary).unwrap(), b"verified model");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn incomplete_local_preparation_is_explicitly_not_ready() {
    let root = std::env::temp_dir().join(format!("manifest-incomplete-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    let model = manifest();
    let final_path = root.join(&model.artifact_name);
    fs::write(temporary_path(&final_path), b"partial").unwrap();

    assert_eq!(
        status_for_paths(&model, &final_path),
        ModelInstallState::Failed {
            check: "incomplete-file".to_owned(),
            detail: "Tệp GGML được chuẩn bị cục bộ trước đó chưa hoàn tất; tệp này chưa được dùng."
                .to_owned(),
            retryable: true,
        }
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn different_revision_requires_confirmation_and_keeps_known_good_model() {
    let installed = manifest();
    let mut candidate = installed.clone();
    candidate.revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned();

    assert_eq!(
        installed.update_state(&candidate),
        ModelInstallState::UpdateRequiresConfirmation {
            installed_revision: installed.revision,
            candidate_revision: candidate.revision,
        }
    );
}

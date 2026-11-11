use std::{
    fs,
    fs::File,
    io::{self, Read},
    path::{Path, PathBuf},
};

use serde::Serialize;
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Manager};

use super::{
    manifest::{bundled_manifest, ManifestError, ModelManifest},
    ModelInstallState,
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInstallStatus {
    pub manifest: ModelManifest,
    pub state: ModelInstallState,
    pub destination: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InstallError {
    Manifest(String),
    Incomplete,
    Size { expected: u64, actual: u64 },
    Checksum,
    Io(String),
}

impl InstallError {
    pub fn ui_detail(&self) -> (String, String, bool) {
        match self {
            Self::Manifest(detail) => ("manifest".to_owned(), detail.clone(), false),
            Self::Incomplete => (
                "incomplete-file".to_owned(),
                "Tệp GGML được chuẩn bị cục bộ trước đó chưa hoàn tất; tệp này chưa được dùng."
                    .to_owned(),
                true,
            ),
            Self::Size { expected, actual } => (
                "file-size".to_owned(),
                format!("Kích thước tệp không khớp: cần {expected} byte, nhận {actual} byte."),
                true,
            ),
            Self::Checksum => (
                "checksum".to_owned(),
                "SHA-256 của tệp GGML không khớp manifest PhoWhisper.".to_owned(),
                true,
            ),
            Self::Io(detail) => ("storage".to_owned(), detail.clone(), true),
        }
    }
}

impl From<io::Error> for InstallError {
    fn from(error: io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

impl From<ManifestError> for InstallError {
    fn from(error: ManifestError) -> Self {
        Self::Manifest(error.to_string())
    }
}

pub fn verify_file(
    path: &Path,
    expected_bytes: u64,
    expected_sha256: &str,
) -> Result<(), InstallError> {
    let actual = fs::metadata(path)?.len();
    if actual != expected_bytes {
        return Err(InstallError::Size {
            expected: expected_bytes,
            actual,
        });
    }
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    if format!("{:x}", hasher.finalize()) != expected_sha256.to_ascii_lowercase() {
        return Err(InstallError::Checksum);
    }
    Ok(())
}

pub fn destination_for(app: &AppHandle, manifest: &ModelManifest) -> Result<PathBuf, InstallError> {
    let root = app
        .path()
        .app_local_data_dir()
        .map_err(|error| InstallError::Io(error.to_string()))?;
    Ok(root
        .join("models")
        .join(&manifest.model_id)
        .join(&manifest.revision)
        .join(&manifest.artifact_name))
}

pub fn status(app: &AppHandle) -> ModelInstallState {
    let manifest = match bundled_manifest() {
        Ok(manifest) => manifest,
        Err(error) => return ModelInstallState::failed(error.into()),
    };
    let destination = match destination_for(app, &manifest) {
        Ok(destination) => destination,
        Err(error) => return ModelInstallState::failed(error),
    };
    status_for_paths(&manifest, &destination)
}

pub fn status_for_paths(manifest: &ModelManifest, destination: &Path) -> ModelInstallState {
    if !destination.exists() {
        return if temporary_path(destination).exists() {
            ModelInstallState::failed(InstallError::Incomplete)
        } else {
            ModelInstallState::Absent
        };
    }
    match verify_file(destination, manifest.expected_bytes, &manifest.sha256) {
        Ok(()) => ModelInstallState::Ready,
        Err(error) => ModelInstallState::failed(error),
    }
}

pub fn status_info(app: &AppHandle) -> Result<ModelInstallStatus, InstallError> {
    let manifest = bundled_manifest()?;
    let destination = destination_for(app, &manifest)?;
    Ok(ModelInstallStatus {
        state: status(app),
        manifest,
        destination: destination.to_string_lossy().into_owned(),
    })
}

pub fn temporary_path(destination: &Path) -> PathBuf {
    let file_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("model.bin");
    destination.with_file_name(format!("{file_name}.part"))
}

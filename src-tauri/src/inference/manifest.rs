use serde::{Deserialize, Serialize};

use super::ModelInstallState;

const MODEL_ID: &str = "ggml-phowhisper-large";
const ARTIFACT_NAME: &str = "ggml-phowhisper-large.bin";
const INSTALLATION_MODE: &str = "local-conversion";
const SOURCE_REPOSITORY: &str = "vinai/PhoWhisper-large";
const SOURCE_CHECKPOINT: &str = "pytorch_model.bin";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSourceFile {
    pub name: String,
    pub expected_bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSource {
    pub repository: String,
    pub revision: String,
    pub checkpoint: String,
    pub files: Vec<ModelSourceFile>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelManifest {
    pub model_id: String,
    pub revision: String,
    pub artifact_name: String,
    pub expected_bytes: u64,
    pub sha256: String,
    pub format: String,
    pub installation_mode: String,
    pub source: ModelSource,
    pub worker_compatibility: String,
    pub license: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ManifestError {
    Source(String),
    Revision,
    Identity(&'static str),
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Source(detail) => write!(formatter, "unapproved model source: {detail}"),
            Self::Revision => {
                formatter.write_str("model revision must be a pinned 40-character commit")
            }
            Self::Identity(detail) => formatter.write_str(detail),
        }
    }
}

impl std::error::Error for ManifestError {}

impl ModelManifest {
    pub fn validate(&self) -> Result<(), ManifestError> {
        if !valid_revision(&self.revision) || !valid_revision(&self.source.revision) {
            return Err(ManifestError::Revision);
        }
        if self.source.repository != SOURCE_REPOSITORY
            || self.source.revision != self.revision
            || self.source.checkpoint != SOURCE_CHECKPOINT
        {
            return Err(ManifestError::Source(self.source.repository.clone()));
        }
        if self.model_id != MODEL_ID
            || self.artifact_name != ARTIFACT_NAME
            || self.expected_bytes == 0
            || !valid_sha256(&self.sha256)
        {
            return Err(ManifestError::Identity(
                "model manifest identity is incomplete",
            ));
        }
        if self.source.files.is_empty()
            || !self.source.files.iter().any(|file| {
                file.name == SOURCE_CHECKPOINT
                    && file.expected_bytes > 0
                    && valid_sha256(&file.sha256)
            })
            || self.source.files.iter().any(|file| {
                file.name.is_empty()
                    || file.name.contains(['/', '\\'])
                    || file.expected_bytes == 0
                    || !valid_sha256(&file.sha256)
            })
        {
            return Err(ManifestError::Source(
                "source checkpoint files are incomplete".to_owned(),
            ));
        }
        if self.format != "GGML"
            || self.installation_mode != INSTALLATION_MODE
            || self.worker_compatibility.is_empty()
            || self.license != "BSD-3-Clause"
        {
            return Err(ManifestError::Identity(
                "model manifest compatibility or license is missing",
            ));
        }
        Ok(())
    }

    pub fn update_state(&self, candidate: &Self) -> ModelInstallState {
        if self.revision == candidate.revision {
            ModelInstallState::Ready
        } else {
            ModelInstallState::UpdateRequiresConfirmation {
                installed_revision: self.revision.clone(),
                candidate_revision: candidate.revision.clone(),
            }
        }
    }
}

pub fn bundled_manifest() -> Result<ModelManifest, ManifestError> {
    let manifest: ModelManifest =
        serde_json::from_str(include_str!("../../resources/model-manifest.json"))
            .map_err(|_| ManifestError::Identity("bundled model manifest is malformed"))?;
    manifest.validate()?;
    Ok(manifest)
}

fn valid_revision(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

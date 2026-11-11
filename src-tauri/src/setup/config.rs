use std::{
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

use crate::audio::source::SelectedSource;
use crate::inference::benchmark::InferenceProfile;

use super::state::CandidateSetup;

pub const CONFIG_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelReference {
    pub model_id: String,
    pub revision: String,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileEvidence {
    pub backend: String,
    pub worker_build: String,
    pub hardware_fingerprint: String,
    pub rtf: f32,
    pub p95_ms: u64,
    pub fixture_id: String,
    pub fixture_audio_sha256: String,
    pub fixture_expected_sha256: String,
}

impl ProfileEvidence {
    pub fn test_profile() -> Self {
        Self {
            backend: "cpu".to_owned(),
            worker_build: "sealed-test-worker".to_owned(),
            hardware_fingerprint: "known-target".to_owned(),
            rtf: 0.5,
            p95_ms: 1_000,
            fixture_id: "immutable-self-test".to_owned(),
            fixture_audio_sha256: "fixture-audio".to_owned(),
            fixture_expected_sha256: "fixture-expectation".to_owned(),
        }
    }

    pub fn from_inference_profile(profile: &InferenceProfile) -> Self {
        Self {
            backend: format!("{:?}", profile.worker),
            worker_build: profile.worker_build.clone(),
            hardware_fingerprint: profile.hardware_fingerprint.clone(),
            rtf: profile.rtf,
            p95_ms: profile.p95_ms,
            fixture_id: profile.fixture.fixture_id.clone(),
            fixture_audio_sha256: profile.fixture.audio_sha256.clone(),
            fixture_expected_sha256: profile.fixture.expected_transcript_sha256.clone(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownGoodConfig {
    pub schema_version: u32,
    pub model: ModelReference,
    pub profile: ProfileEvidence,
    pub official_source: SelectedSource,
    pub committed_at: String,
}

#[derive(Debug, Eq, PartialEq)]
pub enum SetupConfigError {
    Incomplete,
    Io,
    Serialization,
    Validation,
}

impl std::fmt::Display for SetupConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Incomplete => "setup predicates are incomplete",
            Self::Io => "could not write the setup configuration",
            Self::Serialization => "could not serialize the setup configuration",
            Self::Validation => "temporary setup configuration did not validate",
        })
    }
}
impl std::error::Error for SetupConfigError {}

impl KnownGoodConfig {
    pub fn from_candidate(candidate: &CandidateSetup) -> Result<Self, SetupConfigError> {
        if !candidate.is_ready() {
            return Err(SetupConfigError::Incomplete);
        }
        Ok(Self {
            schema_version: CONFIG_SCHEMA_VERSION,
            model: candidate
                .model
                .clone()
                .expect("ready candidate has a model"),
            profile: candidate
                .profile
                .clone()
                .expect("ready candidate has a profile"),
            official_source: candidate
                .official_source
                .clone()
                .expect("ready candidate has a source"),
            committed_at: "local-setup".to_owned(),
        })
    }

    pub fn validate(&self) -> Result<(), SetupConfigError> {
        if self.schema_version != CONFIG_SCHEMA_VERSION
            || !valid_text(&self.model.model_id)
            || !valid_hex(&self.model.revision, 40)
            || !valid_hex(&self.model.sha256, 64)
            || !valid_text(&self.profile.backend)
            || !valid_text(&self.profile.worker_build)
            || !valid_text(&self.profile.hardware_fingerprint)
            || !self.profile.rtf.is_finite()
            || self.profile.rtf < 0.0
            || self.profile.p95_ms == 0
            || !valid_text(&self.profile.fixture_id)
            || !valid_text(&self.profile.fixture_audio_sha256)
            || !valid_text(&self.profile.fixture_expected_sha256)
            || !valid_text(&self.official_source.endpoint_id)
            || !valid_text(&self.official_source.display_name)
            || !valid_text(&self.committed_at)
        {
            return Err(SetupConfigError::Validation);
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct SetupConfigStore {
    path: PathBuf,
}

impl SetupConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Invalid saved data is never repaired or replaced during load. The caller can require
    /// setup again while preserving the bytes for inspection and recovery.
    pub fn load(&self) -> Result<Option<KnownGoodConfig>, SetupConfigError> {
        if !self.path.exists() {
            return Ok(None);
        }
        let config: KnownGoodConfig =
            serde_json::from_slice(&fs::read(&self.path).map_err(|_| SetupConfigError::Io)?)
                .map_err(|_| SetupConfigError::Validation)?;
        config.validate()?;
        Ok(Some(config))
    }

    pub fn commit_candidate(
        &self,
        candidate: &CandidateSetup,
    ) -> Result<KnownGoodConfig, SetupConfigError> {
        let config = KnownGoodConfig::from_candidate(candidate)?;
        config.validate()?;
        let bytes =
            serde_json::to_vec_pretty(&config).map_err(|_| SetupConfigError::Serialization)?;
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|_| SetupConfigError::Io)?;
        }
        let temporary = self.path.with_extension("tmp");
        let mut file = File::create(&temporary).map_err(|_| SetupConfigError::Io)?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| SetupConfigError::Io)?;
        let decoded: KnownGoodConfig =
            serde_json::from_slice(&fs::read(&temporary).map_err(|_| SetupConfigError::Io)?)
                .map_err(|_| SetupConfigError::Validation)?;
        decoded.validate()?;
        fs::rename(&temporary, &self.path).map_err(|_| SetupConfigError::Io)?;
        Ok(config)
    }
}

fn valid_text(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 256
}

fn valid_hex(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::{audio::source::SelectedSource, inference::benchmark::InferenceProfile};

use super::config::{
    KnownGoodConfig, ModelReference, ProfileEvidence, SetupConfigError, SetupConfigStore,
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SetupStep {
    Model,
    BenchmarkSample,
    Benchmark,
    OfficialSource,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum SetupState {
    Empty,
    Wizard(SetupStep),
    ConfirmationRequired,
    Ready,
}

#[derive(Clone, Debug, Default)]
pub struct ReadinessEvidence {
    pub model_current: bool,
    pub profile_current: bool,
    pub fixture_identity_current: bool,
    pub fixture_transcript_matches: bool,
    pub source_signal_current: bool,
    pub official_caption_complete: bool,
}

impl ReadinessEvidence {
    pub fn passing() -> Self {
        Self {
            model_current: true,
            profile_current: true,
            fixture_identity_current: true,
            fixture_transcript_matches: true,
            source_signal_current: true,
            official_caption_complete: true,
        }
    }
    fn all_current(&self) -> bool {
        self.model_current
            && self.profile_current
            && self.fixture_identity_current
            && self.fixture_transcript_matches
            && self.source_signal_current
            && self.official_caption_complete
    }
}

#[derive(Clone, Debug, Default)]
pub struct CandidateSetup {
    pub model: Option<ModelReference>,
    pub temporary_sample_id: Option<String>,
    pub profile: Option<ProfileEvidence>,
    pub official_source: Option<SelectedSource>,
    pub evidence: ReadinessEvidence,
}

impl CandidateSetup {
    pub fn is_ready(&self) -> bool {
        self.model.is_some()
            && self.profile.is_some()
            && self.official_source.is_some()
            && self.evidence.all_current()
    }
}

#[derive(Clone, Debug)]
pub struct SetupMachine {
    known_good: Option<KnownGoodConfig>,
    candidate: CandidateSetup,
    state: SetupState,
}

impl SetupMachine {
    pub fn new() -> Self {
        Self {
            known_good: None,
            candidate: CandidateSetup::default(),
            state: SetupState::Wizard(SetupStep::Model),
        }
    }
    pub fn with_known_good(config: KnownGoodConfig) -> Self {
        Self {
            known_good: Some(config),
            candidate: CandidateSetup::default(),
            state: SetupState::Ready,
        }
    }
    pub fn state(&self) -> SetupState {
        self.state.clone()
    }
    pub fn current_step_and_can_complete(&self) -> (Option<SetupStep>, bool) {
        let current_step = match &self.state {
            SetupState::Wizard(step) => Some(*step),
            _ => None,
        };
        (
            current_step,
            matches!(&self.state, SetupState::Wizard(SetupStep::OfficialSource))
                && self.candidate.is_ready(),
        )
    }
    pub fn known_good(&self) -> Option<&KnownGoodConfig> {
        self.known_good.as_ref()
    }
    pub fn candidate_mut(&mut self) -> &mut CandidateSetup {
        &mut self.candidate
    }

    /// These transitions are called only by native collaborators after they have produced their
    /// own evidence. They intentionally accept no UI-provided flags or readiness values.
    pub fn accept_verified_model(&mut self, model: ModelReference) -> Result<(), SetupConfigError> {
        if !matches!(self.state, SetupState::Wizard(SetupStep::Model)) {
            return Err(SetupConfigError::Incomplete);
        }
        self.candidate.model = Some(model);
        self.advance()
    }

    pub fn accept_temporary_sample(&mut self) -> Result<(), SetupConfigError> {
        if !matches!(self.state, SetupState::Wizard(SetupStep::BenchmarkSample)) {
            return Err(SetupConfigError::Incomplete);
        }
        self.candidate.temporary_sample_id = Some("native-retained-sample".to_owned());
        self.advance()
    }

    pub fn accept_measured_profile(
        &mut self,
        profile: &InferenceProfile,
    ) -> Result<(), SetupConfigError> {
        if !matches!(self.state, SetupState::Wizard(SetupStep::Benchmark))
            || self
                .candidate
                .model
                .as_ref()
                .is_none_or(|model| model.revision != profile.model_revision)
            || profile.correctness < crate::inference::benchmark::MIN_CORRECTNESS
        {
            return Err(SetupConfigError::Incomplete);
        }
        self.candidate.profile = Some(ProfileEvidence::from_inference_profile(profile));
        self.advance()
    }

    pub fn accept_official_source(
        &mut self,
        source: SelectedSource,
    ) -> Result<(), SetupConfigError> {
        if !matches!(self.state, SetupState::Wizard(SetupStep::OfficialSource))
            || source.endpoint_id.trim().is_empty()
        {
            return Err(SetupConfigError::Incomplete);
        }
        self.candidate.official_source = Some(source);
        Ok(())
    }

    pub fn record_official_signal(&mut self, signal_present: bool) -> Result<(), SetupConfigError> {
        if !matches!(self.state, SetupState::Wizard(SetupStep::OfficialSource))
            || self.candidate.official_source.is_none()
            || !signal_present
        {
            return Err(SetupConfigError::Incomplete);
        }
        self.candidate.evidence.source_signal_current = true;
        Ok(())
    }

    pub fn record_official_caption(&mut self, completed: bool) -> Result<(), SetupConfigError> {
        if !matches!(self.state, SetupState::Wizard(SetupStep::OfficialSource))
            || !self.candidate.evidence.source_signal_current
            || !completed
        {
            return Err(SetupConfigError::Incomplete);
        }
        self.candidate.evidence.model_current = true;
        self.candidate.evidence.profile_current = true;
        self.candidate.evidence.fixture_identity_current = true;
        self.candidate.evidence.fixture_transcript_matches = true;
        self.candidate.evidence.official_caption_complete = true;
        Ok(())
    }
    pub fn begin_reconfiguration(&mut self, step: SetupStep) {
        self.candidate = CandidateSetup::default();
        if let Some(config) = &self.known_good {
            if !matches!(step, SetupStep::Model) {
                self.candidate.model = Some(config.model.clone());
            }
            if matches!(step, SetupStep::OfficialSource) {
                self.candidate.profile = Some(config.profile.clone());
            }
        }
        self.state = SetupState::Wizard(step);
    }
    pub fn advance(&mut self) -> Result<(), SetupConfigError> {
        let next = match self.state {
            SetupState::Wizard(SetupStep::Model) if self.candidate.model.is_some() => {
                SetupStep::BenchmarkSample
            }
            SetupState::Wizard(SetupStep::BenchmarkSample)
                if self.candidate.temporary_sample_id.is_some() =>
            {
                SetupStep::Benchmark
            }
            SetupState::Wizard(SetupStep::Benchmark) if self.candidate.profile.is_some() => {
                SetupStep::OfficialSource
            }
            _ => return Err(SetupConfigError::Incomplete),
        };
        self.state = SetupState::Wizard(next);
        Ok(())
    }
    pub fn check_launch(&mut self, current_fingerprint: &str, evidence: &ReadinessEvidence) {
        let Some(config) = self.known_good.as_ref() else {
            self.state = SetupState::Wizard(SetupStep::Model);
            return;
        };
        if config.profile.hardware_fingerprint != current_fingerprint {
            self.state = SetupState::ConfirmationRequired;
        } else if !evidence.model_current {
            self.state = SetupState::Wizard(SetupStep::Model);
        } else if !evidence.profile_current
            || !evidence.fixture_identity_current
            || !evidence.fixture_transcript_matches
        {
            self.state = SetupState::Wizard(SetupStep::Benchmark);
        } else {
            self.state = SetupState::Ready;
        }
    }
    pub fn cancel(&mut self) {
        self.candidate = CandidateSetup::default();
        self.state = if self.known_good.is_some() {
            SetupState::Ready
        } else {
            SetupState::Empty
        };
    }
    pub fn commit(&mut self, store: &SetupConfigStore) -> Result<(), SetupConfigError> {
        let config = store.commit_candidate(&self.candidate)?;
        self.known_good = Some(config);
        self.candidate = CandidateSetup::default();
        self.state = SetupState::Ready;
        Ok(())
    }
}

pub struct SetupController {
    machine: Mutex<SetupMachine>,
    launch_evidence: Mutex<ReadinessEvidence>,
    store: SetupConfigStore,
    retained_profile: Mutex<Option<InferenceProfile>>,
}

impl Default for SetupController {
    fn default() -> Self {
        Self::new(SetupConfigStore::new(
            std::env::temp_dir().join("live-subtitle-tool-setup.json"),
        ))
    }
}

impl SetupController {
    pub fn new(store: SetupConfigStore) -> Self {
        Self {
            machine: Mutex::new(SetupMachine::new()),
            launch_evidence: Mutex::new(ReadinessEvidence::default()),
            store,
            retained_profile: Mutex::new(None),
        }
    }

    pub fn from_store(store: &SetupConfigStore) -> Result<Self, SetupConfigError> {
        let machine = match store.load()? {
            Some(config) => SetupMachine::with_known_good(config),
            None => SetupMachine::new(),
        };
        Ok(Self {
            machine: Mutex::new(machine),
            launch_evidence: Mutex::new(ReadinessEvidence::default()),
            store: store.clone(),
            retained_profile: Mutex::new(None),
        })
    }
    pub fn begin_reconfiguration(&self, step: SetupStep) {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .begin_reconfiguration(step);
    }
    pub fn cancel(&self) {
        self.machine.lock().expect("setup state poisoned").cancel();
        *self
            .retained_profile
            .lock()
            .expect("benchmark profile poisoned") = None;
    }
    pub fn state(&self) -> SetupState {
        self.machine.lock().expect("setup state poisoned").state()
    }
    pub fn current_step_and_can_complete(&self) -> (Option<SetupStep>, bool) {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .current_step_and_can_complete()
    }
    pub fn known_good(&self) -> Option<KnownGoodConfig> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .known_good()
            .cloned()
    }
    pub fn launch_evidence(&self) -> ReadinessEvidence {
        self.launch_evidence
            .lock()
            .expect("setup evidence poisoned")
            .clone()
    }
    pub fn set_launch_evidence(&self, evidence: ReadinessEvidence) {
        *self
            .launch_evidence
            .lock()
            .expect("setup evidence poisoned") = evidence;
    }
    pub fn revalidate_loaded(
        &self,
        current_fingerprint: &str,
        mut evidence: ReadinessEvidence,
        source_available: bool,
    ) -> SetupState {
        // A persisted one-shot/signal is evidence of the committed source check, not a reason to
        // capture again. It remains valid only while the exact endpoint is still available.
        evidence.source_signal_current = source_available;
        evidence.official_caption_complete = source_available;
        let mut machine = self.machine.lock().expect("setup state poisoned");
        machine.check_launch(current_fingerprint, &evidence);
        *self
            .launch_evidence
            .lock()
            .expect("setup evidence poisoned") = evidence;
        machine.state()
    }

    pub fn accept_verified_model(&self, model: ModelReference) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .accept_verified_model(model)
    }
    pub fn accept_temporary_sample(&self) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .accept_temporary_sample()
    }
    pub fn accept_measured_profile(
        &self,
        profile: &InferenceProfile,
    ) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .accept_measured_profile(profile)
    }
    pub fn retain_measured_profile(&self, profile: InferenceProfile) {
        *self
            .retained_profile
            .lock()
            .expect("benchmark profile poisoned") = Some(profile);
    }
    pub fn accept_retained_profile(&self) -> Result<(), SetupConfigError> {
        let profile = self
            .retained_profile
            .lock()
            .expect("benchmark profile poisoned")
            .clone()
            .ok_or(SetupConfigError::Incomplete)?;
        self.accept_measured_profile(&profile)
    }
    pub fn accept_official_source(&self, source: SelectedSource) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .accept_official_source(source)
    }
    pub fn record_official_signal(&self, signal_present: bool) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .record_official_signal(signal_present)
    }
    pub fn record_official_caption(&self, completed: bool) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .record_official_caption(completed)
    }
    pub fn selected_profile(&self) -> Option<InferenceProfile> {
        if let Some(profile) = self
            .retained_profile
            .lock()
            .expect("benchmark profile poisoned")
            .clone()
        {
            return Some(profile);
        }
        let machine = self.machine.lock().expect("setup state poisoned");
        let profile = machine
            .candidate
            .profile
            .as_ref()
            .or_else(|| machine.known_good.as_ref().map(|config| &config.profile))?;
        let worker = match profile.backend.to_ascii_lowercase().as_str() {
            "cpu" => crate::inference::runner::WorkerKind::Cpu,
            "cuda" => crate::inference::runner::WorkerKind::Cuda,
            "vulkan" => crate::inference::runner::WorkerKind::Vulkan,
            _ => return None,
        };
        Some(InferenceProfile {
            worker,
            worker_build: profile.worker_build.clone(),
            model_revision: machine
                .candidate
                .model
                .as_ref()
                .or_else(|| machine.known_good.as_ref().map(|config| &config.model))?
                .revision
                .clone(),
            hardware_fingerprint: profile.hardware_fingerprint.clone(),
            rtf: profile.rtf,
            p95_ms: profile.p95_ms,
            correctness: crate::inference::benchmark::MIN_CORRECTNESS,
            fixture: crate::inference::benchmark::FixtureEvidence {
                fixture_id: profile.fixture_id.clone(),
                audio_sha256: profile.fixture_audio_sha256.clone(),
                expected_transcript_sha256: profile.fixture_expected_sha256.clone(),
                passed_at: "persisted-known-good".to_owned(),
            },
        })
    }
    pub fn commit(&self) -> Result<(), SetupConfigError> {
        self.machine
            .lock()
            .expect("setup state poisoned")
            .commit(&self.store)
    }
}

use serde::Serialize;

use crate::{
    audio::source::{CaptureState, SelectedSource, SourceKind},
    setup::{config::KnownGoodConfig, state::ReadinessEvidence},
};

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticSnapshot {
    pub model_id: Option<String>,
    pub model_revision: Option<String>,
    pub model_checksum_state: Option<String>,
    pub backend: Option<String>,
    pub worker_build: Option<String>,
    pub hardware_fingerprint: Option<String>,
    pub gpu_name: Option<String>,
    pub ram_bytes: Option<u64>,
    pub vram_bytes: Option<u64>,
    pub driver: Option<String>,
    pub benchmark_timestamp: Option<String>,
    pub rtf: Option<f32>,
    pub p95_ms: Option<u64>,
}

impl DiagnosticSnapshot {
    pub fn empty() -> Self {
        Self {
            model_id: None,
            model_revision: None,
            model_checksum_state: None,
            backend: None,
            worker_build: None,
            hardware_fingerprint: None,
            gpu_name: None,
            ram_bytes: None,
            vram_bytes: None,
            driver: None,
            benchmark_timestamp: None,
            rtf: None,
            p95_ms: None,
        }
    }
    fn from_config(config: &KnownGoodConfig) -> Self {
        Self {
            model_id: Some(bound(&config.model.model_id)),
            model_revision: Some(bound(&config.model.revision)),
            model_checksum_state: Some("Đã xác minh".to_owned()),
            backend: Some(bound(&config.profile.backend)),
            worker_build: Some(bound(&config.profile.worker_build)),
            hardware_fingerprint: Some(bound(&config.profile.hardware_fingerprint)),
            gpu_name: None,
            ram_bytes: None,
            vram_bytes: None,
            driver: None,
            benchmark_timestamp: Some(bound(&config.committed_at)),
            rtf: Some(config.profile.rtf),
            p95_ms: Some(config.profile.p95_ms),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDiagnostic {
    pub kind: String,
    pub display_name: String,
    pub endpoint_id: String,
    pub endpoint_status: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReadinessState {
    Ready,
    SetupRequired,
    ConfirmationRequired,
    SourceUnavailable,
    Blocked,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessSnapshot {
    pub state: ReadinessState,
    pub source: Option<SourceDiagnostic>,
    pub blocking_checks: Vec<String>,
    pub diagnostics: DiagnosticSnapshot,
}

pub struct ReadinessInputs {
    pub config: Option<KnownGoodConfig>,
    pub evidence: ReadinessEvidence,
    pub capture: CaptureState,
    pub diagnostics: DiagnosticSnapshot,
}

impl ReadinessSnapshot {
    pub fn assess(inputs: ReadinessInputs) -> Self {
        let Some(config) = inputs.config else {
            return Self {
                state: ReadinessState::SetupRequired,
                source: None,
                blocking_checks: vec!["Chưa có cấu hình sẵn sàng".to_owned()],
                diagnostics: inputs.diagnostics,
            };
        };
        let source = source_snapshot(&config.official_source, &inputs.capture);
        if matches!(inputs.capture, CaptureState::Unavailable { .. }) {
            return Self {
                state: ReadinessState::SourceUnavailable,
                source: Some(source),
                blocking_checks: vec!["Nguồn không khả dụng".to_owned()],
                diagnostics: DiagnosticSnapshot::from_config(&config),
            };
        }
        let mut blocking = Vec::new();
        if !inputs.evidence.model_current {
            blocking.push("Mô hình cần được xác minh lại".to_owned());
        }
        if !inputs.evidence.profile_current {
            blocking.push("Profile benchmark không còn hiện hành".to_owned());
        }
        if !inputs.evidence.fixture_identity_current {
            blocking.push("Bằng chứng fixture không còn hiện hành".to_owned());
        }
        if !inputs.evidence.fixture_transcript_matches {
            blocking.push("Tự kiểm tra fixture không khớp chính xác".to_owned());
        }
        if !inputs.evidence.source_signal_current {
            blocking.push("Có tín hiệu audio chưa đạt".to_owned());
        }
        if !inputs.evidence.official_caption_complete {
            blocking.push("Nhận diện thử tiếng Việt chưa hoàn tất".to_owned());
        }
        let state = if blocking.is_empty() {
            ReadinessState::Ready
        } else {
            ReadinessState::Blocked
        };
        Self {
            state,
            source: Some(source),
            blocking_checks: blocking,
            diagnostics: DiagnosticSnapshot::from_config(&config),
        }
    }
}

fn source_snapshot(source: &SelectedSource, capture: &CaptureState) -> SourceDiagnostic {
    SourceDiagnostic {
        kind: match source.kind {
            SourceKind::Input => "Input",
            SourceKind::DesktopLoopback => "DesktopLoopback",
        }
        .to_owned(),
        display_name: bound(&source.display_name),
        endpoint_id: bound(&source.endpoint_id),
        endpoint_status: match capture {
            CaptureState::Unavailable { .. } => "Không khả dụng",
            CaptureState::Silent => "Im lặng",
            CaptureState::Active => "Có tín hiệu",
            _ => "Chưa kiểm tra",
        }
        .to_owned(),
    }
}

fn bound(value: &str) -> String {
    value.chars().take(256).collect()
}

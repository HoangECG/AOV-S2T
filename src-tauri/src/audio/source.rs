use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use super::endpoints::EndpointEvent;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    Input,
    DesktopLoopback,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EndpointAvailability {
    Active,
    Unavailable,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointInfo {
    pub kind: SourceKind,
    pub endpoint_id: String,
    pub display_name: String,
    pub availability: EndpointAvailability,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectedSource {
    pub kind: SourceKind,
    pub endpoint_id: String,
    pub display_name: String,
}

impl From<EndpointInfo> for SelectedSource {
    fn from(endpoint: EndpointInfo) -> Self {
        Self {
            kind: endpoint.kind,
            endpoint_id: endpoint.endpoint_id,
            display_name: endpoint.display_name,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state", content = "detail")]
pub enum CaptureState {
    Stopped,
    Starting,
    Active,
    Silent,
    Unavailable { reason: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "code")]
pub enum AudioCommandError {
    Conflict { technical_detail: String },
    NoSource { technical_detail: String },
    Unavailable { technical_detail: String },
}

impl std::fmt::Display for AudioCommandError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self {
            Self::Conflict { .. } => "Dừng kiểm tra nguồn hiện tại trước khi chọn nguồn khác.",
            Self::NoSource { .. } => "Chọn một nguồn âm thanh trước khi kiểm tra.",
            Self::Unavailable { .. } => "Nguồn đã chọn không khả dụng. Hãy chọn lại nguồn.",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for AudioCommandError {}

#[derive(Clone)]
pub struct SourceSelection {
    selected: Arc<Mutex<Option<SelectedSource>>>,
    state: Arc<Mutex<CaptureState>>,
}

impl Default for SourceSelection {
    fn default() -> Self {
        Self {
            selected: Arc::new(Mutex::new(None)),
            state: Arc::new(Mutex::new(CaptureState::Stopped)),
        }
    }
}

impl SourceSelection {
    pub fn with_selected(source: SelectedSource) -> Self {
        Self {
            selected: Arc::new(Mutex::new(Some(source))),
            state: Arc::new(Mutex::new(CaptureState::Stopped)),
        }
    }

    pub fn select(&self, source: SelectedSource) -> Result<SelectedSource, AudioCommandError> {
        let mut state = self.state.lock().expect("capture state poisoned");
        if matches!(
            *state,
            CaptureState::Starting | CaptureState::Active | CaptureState::Silent
        ) {
            return Err(AudioCommandError::Conflict {
                technical_detail: "capture is active; selection is immutable until stopped"
                    .to_owned(),
            });
        }
        *self.selected.lock().expect("selected source poisoned") = Some(source.clone());
        *state = CaptureState::Stopped;
        Ok(source)
    }

    pub fn selected(&self) -> Option<SelectedSource> {
        self.selected
            .lock()
            .expect("selected source poisoned")
            .clone()
    }

    pub fn capture_state(&self) -> CaptureState {
        self.state.lock().expect("capture state poisoned").clone()
    }

    pub fn mark_starting(&self) -> Result<SelectedSource, AudioCommandError> {
        let source = self.selected().ok_or(AudioCommandError::NoSource {
            technical_detail: "no exact endpoint ID has been selected".to_owned(),
        })?;
        *self.state.lock().expect("capture state poisoned") = CaptureState::Starting;
        Ok(source)
    }

    pub fn mark_active(&self) {
        *self.state.lock().expect("capture state poisoned") = CaptureState::Active;
    }

    pub fn mark_silent(&self) {
        *self.state.lock().expect("capture state poisoned") = CaptureState::Silent;
    }

    pub fn mark_stopped(&self) {
        *self.state.lock().expect("capture state poisoned") = CaptureState::Stopped;
    }

    pub fn mark_unavailable(&self, reason: impl Into<String>) {
        *self.state.lock().expect("capture state poisoned") = CaptureState::Unavailable {
            reason: reason.into(),
        };
    }

    pub fn handle_events(&self, events: impl IntoIterator<Item = EndpointEvent>) {
        let selected = self.selected();
        for event in events {
            if let (Some(source), EndpointEvent::DeviceInvalidated { endpoint_id }) =
                (&selected, event)
            {
                if source.endpoint_id == endpoint_id {
                    self.mark_unavailable("selected endpoint was removed or invalidated");
                }
            }
        }
    }
}

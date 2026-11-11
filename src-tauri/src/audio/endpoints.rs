use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};

use wasapi::{initialize_mta, DeviceEnumerator, DeviceEventCallbacks, DeviceState, Direction};

use super::source::{EndpointAvailability, EndpointInfo, SourceKind};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EndpointEvent {
    DeviceInvalidated { endpoint_id: String },
    DefaultDeviceChanged { kind: SourceKind },
    CatalogueChanged,
}

/// A nonblocking bridge for IMMNotificationClient callbacks. Windows callback code
/// only calls `enqueue`; capture shutdown and catalogue refresh happen elsewhere.
pub struct EndpointEventAdapter {
    sender: SyncSender<EndpointEvent>,
    receiver: Receiver<EndpointEvent>,
}

impl EndpointEventAdapter {
    pub fn new() -> Self {
        let (sender, receiver) = mpsc::sync_channel(32);
        Self { sender, receiver }
    }

    pub fn enqueue(&self, event: EndpointEvent) {
        match self.sender.try_send(event) {
            Ok(()) | Err(TrySendError::Full(_)) => {}
            Err(TrySendError::Disconnected(_)) => {}
        }
    }

    pub fn drain(&self) -> Vec<EndpointEvent> {
        self.receiver.try_iter().collect()
    }

    pub fn callbacks(&self) -> DeviceEventCallbacks {
        let removed_sender = self.sender.clone();
        let state_sender = self.sender.clone();
        let default_sender = self.sender.clone();
        let mut callbacks = DeviceEventCallbacks::new();
        callbacks.set_device_removed_callback(move |endpoint_id| {
            enqueue(
                &removed_sender,
                EndpointEvent::DeviceInvalidated { endpoint_id },
            )
        });
        callbacks.set_device_state_callback(move |endpoint_id, state| {
            if state != DeviceState::Active {
                enqueue(
                    &state_sender,
                    EndpointEvent::DeviceInvalidated { endpoint_id },
                );
            }
        });
        callbacks.set_default_device_callback(move |direction, _, _| {
            let kind = match direction {
                Direction::Capture => SourceKind::Input,
                Direction::Render => SourceKind::DesktopLoopback,
            };
            enqueue(
                &default_sender,
                EndpointEvent::DefaultDeviceChanged { kind },
            );
        });
        callbacks
    }
}

fn enqueue(sender: &SyncSender<EndpointEvent>, event: EndpointEvent) {
    match sender.try_send(event) {
        Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointCatalogues {
    pub inputs: Vec<EndpointInfo>,
    pub desktop_loopback: Vec<EndpointInfo>,
}

use serde::Serialize;

pub fn enumerate_catalogues() -> Result<EndpointCatalogues, String> {
    std::thread::spawn(enumerate_catalogues_mta)
        .join()
        .map_err(|_| "audio endpoint enumeration thread panicked".to_owned())?
}

fn enumerate_catalogues_mta() -> Result<EndpointCatalogues, String> {
    initialize_mta().ok().map_err(|error| error.to_string())?;
    let enumerator = DeviceEnumerator::new().map_err(|error| error.to_string())?;
    Ok(EndpointCatalogues {
        inputs: enumerate(&enumerator, Direction::Capture, SourceKind::Input)?,
        desktop_loopback: enumerate(&enumerator, Direction::Render, SourceKind::DesktopLoopback)?,
    })
}

fn enumerate(
    enumerator: &DeviceEnumerator,
    direction: Direction,
    kind: SourceKind,
) -> Result<Vec<EndpointInfo>, String> {
    let devices = enumerator
        .get_device_collection(&direction)
        .map_err(|error| error.to_string())?;
    (0..devices
        .get_nbr_devices()
        .map_err(|error| error.to_string())?)
        .map(|index| {
            let device = devices
                .get_device_at_index(index)
                .map_err(|error| error.to_string())?;
            Ok(EndpointInfo {
                kind,
                endpoint_id: device.get_id().map_err(|error| error.to_string())?,
                display_name: device
                    .get_friendlyname()
                    .map_err(|error| error.to_string())?,
                availability: EndpointAvailability::Active,
            })
        })
        .collect()
}

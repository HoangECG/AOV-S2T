use tauri::State;

use crate::audio::{
    capture::CaptureController,
    endpoints::{enumerate_catalogues, EndpointCatalogues},
    source::{AudioCommandError, EndpointAvailability, SelectedSource, SourceSelection},
};
use crate::{
    commands::verification::VerificationTransport,
    verification::{digest_for_native, ReceiptCommand, ReceiptOutcome},
};

#[tauri::command]
pub fn enumerate_audio_endpoints() -> Result<EndpointCatalogues, AudioCommandError> {
    enumerate_catalogues()
        .map_err(|technical_detail| AudioCommandError::Unavailable { technical_detail })
}

#[tauri::command]
pub fn select_audio_source(
    source: SelectedSource,
    selection: State<SourceSelection>,
    verification: State<VerificationTransport>,
) -> Result<SelectedSource, AudioCommandError> {
    let before = digest_for_native(&format!("{:?}", selection.capture_state()));
    let command = match source.kind {
        crate::audio::source::SourceKind::Input => ReceiptCommand::InputSelection,
        crate::audio::source::SourceKind::DesktopLoopback => {
            ReceiptCommand::RenderLoopbackSelection
        }
    };
    let source_digest = digest_for_native(&format!("{:?}\0{}", source.kind, source.endpoint_id));
    let native_source = select_active_catalogue_source(
        source,
        enumerate_catalogues()
            .map_err(|technical_detail| AudioCommandError::Unavailable { technical_detail })?,
    )?;
    let result = selection.select(native_source);
    verification.record(
        command,
        source_digest,
        if result.is_ok() {
            ReceiptOutcome::Affirmative
        } else {
            ReceiptOutcome::Failed
        },
        before,
        digest_for_native(&format!("{:?}", selection.capture_state())),
        digest_for_native("wasapi-selected-source-v1"),
    );
    result
}

pub fn select_active_catalogue_source(
    requested: SelectedSource,
    catalogues: EndpointCatalogues,
) -> Result<SelectedSource, AudioCommandError> {
    let matching = match requested.kind {
        crate::audio::source::SourceKind::Input => catalogues.inputs,
        crate::audio::source::SourceKind::DesktopLoopback => catalogues.desktop_loopback,
    }
    .into_iter()
    .filter(|endpoint| {
        endpoint.endpoint_id == requested.endpoint_id
            && endpoint.kind == requested.kind
            && endpoint.availability == EndpointAvailability::Active
    })
    .collect::<Vec<_>>();

    match matching.as_slice() {
        [endpoint] => Ok(endpoint.clone().into()),
        _ => Err(AudioCommandError::Unavailable {
            technical_detail: "selected endpoint ID is missing, inactive, ambiguous, or mismatched"
                .to_owned(),
        }),
    }
}

#[tauri::command]
pub fn start_audio_capture(
    app: tauri::AppHandle,
    capture: State<CaptureController>,
    selection: State<SourceSelection>,
    verification: State<VerificationTransport>,
) -> Result<(), AudioCommandError> {
    let before = digest_for_native(&format!("{:?}", selection.capture_state()));
    let result = capture.start(app);
    let after = digest_for_native(&format!("{:?}", selection.capture_state()));
    verification.record(
        ReceiptCommand::CaptureSignal,
        digest_for_native("capture-start"),
        if result.is_ok()
            && matches!(
                selection.capture_state(),
                crate::audio::source::CaptureState::Active
            )
        {
            ReceiptOutcome::Affirmative
        } else {
            ReceiptOutcome::Failed
        },
        before,
        after,
        digest_for_native("wasapi-capture-v1"),
    );
    result
}

#[tauri::command]
pub fn stop_audio_capture(
    capture: State<CaptureController>,
    selection: State<SourceSelection>,
    verification: State<VerificationTransport>,
) -> Result<(), AudioCommandError> {
    let before = digest_for_native(&format!("{:?}", selection.capture_state()));
    let result = capture.stop();
    verification.record(
        ReceiptCommand::CaptureLoss,
        digest_for_native("capture-stop"),
        if result.is_ok() {
            ReceiptOutcome::Affirmative
        } else {
            ReceiptOutcome::Failed
        },
        before,
        digest_for_native(&format!("{:?}", selection.capture_state())),
        digest_for_native("wasapi-capture-v1"),
    );
    result
}

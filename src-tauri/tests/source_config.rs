use live_subtitle_tool::{
    audio::{
        capture::{wasapi_capture_config, CaptureStreamMode, Win32StreamFlags},
        endpoints::EndpointCatalogues,
        endpoints::{EndpointEvent, EndpointEventAdapter},
        source::{
            CaptureState, EndpointAvailability, EndpointInfo, SelectedSource, SourceKind,
            SourceSelection,
        },
    },
    commands::audio::select_active_catalogue_source,
};

fn endpoint(kind: SourceKind, endpoint_id: &str, display_name: &str) -> EndpointInfo {
    EndpointInfo {
        kind,
        endpoint_id: endpoint_id.to_owned(),
        display_name: display_name.to_owned(),
        availability: EndpointAvailability::Active,
    }
}

#[test]
fn same_friendly_name_endpoints_remain_distinct_by_exact_id() {
    let first = endpoint(SourceKind::Input, "{input-a}", "Microphone");
    let second = endpoint(SourceKind::Input, "{input-b}", "Microphone");

    assert_ne!(first.endpoint_id, second.endpoint_id);
    assert_eq!(first.display_name, second.display_name);
}

#[test]
fn persisted_source_round_trips_kind_and_opaque_endpoint_id() {
    let source = SelectedSource::from(endpoint(
        SourceKind::DesktopLoopback,
        "{render-id}",
        "Speakers",
    ));
    let restored: SelectedSource =
        serde_json::from_str(&serde_json::to_string(&source).unwrap()).unwrap();

    assert_eq!(restored.kind, SourceKind::DesktopLoopback);
    assert_eq!(restored.endpoint_id, "{render-id}");
}

#[test]
fn invalidation_stops_the_selected_source_but_default_change_does_not_replace_it() {
    let source = SelectedSource::from(endpoint(SourceKind::Input, "{keep-me}", "Microphone"));
    let selection = SourceSelection::with_selected(source.clone());
    selection.mark_active();
    let adapter = EndpointEventAdapter::new();

    adapter.enqueue(EndpointEvent::DefaultDeviceChanged {
        kind: SourceKind::Input,
    });
    selection.handle_events(adapter.drain());
    assert_eq!(selection.selected(), Some(source.clone()));
    assert_eq!(selection.capture_state(), CaptureState::Active);

    adapter.enqueue(EndpointEvent::DeviceInvalidated {
        endpoint_id: source.endpoint_id.clone(),
    });
    selection.handle_events(adapter.drain());
    assert_eq!(selection.selected(), Some(source));
    assert!(matches!(
        selection.capture_state(),
        CaptureState::Unavailable { .. }
    ));
}

#[test]
fn changing_selection_while_active_returns_typed_conflict_and_keeps_source() {
    let active = SelectedSource::from(endpoint(SourceKind::Input, "{active}", "Microphone"));
    let replacement = SelectedSource::from(endpoint(
        SourceKind::DesktopLoopback,
        "{render}",
        "Speakers",
    ));
    let selection = SourceSelection::with_selected(active.clone());
    selection.mark_active();

    assert!(selection.select(replacement).is_err());
    assert_eq!(selection.selected(), Some(active));
}

#[test]
fn a_single_selection_accepts_either_input_or_desktop_catalogue_group() {
    let selection = SourceSelection::default();
    let desktop = SelectedSource::from(endpoint(
        SourceKind::DesktopLoopback,
        "{render}",
        "Speakers",
    ));

    assert_eq!(selection.select(desktop.clone()).unwrap(), desktop);
    assert_eq!(selection.selected(), Some(desktop));
}

#[test]
fn production_capture_config_uses_capture_direction_for_input_and_render_loopback() {
    let input = wasapi_capture_config(SourceKind::Input);
    assert_eq!(input.endpoint_direction, wasapi::Direction::Capture);
    assert_eq!(input.capture_direction, wasapi::Direction::Capture);
    assert_eq!(input.stream_mode, CaptureStreamMode::EventsShared);
    assert!(!input.autoconvert);
    assert_eq!(input.expected_win32_flags, Win32StreamFlags::EVENT_CALLBACK);

    let loopback = wasapi_capture_config(SourceKind::DesktopLoopback);
    assert_eq!(loopback.endpoint_direction, wasapi::Direction::Render);
    assert_eq!(loopback.capture_direction, wasapi::Direction::Capture);
    assert_eq!(loopback.stream_mode, CaptureStreamMode::EventsShared);
    assert!(!loopback.autoconvert);
    assert_eq!(
        loopback.expected_win32_flags,
        Win32StreamFlags::EVENT_CALLBACK | Win32StreamFlags::LOOPBACK
    );
    assert_ne!(loopback.capture_direction, loopback.endpoint_direction);
}

#[test]
fn only_active_native_catalogue_entry_can_be_selected() {
    let catalogues = EndpointCatalogues {
        inputs: vec![endpoint(
            SourceKind::Input,
            "{input-a}",
            "Native microphone",
        )],
        desktop_loopback: vec![endpoint(
            SourceKind::DesktopLoopback,
            "{render-a}",
            "Native speakers",
        )],
    };

    let selected = select_active_catalogue_source(
        SelectedSource {
            kind: SourceKind::DesktopLoopback,
            endpoint_id: "{render-a}".to_owned(),
            display_name: "forged label".to_owned(),
        },
        catalogues.clone(),
    )
    .unwrap();
    assert_eq!(selected.display_name, "Native speakers");

    for request in [
        SelectedSource {
            kind: SourceKind::Input,
            endpoint_id: "{render-a}".to_owned(),
            display_name: "Speakers".to_owned(),
        },
        SelectedSource {
            kind: SourceKind::DesktopLoopback,
            endpoint_id: "{missing}".to_owned(),
            display_name: "Missing".to_owned(),
        },
    ] {
        assert!(select_active_catalogue_source(request, catalogues.clone()).is_err());
    }

    let inactive_catalogues = EndpointCatalogues {
        inputs: vec![EndpointInfo {
            availability: EndpointAvailability::Unavailable,
            ..endpoint(SourceKind::Input, "{inactive}", "Unavailable microphone")
        }],
        desktop_loopback: vec![],
    };
    assert!(select_active_catalogue_source(
        SelectedSource {
            kind: SourceKind::Input,
            endpoint_id: "{inactive}".to_owned(),
            display_name: "Unavailable microphone".to_owned(),
        },
        inactive_catalogues,
    )
    .is_err());
}

use live_subtitle_tool::audio::{
    capture::wasapi_capture_config,
    meter::{Meter, MeterState},
    pcm::{normalize, PcmFormat, SampleEncoding, TARGET_SAMPLE_RATE},
    source::SourceKind,
};

#[test]
fn float_and_pcm_buffers_normalize_to_bounded_16khz_mono_i16() {
    let float = normalize(&[1.0, -1.0, 0.5, -0.5], PcmFormat::float(48_000, 2)).unwrap();
    let pcm = normalize(
        &[i16::MAX, i16::MIN, 0, 0],
        PcmFormat::integer(44_100, 2, 16),
    )
    .unwrap();

    assert_eq!(float.sample_rate, TARGET_SAMPLE_RATE);
    assert_eq!(float.channels, 1);
    assert!(float
        .samples
        .iter()
        .all(|sample| *sample >= i16::MIN && *sample <= i16::MAX));
    assert_eq!(pcm.samples.len(), 1);
    assert_eq!(pcm.samples[0], 0);
}

#[test]
fn meter_distinguishes_signal_silence_and_unavailable_without_packets() {
    let mut meter = Meter::new(0.01, 100);
    assert_eq!(meter.update(&[5_000], 0).state, MeterState::Signal);
    assert_eq!(meter.update(&[0, 0], 50).state, MeterState::Signal);
    assert_eq!(meter.update(&[0, 0], 150).state, MeterState::Silent);
    assert_eq!(meter.no_packets(500).state, MeterState::Unavailable);
}

#[test]
fn input_and_desktop_sources_choose_the_correct_wasapi_configuration() {
    assert_eq!(
        wasapi_capture_config(SourceKind::Input).endpoint_direction,
        wasapi::Direction::Capture
    );
    assert_eq!(
        wasapi_capture_config(SourceKind::DesktopLoopback).endpoint_direction,
        wasapi::Direction::Render
    );
    assert_eq!(
        wasapi_capture_config(SourceKind::DesktopLoopback).capture_direction,
        wasapi::Direction::Capture
    );
}

#[test]
fn unsupported_sample_encodings_are_rejected_without_guessing() {
    let format = PcmFormat {
        sample_rate: 48_000,
        channels: 2,
        encoding: SampleEncoding::Integer { bits: 20 },
    };
    assert!(normalize(&[0; 8], format).is_err());
}

use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Instant,
};

use tauri::{AppHandle, Emitter};
use wasapi::{
    initialize_mta, DeviceEnumerator, Direction, SampleType, ShareMode, StreamMode, TimingMode,
    WasapiError,
};

use super::{
    endpoints::EndpointEventAdapter,
    meter::{Meter, MeterState},
    pcm::{decode_interleaved, normalize, PcmFormat, SampleEncoding, TARGET_SAMPLE_RATE},
    source::{AudioCommandError, CaptureState, SelectedSource, SourceKind, SourceSelection},
};

const SILENCE_THRESHOLD: f32 = 0.005;
const SILENCE_DURATION_MS: u64 = 750;
const EVENT_TIMEOUT_MS: u32 = 1_000;
const BENCHMARK_MAX_SAMPLES: usize = 16_000 * 20;
const LIVE_HISTORY_SAMPLES: usize = TARGET_SAMPLE_RATE as usize * 60;

/// A bounded PCM history with a monotonic sample position for the live scheduler.
/// Keeping the position lets inference catch up after a slow decode instead of jumping
/// straight to the newest audio and losing the intervening speech.
pub(crate) struct LiveAudioBuffer {
    first_sample: u64,
    samples: VecDeque<i16>,
}

#[derive(Clone, Debug)]
pub(crate) struct LiveAudioSnapshot {
    pub(crate) first_sample: u64,
    pub(crate) samples: Vec<i16>,
}

impl LiveAudioBuffer {
    fn append(&mut self, samples: &[i16]) {
        self.samples.extend(samples.iter().copied());
        self.retain_history();
    }

    fn append_silence(&mut self, samples: usize) {
        self.samples
            .resize(self.samples.len().saturating_add(samples), 0);
        self.retain_history();
    }

    fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub(crate) fn snapshot(&self) -> LiveAudioSnapshot {
        LiveAudioSnapshot {
            first_sample: self.first_sample,
            samples: self.samples.iter().copied().collect(),
        }
    }

    fn retain_history(&mut self) {
        let excess = self.samples.len().saturating_sub(LIVE_HISTORY_SAMPLES);
        if excess > 0 {
            self.samples.drain(..excess);
            self.first_sample = self.first_sample.saturating_add(excess as u64);
        }
    }
}

impl Default for LiveAudioBuffer {
    fn default() -> Self {
        Self {
            first_sample: 0,
            samples: VecDeque::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WasapiCaptureConfig {
    pub endpoint_direction: Direction,
    pub capture_direction: Direction,
    pub stream_mode: CaptureStreamMode,
    pub autoconvert: bool,
    pub expected_win32_flags: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaptureStreamMode {
    EventsShared,
}

impl WasapiCaptureConfig {
    pub fn stream_mode(self, buffer_duration_hns: i64) -> StreamMode {
        match self.stream_mode {
            CaptureStreamMode::EventsShared => StreamMode::EventsShared {
                autoconvert: self.autoconvert,
                buffer_duration_hns,
            },
        }
    }
}

pub struct Win32StreamFlags;

impl Win32StreamFlags {
    pub const EVENT_CALLBACK: u32 = 0x0004_0000;
    pub const LOOPBACK: u32 = 0x0002_0000;
}

pub fn wasapi_capture_config(kind: SourceKind) -> WasapiCaptureConfig {
    match kind {
        SourceKind::Input => WasapiCaptureConfig {
            endpoint_direction: Direction::Capture,
            capture_direction: Direction::Capture,
            stream_mode: CaptureStreamMode::EventsShared,
            autoconvert: false,
            expected_win32_flags: Win32StreamFlags::EVENT_CALLBACK,
        },
        SourceKind::DesktopLoopback => WasapiCaptureConfig {
            endpoint_direction: Direction::Render,
            capture_direction: Direction::Capture,
            stream_mode: CaptureStreamMode::EventsShared,
            autoconvert: false,
            expected_win32_flags: Win32StreamFlags::EVENT_CALLBACK | Win32StreamFlags::LOOPBACK,
        },
    }
}

pub struct CaptureController {
    selection: SourceSelection,
    active: Mutex<Option<CaptureHandle>>,
    benchmark_sample: Arc<Mutex<Option<Vec<i16>>>>,
    live_sample: Arc<Mutex<Option<LiveAudioBuffer>>>,
}
struct CaptureHandle {
    stop: Arc<AtomicBool>,
    worker: thread::JoinHandle<()>,
}

impl CaptureController {
    pub fn new(selection: SourceSelection) -> Self {
        Self {
            selection,
            active: Mutex::new(None),
            benchmark_sample: Arc::new(Mutex::new(None)),
            live_sample: Arc::new(Mutex::new(None)),
        }
    }

    pub fn start(&self, app: AppHandle) -> Result<(), AudioCommandError> {
        self.start_with_sample(app, false)
    }

    pub fn start_benchmark_sample(&self, app: AppHandle) -> Result<(), AudioCommandError> {
        self.start_with_sample(app, true)
    }

    pub fn start_live(&self, app: AppHandle) -> Result<(), AudioCommandError> {
        *self.live_sample.lock().expect("live sample poisoned") = Some(LiveAudioBuffer::default());
        if let Err(error) = self.start_with_sample(app, false) {
            self.live_sample
                .lock()
                .expect("live sample poisoned")
                .take();
            return Err(error);
        }
        Ok(())
    }

    fn start_with_sample(
        &self,
        app: AppHandle,
        keep_benchmark_sample: bool,
    ) -> Result<(), AudioCommandError> {
        let mut active = self.active.lock().expect("capture handle poisoned");
        if active
            .as_ref()
            .is_some_and(|handle| handle.worker.is_finished())
        {
            let handle = active.take().expect("finished capture handle exists");
            handle
                .worker
                .join()
                .map_err(|_| AudioCommandError::Unavailable {
                    technical_detail: "capture worker panicked after endpoint loss".to_owned(),
                })?;
        }
        if active.is_some() {
            return Err(AudioCommandError::Conflict {
                technical_detail: "capture already owns an active stream".to_owned(),
            });
        }
        let source = self.selection.mark_starting()?;
        *self
            .benchmark_sample
            .lock()
            .expect("benchmark sample poisoned") = keep_benchmark_sample.then(Vec::new);
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let selection = self.selection.clone();
        let benchmark_sample = Arc::clone(&self.benchmark_sample);
        let live_sample = Arc::clone(&self.live_sample);
        let worker = thread::spawn(move || {
            run_capture(
                app,
                source,
                selection,
                worker_stop,
                benchmark_sample,
                live_sample,
            )
        });
        *active = Some(CaptureHandle { stop, worker });
        Ok(())
    }

    pub fn finish_benchmark_sample(&self) -> Result<BenchmarkSampleMetadata, AudioCommandError> {
        let mut sample = self.take_benchmark_sample()?;
        let metadata = BenchmarkSampleMetadata {
            frames: sample.len() as u64,
            duration_ms: sample.len() as u64 * 1_000 / 16_000,
        };
        sample.fill(0);
        Ok(metadata)
    }

    /// Atomically ends capture and moves the private sample out of controller-owned memory.
    pub fn take_benchmark_sample(&self) -> Result<Vec<i16>, AudioCommandError> {
        let stop_result = self.stop();
        let mut sample = self
            .benchmark_sample
            .lock()
            .expect("benchmark sample poisoned")
            .take()
            .unwrap_or_default();
        if let Err(error) = stop_result {
            sample.fill(0);
            return Err(error);
        }
        if sample.is_empty() || !sample.iter().any(|value| value.unsigned_abs() > 327) {
            sample.fill(0);
            return Err(AudioCommandError::Unavailable {
                technical_detail: "benchmark sample had no non-silent PCM signal".to_owned(),
            });
        }
        Ok(sample)
    }

    pub fn discard_benchmark_sample(&self) {
        if let Some(mut sample) = self
            .benchmark_sample
            .lock()
            .expect("benchmark sample poisoned")
            .take()
        {
            sample.fill(0);
        }
    }

    pub fn has_benchmark_sample(&self) -> bool {
        self.benchmark_sample
            .lock()
            .expect("benchmark sample poisoned")
            .is_some()
    }

    pub fn live_window(&self) -> Result<Vec<i16>, AudioCommandError> {
        let sample = self.live_sample.lock().expect("live sample poisoned");
        let sample = sample.as_ref().ok_or(AudioCommandError::NoSource {
            technical_detail: "live subtitle capture is not running".to_owned(),
        })?;
        if sample.is_empty() {
            return Err(AudioCommandError::Unavailable {
                technical_detail: "live subtitle capture has no audio yet".to_owned(),
            });
        }
        Ok(sample.snapshot().samples)
    }

    pub(crate) fn live_samples(&self) -> Arc<Mutex<Option<LiveAudioBuffer>>> {
        Arc::clone(&self.live_sample)
    }

    pub fn stop(&self) -> Result<(), AudioCommandError> {
        let result =
            if let Some(handle) = self.active.lock().expect("capture handle poisoned").take() {
                handle.stop.store(true, Ordering::Release);
                handle
                    .worker
                    .join()
                    .map_err(|_| AudioCommandError::Unavailable {
                        technical_detail: "capture worker panicked while stopping".to_owned(),
                    })
            } else {
                Ok(())
            };
        self.selection.mark_stopped();
        self.live_sample
            .lock()
            .expect("live sample poisoned")
            .take();
        result
    }
}

fn run_capture(
    app: AppHandle,
    source: SelectedSource,
    selection: SourceSelection,
    stop: Arc<AtomicBool>,
    benchmark_sample: Arc<Mutex<Option<Vec<i16>>>>,
    live_sample: Arc<Mutex<Option<LiveAudioBuffer>>>,
) {
    let result = (|| -> Result<(), AudioCommandError> {
        initialize_mta().ok().map_err(wasapi_error)?;
        let enumerator = DeviceEnumerator::new().map_err(wasapi_error)?;
        let events = EndpointEventAdapter::new();
        let _notifications = enumerator
            .register_notification_callback(events.callbacks())
            .map_err(wasapi_error)?;
        let device = enumerator
            .get_device(&source.endpoint_id)
            .map_err(wasapi_error)?;
        let mut client = device.get_iaudioclient().map_err(wasapi_error)?;
        let config = wasapi_capture_config(source.kind);
        if client.get_direction() != config.endpoint_direction {
            return Err(AudioCommandError::Unavailable {
                technical_detail: "selected endpoint has an unexpected WASAPI data flow".to_owned(),
            });
        }
        let mix_format = client.get_mixformat().map_err(wasapi_error)?;
        let format = format_from_mix(&mix_format)?;
        let (_, minimum_period) = client.get_device_period().map_err(wasapi_error)?;
        // Render endpoint + capture direction + EventsShared is wasapi 0.24.0 loopback.
        client
            .initialize_client(
                &mix_format,
                &config.capture_direction,
                &config.stream_mode(minimum_period),
            )
            .map_err(wasapi_error)?;
        if client.get_sharemode() != Some(ShareMode::Shared)
            || client.get_timing_mode() != Some(TimingMode::Events)
        {
            return Err(AudioCommandError::Unavailable {
                technical_detail: "WASAPI did not initialize the required shared event stream"
                    .to_owned(),
            });
        }
        let event = client.set_get_eventhandle().map_err(wasapi_error)?;
        let buffer_bytes = client.get_buffer_size().map_err(wasapi_error)? as usize
            * mix_format.get_blockalign() as usize;
        let capture = client.get_audiocaptureclient().map_err(wasapi_error)?;
        client.start_stream().map_err(wasapi_error)?;
        selection.mark_active();
        let started_at = Instant::now();
        let mut meter = Meter::new(SILENCE_THRESHOLD, SILENCE_DURATION_MS);

        while !stop.load(Ordering::Acquire) {
            match event.wait_for_event(EVENT_TIMEOUT_MS) {
                Ok(()) | Err(WasapiError::EventTimeout) => {}
                Err(error) => return Err(wasapi_error(error)),
            }
            selection.handle_events(events.drain());
            if matches!(selection.capture_state(), CaptureState::Unavailable { .. }) {
                return Err(AudioCommandError::Unavailable {
                    technical_detail: "selected endpoint was invalidated".to_owned(),
                });
            }
            while capture
                .get_next_packet_size()
                .map_err(wasapi_error)?
                .unwrap_or(0)
                > 0
            {
                let mut packet = vec![0_u8; buffer_bytes];
                let (frames, info) = capture
                    .read_from_device(&mut packet)
                    .map_err(wasapi_error)?;
                packet.truncate(frames as usize * mix_format.get_blockalign() as usize);
                // A discontinuity means frames were lost, not that the endpoint disappeared.
                // Continue with the next packet; actual endpoint loss is reported by the
                // notification callback or a WASAPI operation failure.
                let elapsed = started_at.elapsed().as_millis() as u64;
                let normalized = if info.flags.silent {
                    None
                } else {
                    Some(normalize(&decode_interleaved(&packet, format)?, format)?)
                };
                let level = if let Some(frame) = normalized {
                    if let Some(sample) = benchmark_sample
                        .lock()
                        .expect("benchmark sample poisoned")
                        .as_mut()
                    {
                        let remaining = BENCHMARK_MAX_SAMPLES.saturating_sub(sample.len());
                        sample.extend(frame.samples.iter().copied().take(remaining));
                    }
                    if let Some(sample) = live_sample.lock().expect("live sample poisoned").as_mut()
                    {
                        sample.append(&frame.samples);
                    }
                    meter.update(&frame.samples, elapsed)
                } else {
                    if let Some(sample) = live_sample.lock().expect("live sample poisoned").as_mut()
                    {
                        let silent_samples = (frames as usize)
                            .saturating_mul(TARGET_SAMPLE_RATE as usize)
                            .div_ceil(mix_format.get_samplespersec() as usize);
                        sample.append_silence(silent_samples);
                    }
                    meter.update(&[0], elapsed)
                };
                if level.state == MeterState::Silent {
                    selection.mark_silent();
                } else {
                    selection.mark_active();
                }
                let _ = app.emit("audio-level", level);
            }
            // Event notifications can race with packet consumption. An empty wake-up is not
            // evidence that the selected endpoint is unavailable.
        }
        client.stop_stream().map_err(wasapi_error)?;
        Ok(())
    })();

    if let Err(error) = result {
        live_sample.lock().expect("live sample poisoned").take();
        let _ = app.emit("audio-capture-error", error.to_string());
        selection.mark_unavailable(error.to_string());
        let _ = app.emit(
            "audio-level",
            Meter::new(SILENCE_THRESHOLD, SILENCE_DURATION_MS).no_packets(0),
        );
    } else {
        selection.mark_stopped();
    }
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkSampleMetadata {
    pub frames: u64,
    pub duration_ms: u64,
}

fn format_from_mix(format: &wasapi::WaveFormat) -> Result<PcmFormat, AudioCommandError> {
    let encoding = match format.get_subformat().map_err(wasapi_error)? {
        SampleType::Float => SampleEncoding::Float,
        SampleType::Int => SampleEncoding::Integer {
            bits: format.get_bitspersample(),
        },
    };
    Ok(PcmFormat {
        sample_rate: format.get_samplespersec(),
        channels: format.get_nchannels(),
        encoding,
    })
}

fn wasapi_error(error: impl std::fmt::Display) -> AudioCommandError {
    AudioCommandError::Unavailable {
        technical_detail: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_a_bounded_history_with_an_absolute_sample_offset() {
        let mut buffer = LiveAudioBuffer::default();
        buffer.append(&vec![7; LIVE_HISTORY_SAMPLES + 3]);

        let snapshot = buffer.snapshot();

        assert_eq!(snapshot.first_sample, 3);
        assert_eq!(snapshot.samples.len(), LIVE_HISTORY_SAMPLES);
        assert!(snapshot.samples.iter().all(|sample| *sample == 7));
    }
}

use std::{
    process::Command,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

use tauri::{AppHandle, Emitter, Manager, State};

use crate::{
    audio::{
        capture::{CaptureController, LiveAudioBuffer, LiveAudioSnapshot},
        meter::{first_live_speech_sample, has_recent_live_speech},
    },
    hallucination_filter::is_rejected_caption,
    inference::{
        benchmark::{FixtureEvidence, InferenceProfile},
        download, manifest,
        runner::{HostInfo, InferenceRunner, VerifiedModel, WorkerKind},
        transaction::transcribe_live_window_persistent,
    },
    setup::state::SetupController,
    subtitle_filter::LiveCaptionFilter,
    subtitle_web::CaptionStore,
};

// Start after one second so a short first utterance is not lost before inference.
const MINIMUM_LIVE_SAMPLES: usize = 16_000;
const LIVE_DECODE_WINDOW_SAMPLES: usize = 16_000 * 8;
const LIVE_DECODE_STRIDE_SAMPLES: u64 = 16_000 * 2;
const LIVE_CAPTURE_POLL_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LiveWindowPass {
    Active,
    Final,
}

enum LiveWindowAction {
    Decode {
        pass: LiveWindowPass,
        end_sample: u64,
        samples: Vec<i16>,
    },
    Flush,
}

fn worker_candidates(preferred: WorkerKind) -> [WorkerKind; 4] {
    [
        preferred,
        WorkerKind::Cuda,
        WorkerKind::Vulkan,
        WorkerKind::Cpu,
    ]
}

fn quick_start_profile(model_revision: &str, installed_workers: &[WorkerKind]) -> InferenceProfile {
    let worker = [WorkerKind::Cuda, WorkerKind::Vulkan, WorkerKind::Cpu]
        .into_iter()
        .find(|kind| installed_workers.contains(kind))
        .unwrap_or(WorkerKind::Cpu);
    let worker_build = match worker {
        WorkerKind::Cpu => "whispercpp-4834a232-cpu-x64",
        WorkerKind::Cuda => "whispercpp-4834a232-cuda-x64",
        WorkerKind::Vulkan => "whispercpp-4834a232-vulkan-x64",
    };
    InferenceProfile {
        worker,
        worker_build: worker_build.to_owned(),
        model_revision: model_revision.to_owned(),
        hardware_fingerprint: format!("quick-start-{worker_build}"),
        rtf: 0.0,
        p95_ms: 0,
        correctness: 0.0,
        fixture: FixtureEvidence::default(),
    }
}

#[derive(Default)]
struct LiveWindowScheduler {
    last_completed_end: Option<u64>,
    speech_seen: bool,
    speech_start: Option<u64>,
    final_boundary: Option<u64>,
}

impl LiveWindowScheduler {
    /// Emits only windows with fresh PCM. The absolute end marker means a slow worker can
    /// catch up through retained audio rather than continually replacing its work with the
    /// latest eight-second snapshot.
    fn next(&mut self, snapshot: &LiveAudioSnapshot) -> Option<LiveWindowAction> {
        if has_recent_live_speech(&snapshot.samples) {
            if !self.speech_seen {
                self.speech_start = first_live_speech_sample(&snapshot.samples)
                    .map(|offset| snapshot.first_sample.saturating_add(offset as u64));
            }
            self.speech_seen = true;
            self.final_boundary = None;

            let end_sample = match self.last_completed_end {
                Some(end_sample) => {
                    let next = end_sample.saturating_add(LIVE_DECODE_STRIDE_SAMPLES);
                    (next <= snapshot.end_sample()).then_some(next)?
                }
                None => self
                    .speech_start
                    .map(|start| start.saturating_add(LIVE_DECODE_WINDOW_SAMPLES as u64))
                    .unwrap_or_else(|| snapshot.end_sample())
                    .min(snapshot.end_sample()),
            };
            return self.decode(
                snapshot,
                end_sample,
                snapshot.end_sample(),
                LiveWindowPass::Active,
            );
        }

        if self.speech_seen {
            self.speech_seen = false;
            self.final_boundary = Some(snapshot.end_sample());
        }

        let final_boundary = self.final_boundary?;
        if self
            .last_completed_end
            .is_some_and(|end_sample| end_sample >= final_boundary)
        {
            self.speech_start = None;
            self.final_boundary = None;
            return Some(LiveWindowAction::Flush);
        }

        let end_sample = self
            .last_completed_end
            .map(|end_sample| end_sample.saturating_add(LIVE_DECODE_STRIDE_SAMPLES))
            .or_else(|| {
                self.speech_start
                    .map(|start| start.saturating_add(LIVE_DECODE_WINDOW_SAMPLES as u64))
            })
            .unwrap_or(final_boundary)
            .min(final_boundary);
        match self.decode(snapshot, end_sample, final_boundary, LiveWindowPass::Final) {
            Some(action) => Some(action),
            None => {
                // The bounded history has already expired. Do not leave the final caption
                // permanently pending when there is no recoverable PCM left to decode.
                self.last_completed_end = Some(final_boundary);
                self.speech_start = None;
                self.final_boundary = None;
                Some(LiveWindowAction::Flush)
            }
        }
    }

    fn decode(
        &self,
        snapshot: &LiveAudioSnapshot,
        desired_end: u64,
        maximum_end: u64,
        pass: LiveWindowPass,
    ) -> Option<LiveWindowAction> {
        let earliest_end = snapshot
            .first_sample
            .saturating_add(MINIMUM_LIVE_SAMPLES as u64);
        let end_sample = desired_end.max(earliest_end).min(maximum_end);
        if end_sample > snapshot.end_sample() || end_sample < earliest_end {
            return None;
        }
        let start_sample = end_sample
            .saturating_sub(LIVE_DECODE_WINDOW_SAMPLES as u64)
            .max(snapshot.first_sample);
        let start = usize::try_from(start_sample.saturating_sub(snapshot.first_sample)).ok()?;
        let end = usize::try_from(end_sample.saturating_sub(snapshot.first_sample)).ok()?;
        (start < end && end <= snapshot.samples.len()).then(|| LiveWindowAction::Decode {
            pass,
            end_sample,
            samples: snapshot.samples[start..end].to_vec(),
        })
    }

    fn mark_completed(&mut self, end_sample: u64) {
        self.last_completed_end = Some(
            self.last_completed_end
                .map(|current| current.max(end_sample))
                .unwrap_or(end_sample),
        );
        self.speech_start = None;
    }

    #[cfg(test)]
    fn last_completed_end(&self) -> Option<u64> {
        self.last_completed_end
    }

    #[cfg(test)]
    fn final_boundary(&self) -> Option<u64> {
        self.final_boundary
    }
}

impl LiveAudioSnapshot {
    fn end_sample(&self) -> u64 {
        self.first_sample.saturating_add(self.samples.len() as u64)
    }
}

#[derive(Clone, Default)]
pub struct SubtitleService {
    active_session: Arc<Mutex<Option<Arc<AtomicBool>>>>,
}

impl SubtitleService {
    fn begin(&self) -> Result<Arc<AtomicBool>, String> {
        let mut active_session = self
            .active_session
            .lock()
            .expect("subtitle session poisoned");
        if active_session.is_some() {
            return Err("Phiên phụ đề đang chạy.".to_owned());
        }

        let running = Arc::new(AtomicBool::new(true));
        *active_session = Some(Arc::clone(&running));
        Ok(running)
    }

    fn stop(&self) {
        if let Some(running) = self
            .active_session
            .lock()
            .expect("subtitle session poisoned")
            .take()
        {
            running.store(false, Ordering::Release);
        }
    }

    fn is_current(&self, running: &Arc<AtomicBool>) -> bool {
        running.load(Ordering::Acquire)
            && self
                .active_session
                .lock()
                .expect("subtitle session poisoned")
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, running))
    }

    fn finish(&self, running: &Arc<AtomicBool>) {
        running.store(false, Ordering::Release);
        let mut active_session = self
            .active_session
            .lock()
            .expect("subtitle session poisoned");
        if active_session
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, running))
        {
            active_session.take();
        }
    }
}

#[tauri::command]
pub fn start_subtitle_capture(
    app: AppHandle,
    capture: State<CaptureController>,
    setup: State<SetupController>,
    service: State<SubtitleService>,
    captions: State<CaptionStore>,
) -> Result<(), String> {
    let running = service.begin()?;
    if let Err(error) = capture.start_live(app.clone()) {
        service.finish(&running);
        return Err(error.to_string());
    }

    captions.set_text(String::new());
    captions.set_status("Đang chờ tín hiệu audio…".to_owned());
    let samples = capture.live_samples();
    let captions = captions.inner().clone();
    let profile = setup.selected_profile();
    let service_for_thread = service.inner().clone();
    let worker_running = Arc::clone(&running);
    let worker = thread::Builder::new()
        .name("subtitle-inference".to_owned())
        .spawn(move || {
            run_inference(
                app,
                samples,
                worker_running,
                captions,
                profile,
                service_for_thread,
            )
        });
    if let Err(error) = worker {
        service.finish(&running);
        let _ = capture.stop();
        return Err(error.to_string());
    }
    Ok(())
}

#[tauri::command]
pub fn stop_subtitle_capture(
    capture: State<CaptureController>,
    service: State<SubtitleService>,
    captions: State<CaptionStore>,
) -> Result<(), String> {
    service.stop();
    captions.set_text(String::new());
    captions.set_status("Đã dừng phụ đề.".to_owned());
    capture.stop().map_err(|error| error.to_string())
}

#[tauri::command]
pub fn open_subtitle_web() -> Result<(), String> {
    #[cfg(windows)]
    {
        Command::new("rundll32.exe")
            .arg("url.dll,FileProtocolHandler")
            .arg(crate::subtitle_web::DEFAULT_URL)
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("Không thể mở trình duyệt: {error}"))
    }

    #[cfg(not(windows))]
    {
        Err("Mở trang phụ đề tự động chỉ hỗ trợ Windows.".to_owned())
    }
}

fn run_inference(
    app: AppHandle,
    live_samples: Arc<Mutex<Option<LiveAudioBuffer>>>,
    running: Arc<AtomicBool>,
    captions: CaptionStore,
    configured_profile: Option<InferenceProfile>,
    service: SubtitleService,
) {
    let result = (|| -> Result<bool, String> {
        let manifest = manifest::bundled_manifest().map_err(|error| error.to_string())?;
        let model_path =
            download::destination_for(&app, &manifest).map_err(|error| error.ui_detail().1)?;
        captions.set_status("Đang kiểm tra tệp mô hình…".to_owned());
        download::verify_file(&model_path, manifest.expected_bytes, &manifest.sha256)
            .map_err(|error| error.ui_detail().1)?;
        let resources = app
            .path()
            .resource_dir()
            .map_err(|error| error.to_string())?;
        if !service.is_current(&running) {
            return Ok(false);
        }
        captions.set_status("Đang nạp mô hình nhận dạng…".to_owned());
        let runner = InferenceRunner::from_runtime_inventory(resources, HostInfo::supported_x64())
            .map_err(|error| error.to_string())?;
        let model = VerifiedModel {
            path: model_path,
            revision: manifest.revision.clone(),
        };
        let installed_workers = runner.installed_workers();
        let mut profile = configured_profile
            .unwrap_or_else(|| quick_start_profile(&manifest.revision, &installed_workers));
        let mut tried_workers = Vec::new();
        let mut last_error = None;
        let mut selected_worker = None;
        for worker_kind in worker_candidates(profile.worker) {
            if tried_workers.contains(&worker_kind) || !installed_workers.contains(&worker_kind) {
                continue;
            }
            tried_workers.push(worker_kind);
            match runner.start_live_worker(worker_kind, &model) {
                Ok(worker) => {
                    selected_worker = Some((worker_kind, worker));
                    break;
                }
                Err(error) => last_error = Some(error),
            }
        }
        let (worker_kind, mut worker) = selected_worker.ok_or_else(|| {
            last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "Không có worker nhận dạng khả dụng.".to_owned())
        })?;
        profile.worker = worker_kind;
        captions.set_status(format!("Đang nhận dạng bằng {:?}…", worker_kind));
        let mut capture_ended = false;
        let mut caption_filter = LiveCaptionFilter::default();
        let mut window_scheduler = LiveWindowScheduler::default();

        while service.is_current(&running) {
            thread::sleep(LIVE_CAPTURE_POLL_INTERVAL);
            if !service.is_current(&running) {
                break;
            }
            let snapshot = {
                let samples = live_samples.lock().expect("live sample poisoned");
                match samples.as_ref() {
                    Some(samples) => {
                        let snapshot = samples.snapshot();
                        if snapshot.samples.len() < MINIMUM_LIVE_SAMPLES {
                            continue;
                        }
                        snapshot
                    }
                    None => {
                        capture_ended = true;
                        break;
                    }
                }
            };
            if !service.is_current(&running) {
                break;
            }
            let Some(action) = window_scheduler.next(&snapshot) else {
                captions.set_status("Đang chờ giọng nói…".to_owned());
                continue;
            };
            let (pass, end_sample, samples) = match action {
                LiveWindowAction::Decode {
                    pass,
                    end_sample,
                    samples,
                } => (pass, end_sample, samples),
                LiveWindowAction::Flush => {
                    if let Some(text) = caption_filter.flush() {
                        captions.set_text(text.clone());
                        let _ = app.emit("subtitle-text", text);
                    }
                    captions.set_status("Đang chờ giọng nói…".to_owned());
                    continue;
                }
            };
            captions.set_status(
                match pass {
                    LiveWindowPass::Active => "Đang nhận dạng audio…",
                    LiveWindowPass::Final => "Đang hoàn tất phụ đề…",
                }
                .to_owned(),
            );
            match transcribe_live_window_persistent(&mut worker, &model, &profile, samples) {
                Ok(text) if service.is_current(&running) => {
                    window_scheduler.mark_completed(end_sample);
                    if text.is_empty() {
                        captions.set_status("Đang nghe…".to_owned());
                    } else if is_rejected_caption(&text) {
                        caption_filter.reset();
                        captions.set_text(String::new());
                        captions.set_status("Đã bỏ kết quả không phải lời nói…".to_owned());
                        let _ = app.emit("subtitle-text", String::new());
                    } else if let Some(text) = caption_filter.push(&text) {
                        captions.set_text(text.clone());
                        captions.set_status("Đang nghe…".to_owned());
                        let _ = app.emit("subtitle-text", text);
                    } else {
                        captions.set_status("Đang ổn định phụ đề…".to_owned());
                    }
                }
                Ok(_) => {}
                Err(error) => {
                    captions.set_status(format!("Lỗi nhận dạng: {error}"));
                }
            }
        }
        Ok(capture_ended)
    })();

    match result {
        Ok(true) if service.is_current(&running) => {
            captions.set_text(String::new());
            let error = "Nguồn audio đã dừng. Hãy chọn và bắt đầu lại nguồn audio.".to_owned();
            captions.set_status(error.clone());
            let _ = app.emit("subtitle-error", error);
        }
        Err(error) if service.is_current(&running) => {
            captions.set_status(format!("Lỗi phụ đề: {error}"));
            let _ = app.emit("subtitle-error", error);
        }
        _ => {}
    }
    service.finish(&running);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completed_old_session_cannot_clear_a_new_session() {
        let service = SubtitleService::default();
        let first = service.begin().expect("first session starts");
        service.stop();
        let second = service.begin().expect("second session starts");

        service.finish(&first);

        assert!(service.is_current(&second));
    }

    fn live_snapshot(seconds: usize, speech_seconds: usize) -> LiveAudioSnapshot {
        let mut samples = vec![0; seconds * MINIMUM_LIVE_SAMPLES];
        samples[..speech_seconds * MINIMUM_LIVE_SAMPLES].fill(1_500);
        LiveAudioSnapshot {
            first_sample: 0,
            samples,
        }
    }

    fn decode(action: LiveWindowAction) -> (LiveWindowPass, u64, usize) {
        match action {
            LiveWindowAction::Decode {
                pass,
                end_sample,
                samples,
            } => (pass, end_sample, samples.len()),
            LiveWindowAction::Flush => panic!("expected a decode window"),
        }
    }

    #[test]
    fn advances_only_after_two_seconds_of_new_audio() {
        let mut scheduler = LiveWindowScheduler::default();
        let first = live_snapshot(3, 3);
        let (pass, end_sample, samples) = decode(scheduler.next(&first).expect("first window"));

        assert_eq!(pass, LiveWindowPass::Active);
        assert_eq!(end_sample, 3 * MINIMUM_LIVE_SAMPLES as u64);
        assert_eq!(samples, 3 * MINIMUM_LIVE_SAMPLES);
        scheduler.mark_completed(end_sample);

        assert!(scheduler.next(&live_snapshot(4, 4)).is_none());

        let (_, end_sample, _) =
            decode(scheduler.next(&live_snapshot(5, 5)).expect("fresh window"));
        assert_eq!(end_sample, 5 * MINIMUM_LIVE_SAMPLES as u64);
    }

    #[test]
    fn catches_up_from_retained_history_instead_of_skipping_to_the_latest_window() {
        let mut scheduler = LiveWindowScheduler::default();
        let (_, first_end, _) = decode(scheduler.next(&live_snapshot(1, 1)).expect("first window"));
        scheduler.mark_completed(first_end);

        let (_, end_sample, _) = decode(
            scheduler
                .next(&live_snapshot(20, 20))
                .expect("backlog window"),
        );

        assert_eq!(first_end, MINIMUM_LIVE_SAMPLES as u64);
        assert_eq!(end_sample, 3 * MINIMUM_LIVE_SAMPLES as u64);
    }

    #[test]
    fn drains_before_flushing_when_speech_ends() {
        let mut scheduler = LiveWindowScheduler::default();
        let (_, first_end, _) = decode(scheduler.next(&live_snapshot(3, 3)).expect("first window"));
        scheduler.mark_completed(first_end);

        let ending = live_snapshot(5, 4);
        let (pass, final_end, _) = decode(scheduler.next(&ending).expect("final window"));

        assert_eq!(pass, LiveWindowPass::Final);
        assert_eq!(final_end, 5 * MINIMUM_LIVE_SAMPLES as u64);
        assert_eq!(scheduler.final_boundary(), Some(final_end));
        scheduler.mark_completed(final_end);

        assert!(matches!(
            scheduler.next(&ending),
            Some(LiveWindowAction::Flush)
        ));
        assert_eq!(scheduler.last_completed_end(), Some(final_end));
    }

    #[test]
    fn prefers_the_benchmarked_worker_before_accelerated_fallbacks() {
        assert_eq!(
            worker_candidates(WorkerKind::Cpu),
            [
                WorkerKind::Cpu,
                WorkerKind::Cuda,
                WorkerKind::Vulkan,
                WorkerKind::Cpu,
            ]
        );
    }

    #[test]
    fn quick_start_prefers_cuda_when_it_is_packaged() {
        let profile = quick_start_profile("model-revision", &[WorkerKind::Cpu, WorkerKind::Cuda]);

        assert_eq!(profile.worker, WorkerKind::Cuda);
    }
}

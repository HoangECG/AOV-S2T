use serde::Serialize;

const LIVE_SPEECH_FRAME_SAMPLES: usize = 16_000 / 50;
const LIVE_SPEECH_LOOKBACK_SAMPLES: usize = 16_000;
const LIVE_SPEECH_PEAK_THRESHOLD: f64 = 0.005;
const LIVE_SPEECH_RMS_THRESHOLD: f64 = 0.002;
const MIN_ACTIVE_LIVE_SPEECH_FRAMES: usize = 4;
const MIN_CONSECUTIVE_LIVE_SPEECH_FRAMES: usize = 2;
const MIN_ACTIVE_SAMPLES_PER_LIVE_SPEECH_FRAME: usize = LIVE_SPEECH_FRAME_SAMPLES / 32;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MeterState {
    Signal,
    Silent,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioLevelEvent {
    pub peak_percent: f32,
    pub rms_percent: f32,
    pub state: MeterState,
}

pub struct Meter {
    threshold: f32,
    silence_duration_ms: u64,
    last_signal_at: Option<u64>,
}

impl Meter {
    pub fn new(threshold: f32, silence_duration_ms: u64) -> Self {
        Self {
            threshold,
            silence_duration_ms,
            last_signal_at: None,
        }
    }
    pub fn update(&mut self, samples: &[i16], now_ms: u64) -> AudioLevelEvent {
        if samples.is_empty() {
            return self.no_packets(now_ms);
        }
        let normalized = samples
            .iter()
            .map(|sample| *sample as f32 / i16::MAX as f32)
            .collect::<Vec<_>>();
        let peak = normalized
            .iter()
            .fold(0.0_f32, |current, sample| current.max(sample.abs()));
        let rms = (normalized.iter().map(|sample| sample * sample).sum::<f32>()
            / normalized.len() as f32)
            .sqrt();
        if peak >= self.threshold {
            self.last_signal_at = Some(now_ms);
            return event(peak, rms, MeterState::Signal);
        }
        let state = match self.last_signal_at {
            Some(last) if now_ms.saturating_sub(last) < self.silence_duration_ms => {
                MeterState::Signal
            }
            _ => MeterState::Silent,
        };
        event(peak, rms, state)
    }
    pub fn no_packets(&mut self, _now_ms: u64) -> AudioLevelEvent {
        event(0.0, 0.0, MeterState::Unavailable)
    }
}

/// Returns true only when the most recent second contains sustained voice-like audio.
/// This is intentionally stricter than the UI meter so silent live windows never reach Whisper.
pub fn has_recent_live_speech(samples: &[i16]) -> bool {
    let start = samples.len().saturating_sub(LIVE_SPEECH_LOOKBACK_SAMPLES);
    let recent_samples = &samples[start..];
    let mut active_frames = 0;
    let mut consecutive_active_frames = 0;
    let mut longest_active_run = 0;

    for frame in recent_samples.chunks(LIVE_SPEECH_FRAME_SAMPLES) {
        if frame_has_live_speech(frame) {
            active_frames += 1;
            consecutive_active_frames += 1;
            longest_active_run = longest_active_run.max(consecutive_active_frames);
        } else {
            consecutive_active_frames = 0;
        }
    }

    active_frames >= MIN_ACTIVE_LIVE_SPEECH_FRAMES
        && longest_active_run >= MIN_CONSECUTIVE_LIVE_SPEECH_FRAMES
}

/// Locates the first sustained speech-like run in a retained live-audio history.
/// This is used only when inference first becomes ready, so a model load cannot discard
/// speech that arrived before the worker finished initializing.
pub fn first_live_speech_sample(samples: &[i16]) -> Option<usize> {
    let mut consecutive_active_frames = 0;
    let mut run_start = 0;

    for (index, frame) in samples.chunks(LIVE_SPEECH_FRAME_SAMPLES).enumerate() {
        if frame_has_live_speech(frame) {
            if consecutive_active_frames == 0 {
                run_start = index * LIVE_SPEECH_FRAME_SAMPLES;
            }
            consecutive_active_frames += 1;
            if consecutive_active_frames >= MIN_CONSECUTIVE_LIVE_SPEECH_FRAMES {
                return Some(run_start);
            }
        } else {
            consecutive_active_frames = 0;
        }
    }

    None
}

fn frame_has_live_speech(frame: &[i16]) -> bool {
    if frame.is_empty() {
        return false;
    }

    let mut peak = 0.0_f64;
    let mut sum_squares = 0.0_f64;
    let mut active_samples = 0;
    for sample in frame {
        let normalized = *sample as f64 / i16::MAX as f64;
        peak = peak.max(normalized.abs());
        sum_squares += normalized * normalized;
        if normalized.abs() >= LIVE_SPEECH_PEAK_THRESHOLD {
            active_samples += 1;
        }
    }
    let rms = (sum_squares / frame.len() as f64).sqrt();

    peak >= LIVE_SPEECH_PEAK_THRESHOLD
        && rms >= LIVE_SPEECH_RMS_THRESHOLD
        && active_samples >= MIN_ACTIVE_SAMPLES_PER_LIVE_SPEECH_FRAME
}

fn event(peak: f32, rms: f32, state: MeterState) -> AudioLevelEvent {
    AudioLevelEvent {
        peak_percent: (peak * 100.0).clamp(0.0, 100.0),
        rms_percent: (rms * 100.0).clamp(0.0, 100.0),
        state,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ignores_silence_and_low_level_hiss() {
        assert!(!has_recent_live_speech(&vec![0; 16_000 * 8]));
        assert!(!has_recent_live_speech(&vec![100; 16_000]));
    }

    #[test]
    fn ignores_isolated_spikes() {
        let mut samples = vec![0; 16_000];
        for frame in 0..8 {
            samples[frame * LIVE_SPEECH_FRAME_SAMPLES] = 2_000;
        }

        assert!(!has_recent_live_speech(&samples));
    }

    #[test]
    fn accepts_recent_sustained_voice_like_audio() {
        let mut samples = vec![0; 16_000];
        let start = samples.len() - LIVE_SPEECH_FRAME_SAMPLES * 4;
        samples[start..].fill(200);

        assert!(has_recent_live_speech(&samples));
    }

    #[test]
    fn finds_the_start_of_sustained_speech() {
        let mut samples = vec![0; 16_000];
        let start = LIVE_SPEECH_FRAME_SAMPLES * 7;
        samples[start..start + LIVE_SPEECH_FRAME_SAMPLES * 3].fill(1_500);

        assert_eq!(first_live_speech_sample(&samples), Some(start));
    }

    #[test]
    fn rejects_voice_that_is_only_in_the_old_part_of_the_buffer() {
        let mut samples = vec![0; 16_000 * 8];
        samples[..LIVE_SPEECH_FRAME_SAMPLES * 10].fill(1_500);

        assert!(!has_recent_live_speech(&samples));
    }
}

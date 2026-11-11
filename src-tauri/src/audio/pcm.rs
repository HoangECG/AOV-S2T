use super::source::AudioCommandError;

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SampleEncoding {
    Float,
    Integer { bits: u16 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PcmFormat {
    pub sample_rate: u32,
    pub channels: u16,
    pub encoding: SampleEncoding,
}

impl PcmFormat {
    pub fn float(sample_rate: u32, channels: u16) -> Self {
        Self {
            sample_rate,
            channels,
            encoding: SampleEncoding::Float,
        }
    }
    pub fn integer(sample_rate: u32, channels: u16, bits: u16) -> Self {
        Self {
            sample_rate,
            channels,
            encoding: SampleEncoding::Integer { bits },
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PcmFrame {
    pub sample_rate: u32,
    pub channels: u16,
    pub samples: Vec<i16>,
}

pub trait SampleValue {
    fn to_normalized(self) -> f32;
}
impl SampleValue for f32 {
    fn to_normalized(self) -> f32 {
        self
    }
}
impl SampleValue for i16 {
    fn to_normalized(self) -> f32 {
        self as f32 / i16::MAX as f32
    }
}

pub fn normalize<T: Copy + SampleValue>(
    interleaved: &[T],
    format: PcmFormat,
) -> Result<PcmFrame, AudioCommandError> {
    if format.channels == 0 || format.sample_rate == 0 {
        return Err(format_error("zero channel count or sample rate"));
    }
    if !matches!(
        format.encoding,
        SampleEncoding::Float | SampleEncoding::Integer { bits: 16 | 24 | 32 }
    ) {
        return Err(format_error("unsupported endpoint sample encoding"));
    }
    let channels = format.channels as usize;
    if interleaved.len() % channels != 0 {
        return Err(format_error("incomplete endpoint audio frame"));
    }
    let mono: Vec<f32> = interleaved
        .chunks_exact(channels)
        .map(|frame| {
            frame
                .iter()
                .map(|sample| sample.to_normalized())
                .sum::<f32>()
                / channels as f32
        })
        .collect();
    let output_len = mono
        .len()
        .saturating_mul(TARGET_SAMPLE_RATE as usize)
        .div_ceil(format.sample_rate as usize);
    let samples = (0..output_len)
        .map(|index| {
            let position = index as f64 * format.sample_rate as f64 / TARGET_SAMPLE_RATE as f64;
            let left = position.floor() as usize;
            let right = (left + 1).min(mono.len().saturating_sub(1));
            let fraction = (position - left as f64) as f32;
            let value = mono.get(left).copied().unwrap_or_default() * (1.0 - fraction)
                + mono.get(right).copied().unwrap_or_default() * fraction;
            (value.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
        })
        .collect();
    Ok(PcmFrame {
        sample_rate: TARGET_SAMPLE_RATE,
        channels: 1,
        samples,
    })
}

pub fn decode_interleaved(bytes: &[u8], format: PcmFormat) -> Result<Vec<f32>, AudioCommandError> {
    let sample_bytes = match format.encoding {
        SampleEncoding::Float | SampleEncoding::Integer { bits: 32 } => 4,
        SampleEncoding::Integer { bits: 16 } => 2,
        SampleEncoding::Integer { bits: 24 } => 3,
        SampleEncoding::Integer { .. } => {
            return Err(format_error("unsupported endpoint integer width"))
        }
    };
    if bytes.len() % (sample_bytes * format.channels as usize) != 0 {
        return Err(format_error(
            "capture packet does not align to endpoint format",
        ));
    }
    Ok(bytes
        .chunks_exact(sample_bytes)
        .map(|sample| match format.encoding {
            SampleEncoding::Float => {
                f32::from_le_bytes(sample.try_into().expect("float sample width checked"))
            }
            SampleEncoding::Integer { bits: 16 } => {
                i16::from_le_bytes(sample.try_into().expect("i16 sample width checked")) as f32
                    / i16::MAX as f32
            }
            SampleEncoding::Integer { bits: 24 } => {
                i32::from_le_bytes([
                    sample[0],
                    sample[1],
                    sample[2],
                    if sample[2] & 0x80 != 0 { 0xff } else { 0 },
                ]) as f32
                    / 8_388_607.0
            }
            SampleEncoding::Integer { bits: 32 } => {
                i32::from_le_bytes(sample.try_into().expect("i32 sample width checked")) as f32
                    / i32::MAX as f32
            }
            SampleEncoding::Integer { .. } => unreachable!("unsupported widths return above"),
        })
        .collect())
}

fn format_error(technical_detail: &str) -> AudioCommandError {
    AudioCommandError::Unavailable {
        technical_detail: technical_detail.to_owned(),
    }
}

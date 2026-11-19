//! Deterministic offline PCM audio engine foundation for Aura Voice Studio.
//!
//! The first engine slice deliberately focuses on reliable file rendering:
//! decode PCM/IEEE-float WAV, arrange clips at exact sample-frame positions,
//! mix tracks in floating point, meter the result, and export integer PCM WAV.
//! Realtime device I/O is isolated in CPAL-backed capture and output
//! modules. Capture writes to a preallocated SPSC ring; output can either
//! audition a decoded WAV or mix an immutable multitrack session snapshot
//! directly in the callback. Neither callback performs file I/O.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicPtr, Ordering};

pub mod device_io;
use std::error::Error;
use std::fmt;

const MIN_SAMPLE_RATE: u32 = 8_000;
const MAX_SAMPLE_RATE: u32 = 384_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioError {
    InvalidArgument(String),
    InvalidWave(String),
    UnsupportedWaveFormat { format: u16, bits_per_sample: u16 },
    UnsupportedChannelCount(u16),
    MissingWaveChunk(&'static str),
    AssetNotFound(String),
    SampleRateMismatch { asset_rate: u32, session_rate: u32 },
    SizeOverflow,
}

impl fmt::Display for AudioError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArgument(message) => write!(f, "invalid argument: {message}"),
            Self::InvalidWave(message) => write!(f, "invalid WAV file: {message}"),
            Self::UnsupportedWaveFormat { format, bits_per_sample } => {
                write!(f, "unsupported WAV format {format} at {bits_per_sample} bits")
            }
            Self::UnsupportedChannelCount(channels) => {
                write!(f, "unsupported channel count: {channels}")
            }
            Self::MissingWaveChunk(chunk) => write!(f, "WAV is missing the {chunk} chunk"),
            Self::AssetNotFound(id) => write!(f, "audio asset not found: {id}"),
            Self::SampleRateMismatch { asset_rate, session_rate } => write!(
                f,
                "sample-rate mismatch: asset is {asset_rate} Hz, session is {session_rate} Hz"
            ),
            Self::SizeOverflow => write!(f, "audio data is too large to represent safely"),
        }
    }
}

impl Error for AudioError {}

#[derive(Debug, Clone, PartialEq)]
pub struct AudioBuffer {
    sample_rate: u32,
    channels: u16,
    samples: Vec<f32>,
}

impl AudioBuffer {
    /// Creates an interleaved mono or stereo floating-point buffer.
    pub fn new(sample_rate: u32, channels: u16, samples: Vec<f32>) -> Result<Self, AudioError> {
        validate_audio_format(sample_rate, channels)?;
        if samples.len() % usize::from(channels) != 0 {
            return Err(AudioError::InvalidArgument(
                "interleaved sample count must be divisible by channel count".into(),
            ));
        }
        if samples.iter().any(|sample| !sample.is_finite()) {
            return Err(AudioError::InvalidArgument(
                "audio samples must be finite floating-point values".into(),
            ));
        }
        Ok(Self { sample_rate, channels, samples })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    pub fn samples(&self) -> &[f32] {
        &self.samples
    }

    /// Consumes the decoded buffer and transfers its sample allocation.
    pub fn into_samples(self) -> Vec<f32> {
        self.samples
    }

    pub fn frame_count(&self) -> u64 {
        (self.samples.len() / usize::from(self.channels)) as u64
    }

    /// Decodes uncompressed PCM WAV (8/16/24/32-bit) or IEEE float32 WAV.
    pub fn from_wav(bytes: &[u8]) -> Result<Self, AudioError> {
        let (format, channels, sample_rate, bits_per_sample, data) = parse_wav(bytes)?;
        validate_audio_format(sample_rate, channels)?;
        if !matches!(
            (format, bits_per_sample),
            (1, 8) | (1, 16) | (1, 24) | (1, 32) | (3, 32)
        ) {
            return Err(AudioError::UnsupportedWaveFormat {
                format,
                bits_per_sample,
            });
        }

        let bytes_per_sample = usize::from(bits_per_sample / 8);
        if data.len() % bytes_per_sample != 0 {
            return Err(AudioError::InvalidWave(
                "data chunk ends in a partial sample".into(),
            ));
        }
        let expected_block = usize::from(channels) * bytes_per_sample;
        if data.len() % expected_block != 0 {
            return Err(AudioError::InvalidWave(
                "data chunk ends in a partial audio frame".into(),
            ));
        }

        let mut samples = Vec::with_capacity(data.len() / bytes_per_sample);
        for sample_bytes in data.chunks_exact(bytes_per_sample) {
            let sample = match (format, bits_per_sample) {
                (1, 8) => (f32::from(sample_bytes[0]) - 128.0) / 128.0,
                (1, 16) => {
                    let value = i16::from_le_bytes([sample_bytes[0], sample_bytes[1]]);
                    f32::from(value) / 32_768.0
                }
                (1, 24) => {
                    let raw = u32::from(sample_bytes[0])
                        | (u32::from(sample_bytes[1]) << 8)
                        | (u32::from(sample_bytes[2]) << 16);
                    let signed = if raw & 0x0080_0000 != 0 {
                        (raw | 0xFF00_0000) as i32
                    } else {
                        raw as i32
                    };
                    signed as f32 / 8_388_608.0
                }
                (1, 32) => {
                    let value = i32::from_le_bytes([
                        sample_bytes[0], sample_bytes[1], sample_bytes[2], sample_bytes[3],
                    ]);
                    value as f64 as f32 / 2_147_483_648.0
                }
                (3, 32) => {
                    let value = f32::from_le_bytes([
                        sample_bytes[0], sample_bytes[1], sample_bytes[2], sample_bytes[3],
                    ]);
                    if !value.is_finite() {
                        return Err(AudioError::InvalidWave(
                            "IEEE-float WAV contains NaN or infinity".into(),
                        ));
                    }
                    value
                }
                _ => return Err(AudioError::UnsupportedWaveFormat {
                    format,
                    bits_per_sample,
                }),
            };
            samples.push(sample);
        }

        Self::new(sample_rate, channels, samples)
    }

    /// Encodes this buffer as integer PCM WAV at 16, 24 or 32 bits per sample.
    /// Samples are hard-clipped to [-1.0, 1.0] at the file boundary.
    pub fn to_wav_pcm(&self, bit_depth: u16) -> Result<Vec<u8>, AudioError> {
        if ![16, 24, 32].contains(&bit_depth) {
            return Err(AudioError::InvalidArgument(
                "WAV export bit depth must be 16, 24 or 32".into(),
            ));
        }
        validate_audio_format(self.sample_rate, self.channels)?;

        let bytes_per_sample = usize::from(bit_depth / 8);
        let block_align = usize::from(self.channels)
            .checked_mul(bytes_per_sample)
            .ok_or(AudioError::SizeOverflow)?;
        let data_size = self.samples.len()
            .checked_mul(bytes_per_sample)
            .ok_or(AudioError::SizeOverflow)?;
        let data_size_u32 = u32::try_from(data_size).map_err(|_| AudioError::SizeOverflow)?;
        let riff_size = data_size_u32.checked_add(36).ok_or(AudioError::SizeOverflow)?;
        let byte_rate = self.sample_rate
            .checked_mul(u32::try_from(block_align).map_err(|_| AudioError::SizeOverflow)?)
            .ok_or(AudioError::SizeOverflow)?;

        let output_capacity = data_size.checked_add(44).ok_or(AudioError::SizeOverflow)?;
        let mut output = Vec::with_capacity(output_capacity);
        output.extend_from_slice(b"RIFF");
        output.extend_from_slice(&riff_size.to_le_bytes());
        output.extend_from_slice(b"WAVE");
        output.extend_from_slice(b"fmt ");
        output.extend_from_slice(&16_u32.to_le_bytes());
        output.extend_from_slice(&1_u16.to_le_bytes());
        output.extend_from_slice(&self.channels.to_le_bytes());
        output.extend_from_slice(&self.sample_rate.to_le_bytes());
        output.extend_from_slice(&byte_rate.to_le_bytes());
        output.extend_from_slice(
            &u16::try_from(block_align).map_err(|_| AudioError::SizeOverflow)?.to_le_bytes(),
        );
        output.extend_from_slice(&bit_depth.to_le_bytes());
        output.extend_from_slice(b"data");
        output.extend_from_slice(&data_size_u32.to_le_bytes());

        for &raw in &self.samples {
            let sample = raw.clamp(-1.0, 1.0);
            match bit_depth {
                16 => {
                    let quantized = if sample <= -1.0 {
                        i16::MIN
                    } else {
                        (f64::from(sample) * 32_767.0).round() as i16
                    };
                    output.extend_from_slice(&quantized.to_le_bytes());
                }
                24 => {
                    let quantized = if sample <= -1.0 {
                        -8_388_608_i32
                    } else {
                        (f64::from(sample) * 8_388_607.0).round() as i32
                    };
                    let encoded = quantized.to_le_bytes();
                    output.extend_from_slice(&encoded[..3]);
                }
                32 => {
                    let quantized = if sample <= -1.0 {
                        i32::MIN
                    } else {
                        (f64::from(sample) * 2_147_483_647.0).round() as i32
                    };
                    output.extend_from_slice(&quantized.to_le_bytes());
                }
                _ => unreachable!("bit depth is validated above"),
            }
        }
        Ok(output)
    }
}

fn validate_audio_format(sample_rate: u32, channels: u16) -> Result<(), AudioError> {
    if !(MIN_SAMPLE_RATE..=MAX_SAMPLE_RATE).contains(&sample_rate) {
        return Err(AudioError::InvalidArgument(format!(
            "sample rate must be between {MIN_SAMPLE_RATE} and {MAX_SAMPLE_RATE} Hz"
        )));
    }
    if !(1..=2).contains(&channels) {
        return Err(AudioError::UnsupportedChannelCount(channels));
    }
    Ok(())
}

fn read_u16(bytes: &[u8], offset: usize) -> Result<u16, AudioError> {
    let chunk = bytes.get(offset..offset + 2)
        .ok_or_else(|| AudioError::InvalidWave("truncated 16-bit field".into()))?;
    Ok(u16::from_le_bytes([chunk[0], chunk[1]]))
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, AudioError> {
    let chunk = bytes.get(offset..offset + 4)
        .ok_or_else(|| AudioError::InvalidWave("truncated 32-bit field".into()))?;
    Ok(u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
}

fn parse_wav(bytes: &[u8]) -> Result<(u16, u16, u32, u16, &[u8]), AudioError> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(AudioError::InvalidWave("missing RIFF/WAVE header".into()));
    }
    let riff_end = usize::try_from(read_u32(bytes, 4)?)
        .map_err(|_| AudioError::SizeOverflow)?
        .checked_add(8)
        .ok_or(AudioError::SizeOverflow)?;
    if riff_end > bytes.len() || riff_end < 12 {
        return Err(AudioError::InvalidWave("RIFF size exceeds available data".into()));
    }

    let mut format: Option<(u16, u16, u32, u16)> = None;
    let mut audio_data: Option<&[u8]> = None;
    let mut offset = 12_usize;

    while offset.checked_add(8).ok_or(AudioError::SizeOverflow)? <= riff_end {
        let header = bytes.get(offset..offset + 8)
            .ok_or_else(|| AudioError::InvalidWave("truncated chunk header".into()))?;
        let chunk_size = usize::try_from(u32::from_le_bytes([
            header[4], header[5], header[6], header[7],
        ])).map_err(|_| AudioError::SizeOverflow)?;
        let chunk_start = offset.checked_add(8).ok_or(AudioError::SizeOverflow)?;
        let chunk_end = chunk_start.checked_add(chunk_size).ok_or(AudioError::SizeOverflow)?;
        if chunk_end > riff_end {
            return Err(AudioError::InvalidWave("chunk exceeds RIFF boundary".into()));
        }

        match &header[0..4] {
            b"fmt " => {
                if chunk_size < 16 {
                    return Err(AudioError::InvalidWave("fmt chunk is shorter than 16 bytes".into()));
                }
                let format_tag = read_u16(bytes, chunk_start)?;
                let channel_count = read_u16(bytes, chunk_start + 2)?;
                let sample_rate = read_u32(bytes, chunk_start + 4)?;
                let byte_rate = read_u32(bytes, chunk_start + 8)?;
                let actual_align = read_u16(bytes, chunk_start + 12)?;
                let bits_per_sample = read_u16(bytes, chunk_start + 14)?;
                let expected_align = channel_count
                    .checked_mul(bits_per_sample / 8)
                    .ok_or(AudioError::SizeOverflow)?;
                let expected_byte_rate = sample_rate
                    .checked_mul(u32::from(expected_align))
                    .ok_or(AudioError::SizeOverflow)?;
                if expected_align != actual_align || expected_byte_rate != byte_rate {
                    return Err(AudioError::InvalidWave("inconsistent WAV byte rate or block alignment".into()));
                }
                format = Some((format_tag, channel_count, sample_rate, bits_per_sample));
            }
            b"data" if audio_data.is_none() => {
                audio_data = Some(&bytes[chunk_start..chunk_end]);
            }
            _ => {}
        }

        offset = chunk_end.checked_add(chunk_size & 1).ok_or(AudioError::SizeOverflow)?;
    }

    let (format_tag, channels, sample_rate, bits_per_sample) =
        format.ok_or(AudioError::MissingWaveChunk("fmt"))?;
    let data = audio_data.ok_or(AudioError::MissingWaveChunk("data"))?;
    Ok((format_tag, channels, sample_rate, bits_per_sample, data))
}

#[derive(Debug, Clone, PartialEq)]
pub struct Clip {
    pub id: String,
    pub media_id: String,
    pub start_frame: u64,
    pub source_start_frame: u64,
    pub duration_frames: u64,
    pub gain: f32,
    /// -1.0 is left, 0.0 is centre and 1.0 is right.
    pub pan: f32,
    pub muted: bool,
    pub fade_in_frames: u64,
    pub fade_out_frames: u64,
}

impl Clip {
    pub fn new(id: impl Into<String>, media_id: impl Into<String>, start_frame: u64,
        source_start_frame: u64, duration_frames: u64) -> Self {
        Self {
            id: id.into(),
            media_id: media_id.into(),
            start_frame,
            source_start_frame,
            duration_frames,
            gain: 1.0,
            pan: 0.0,
            muted: false,
            fade_in_frames: 0,
            fade_out_frames: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Track {
    pub id: String,
    pub gain: f32,
    pub pan: f32,
    pub muted: bool,
    pub solo: bool,
    /// One-pole high-pass cutoff in Hz; 0 disables the filter.
    pub high_pass_hz: f32,
    /// Linked stereo compressor threshold in linear amplitude; 1 disables it.
    pub compressor_threshold: f32,
    /// Compressor ratio; 1 disables compression.
    pub compressor_ratio: f32,
    pub clips: Vec<Clip>,
}

impl Track {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            gain: 1.0,
            pan: 0.0,
            muted: false,
            solo: false,
            high_pass_hz: 0.0,
            compressor_threshold: 1.0,
            compressor_ratio: 1.0,
            clips: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MixSession {
    pub sample_rate: u32,
    pub channels: u16,
    pub master_gain: f32,
    pub tracks: Vec<Track>,
}

impl MixSession {
    pub fn new(sample_rate: u32, channels: u16) -> Self {
        Self { sample_rate, channels, master_gain: 1.0, tracks: Vec::new() }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RenderReport {
    pub audio: AudioBuffer,
    /// Sample peak before export clipping; this is not an oversampled true-peak meter.
    pub sample_peak: f32,
    /// Number of interleaved samples whose magnitude exceeds full scale.
    pub clipped_samples: usize,
}

impl RenderReport {
    pub fn to_wav_pcm(&self, bit_depth: u16) -> Result<Vec<u8>, AudioError> {
        self.audio.to_wav_pcm(bit_depth)
    }
}

/// Renders a non-destructive session to an interleaved floating-point mix.
///
/// All media must already be decoded to the session sample rate. No hidden
/// resampling or loudness normalization is performed.
pub fn render_mix(
    session: &MixSession,
    assets: &HashMap<String, AudioBuffer>,
) -> Result<RenderReport, AudioError> {
    validate_audio_format(session.sample_rate, session.channels)?;
    if !session.master_gain.is_finite() || session.master_gain < 0.0 {
        return Err(AudioError::InvalidArgument("master gain must be finite and non-negative".into()));
    }
    let has_solo = session.tracks.iter().any(|track| track.solo && !track.muted);
    let mut resolved: Vec<(&Track, Vec<(&Clip, &AudioBuffer)>)> = Vec::new();
    let mut output_frames = 0_u64;

    for track in &session.tracks {
        if track.id.trim().is_empty() {
            return Err(AudioError::InvalidArgument("track id must not be empty".into()));
        }
        if !track.gain.is_finite() || track.gain < 0.0 || !track.pan.is_finite()
            || !(-1.0..=1.0).contains(&track.pan) {
            return Err(AudioError::InvalidArgument(format!("track {} has invalid gain or pan", track.id)));
        }
        let audible = !track.muted && (!has_solo || track.solo);
        let mut track_clips = Vec::new();
        if audible {
            for clip in &track.clips {
                if clip.id.trim().is_empty() || clip.media_id.trim().is_empty()
                    || clip.duration_frames == 0 || !clip.gain.is_finite() || clip.gain < 0.0
                    || !clip.pan.is_finite() || !(-1.0..=1.0).contains(&clip.pan) {
                    return Err(AudioError::InvalidArgument(format!("track {} contains an invalid clip", track.id)));
                }
                if clip.muted {
                    continue;
                }
                let asset = assets.get(&clip.media_id)
                    .ok_or_else(|| AudioError::AssetNotFound(clip.media_id.clone()))?;
                if asset.sample_rate != session.sample_rate {
                    return Err(AudioError::SampleRateMismatch {
                        asset_rate: asset.sample_rate,
                        session_rate: session.sample_rate,
                    });
                }
                let source_end = clip.source_start_frame.checked_add(clip.duration_frames)
                    .ok_or(AudioError::SizeOverflow)?;
                if source_end > asset.frame_count() {
                    return Err(AudioError::InvalidArgument(format!(
                        "clip {} reads beyond the end of asset {}", clip.id, clip.media_id
                    )));
                }
                let timeline_end = clip.start_frame.checked_add(clip.duration_frames)
                    .ok_or(AudioError::SizeOverflow)?;
                output_frames = output_frames.max(timeline_end);
                track_clips.push((clip, asset));
            }
        }
        resolved.push((track, track_clips));
    }

    let frame_count = usize::try_from(output_frames).map_err(|_| AudioError::SizeOverflow)?;
    let sample_count = frame_count.checked_mul(usize::from(session.channels))
        .ok_or(AudioError::SizeOverflow)?;
    let mut mixed = vec![0.0_f32; sample_count];

    for (track, clips) in resolved {
        for (clip, asset) in clips {
            let total_gain = track.gain * clip.gain * session.master_gain;
            let combined_pan = (track.pan + clip.pan).clamp(-1.0, 1.0);
            let duration = clip.duration_frames;
            for offset in 0..duration {
                let source_frame = clip.source_start_frame + offset;
                let destination_frame = clip.start_frame + offset;
                let fade = fade_envelope(offset, duration, clip.fade_in_frames, clip.fade_out_frames);
                let gain = total_gain * fade;
                let source_index = usize::try_from(source_frame)
                    .map_err(|_| AudioError::SizeOverflow)? * usize::from(asset.channels);
                let destination_index = usize::try_from(destination_frame)
                    .map_err(|_| AudioError::SizeOverflow)? * usize::from(session.channels);

                match (asset.channels, session.channels) {
                    (1, 1) => {
                        mixed[destination_index] += asset.samples[source_index] * gain;
                    }
                    (1, 2) => {
                        let angle = (f64::from(combined_pan) + 1.0) * std::f64::consts::FRAC_PI_4;
                        mixed[destination_index] += asset.samples[source_index] * gain * angle.cos() as f32;
                        mixed[destination_index + 1] += asset.samples[source_index] * gain * angle.sin() as f32;
                    }
                    (2, 1) => {
                        let mono = (asset.samples[source_index] + asset.samples[source_index + 1]) * 0.5;
                        mixed[destination_index] += mono * gain;
                    }
                    (2, 2) => {
                        let left = asset.samples[source_index];
                        let right = asset.samples[source_index + 1];
                        let left_gain = if combined_pan > 0.0 {
                            (f64::from(combined_pan) * std::f64::consts::FRAC_PI_2).cos() as f32
                        } else { 1.0 };
                        let right_gain = if combined_pan < 0.0 {
                            (f64::from(-combined_pan) * std::f64::consts::FRAC_PI_2).cos() as f32
                        } else { 1.0 };
                        mixed[destination_index] += left * gain * left_gain;
                        mixed[destination_index + 1] += right * gain * right_gain;
                    }
                    _ => unreachable!("audio buffers and sessions are validated as mono or stereo"),
                }
            }
        }
    }

    let mut sample_peak = 0.0_f32;
    let mut clipped_samples = 0_usize;
    for sample in &mixed {
        if !sample.is_finite() {
            return Err(AudioError::InvalidArgument("mix produced a non-finite sample".into()));
        }
        sample_peak = sample_peak.max(sample.abs());
        if sample.abs() > 1.0 {
            clipped_samples += 1;
        }
    }

    Ok(RenderReport {
        audio: AudioBuffer::new(session.sample_rate, session.channels, mixed)?,
        sample_peak,
        clipped_samples,
    })
}

fn fade_envelope(offset: u64, duration: u64, fade_in: u64, fade_out: u64) -> f32 {
    let mut envelope = 1.0_f64;
    if fade_in > 0 && offset < fade_in {
        envelope *= offset as f64 / fade_in as f64;
    }
    if fade_out > 0 && offset >= duration.saturating_sub(fade_out) {
        let fade_offset = offset - duration.saturating_sub(fade_out);
        envelope *= (fade_out.saturating_sub(fade_offset + 1)) as f64 / fade_out as f64;
    }
    envelope.clamp(0.0, 1.0) as f32
}


/// Immutable, pre-resolved session snapshot for the realtime output callback.
///
/// All WAV decoding, validation, allocation and pan/fade coefficient work
/// happens before the stream starts. The callback only reads these buffers
/// and accumulates one sample frame; it never allocates or locks.
#[derive(Clone)]
struct RealtimeClip {
    track_index: usize,
    start_frame: usize,
    source_start_frame: usize,
    duration_frames: usize,
    source_channels: usize,
    asset: Arc<AudioBuffer>,
    gain: f32,
    left_pan_gain: f32,
    right_pan_gain: f32,
    fade_in_frames: usize,
    fade_out_frames: usize,
}

#[derive(Clone)]
struct RealtimeTrack {
    gain: f32,
    high_pass_alpha: f32,
    compressor_threshold: f32,
    compressor_ratio: f32,
}

#[derive(Clone, Copy)]
struct ClipEvent {
    frame: usize,
    clip_index: usize,
    is_start: bool,
}

/// Limits allow the callback to keep all working memory preallocated even
/// when a new session graph is published while playback is active.
pub(crate) const MAX_REALTIME_TRACKS: usize = 256;
pub(crate) const MAX_REALTIME_CLIPS: usize = 16_384;
pub(crate) const MAX_REALTIME_BLOCK_FRAMES: usize = 1024;

struct RealtimeGraphOwners {
    current: Arc<RealtimeMixer>,
    retired: Vec<Arc<RealtimeMixer>>,
}

/// Read-mostly graph publisher. The audio thread uses an atomic pointer plus a
/// single-reader hazard pointer; writers retain old snapshots until the audio
/// callback has moved to a newer graph. The callback never locks or increments
/// reference counts.
pub(crate) struct RealtimeGraph {
    current: AtomicPtr<RealtimeMixer>,
    hazard: AtomicPtr<RealtimeMixer>,
    owners: Mutex<RealtimeGraphOwners>,
}

pub(crate) struct RealtimeMixerGuard<'a> {
    graph: &'a RealtimeGraph,
    pointer: *mut RealtimeMixer,
}

impl RealtimeMixerGuard<'_> {
    pub(crate) fn mixer(&self) -> &RealtimeMixer {
        // SAFETY: The hazard pointer pins this graph snapshot until Guard::drop.
        unsafe { &*self.pointer }
    }
}

impl Drop for RealtimeMixerGuard<'_> {
    fn drop(&mut self) {
        self.graph.hazard.store(ptr::null_mut(), Ordering::SeqCst);
    }
}

impl RealtimeGraph {
    pub(crate) fn new(initial: Arc<RealtimeMixer>) -> Arc<Self> {
        let pointer = Arc::as_ptr(&initial) as *mut RealtimeMixer;
        Arc::new(Self {
            current: AtomicPtr::new(pointer),
            hazard: AtomicPtr::new(ptr::null_mut()),
            owners: Mutex::new(RealtimeGraphOwners {
                current: initial,
                retired: Vec::new(),
            }),
        })
    }

    /// Lock-free callback-side snapshot access. A graph cannot be reclaimed
    /// between pointer validation and the end of this guard's lifetime.
    pub(crate) fn load(&self) -> RealtimeMixerGuard<'_> {
        loop {
            let pointer = self.current.load(Ordering::SeqCst);
            self.hazard.store(pointer, Ordering::SeqCst);
            if self.current.load(Ordering::SeqCst) == pointer {
                return RealtimeMixerGuard {
                    graph: self,
                    pointer,
                };
            }
            self.hazard.store(ptr::null_mut(), Ordering::SeqCst);
        }
    }

    /// Publishes a complete prepared graph. The callback notices the pointer
    /// change at the next block boundary and rebuilds its active-clip schedule
    /// at the current sample frame.
    pub(crate) fn publish(
        &self,
        next: Arc<RealtimeMixer>,
    ) -> Result<(), AudioError> {
        let mut owners = self
            .owners
            .lock()
            .map_err(|_| AudioError::InvalidArgument(
                "realtime graph publisher lock is poisoned".into(),
            ))?;
        if next.sample_rate != owners.current.sample_rate
            || next.channels != owners.current.channels
        {
            return Err(AudioError::InvalidArgument(
                "live graph updates must keep the current sample rate and channel layout".into(),
            ));
        }

        let next_pointer = Arc::as_ptr(&next) as *mut RealtimeMixer;
        let previous = std::mem::replace(&mut owners.current, next);
        self.current.store(next_pointer, Ordering::SeqCst);
        owners.retired.push(previous);

        let protected = self.hazard.load(Ordering::SeqCst);
        owners
            .retired
            .retain(|snapshot| Arc::as_ptr(snapshot) as *mut RealtimeMixer == protected);
        Ok(())
    }
}

/// Immutable, sample-time-sorted playback plan. The callback visits only
/// currently active clips, not every clip in the project, for each frame.
pub(crate) struct RealtimeMixer {
    pub(crate) sample_rate: u32,
    pub(crate) channels: u16,
    pub(crate) total_frames: u64,
    tracks: Vec<RealtimeTrack>,
    clips: Vec<RealtimeClip>,
    events: Vec<ClipEvent>,
    master_gain: f32,
}

/// Callback-owned state. All vectors are allocated before CPAL starts.
pub(crate) struct RealtimeRenderState {
    active_clips: Vec<usize>,
    event_cursor: usize,
    next_frame: Option<usize>,
    graph_identity: usize,
    track_scratch: Vec<f32>,
    filter_state: Vec<f32>,
    compressor_envelope: Vec<f32>,
}

impl RealtimeRenderState {
    pub(crate) fn new() -> Self {
        Self {
            active_clips: Vec::with_capacity(MAX_REALTIME_CLIPS),
            event_cursor: 0,
            next_frame: None,
            graph_identity: 0,
            track_scratch: vec![0.0; MAX_REALTIME_TRACKS * 2],
            filter_state: vec![0.0; MAX_REALTIME_TRACKS * 4],
            compressor_envelope: vec![0.0; MAX_REALTIME_TRACKS],
        }
    }

    fn apply_event(&mut self, event: ClipEvent) {
        if event.is_start {
            if self.active_clips.len() < self.active_clips.capacity() {
                self.active_clips.push(event.clip_index);
            }
        } else if let Some(index) = self
            .active_clips
            .iter()
            .position(|active| *active == event.clip_index)
        {
            self.active_clips.swap_remove(index);
        }
    }

    fn reset_for(&mut self, mixer: &RealtimeMixer, start_frame: usize) {
        self.active_clips.clear();
        self.event_cursor = 0;
        while let Some(event) = mixer.events.get(self.event_cursor).copied() {
            if event.frame >= start_frame {
                break;
            }
            self.apply_event(event);
            self.event_cursor += 1;
        }
        self.filter_state.fill(0.0);
        self.compressor_envelope.fill(0.0);
        self.graph_identity = mixer as *const RealtimeMixer as usize;
        self.next_frame = Some(start_frame);
    }
}

impl RealtimeMixer {
    /// Mixes a contiguous block at exact timeline frames. The callback state
    /// maintains the active-clip set across blocks and rebuilds it only after
    /// a seek, loop wrap or graph replacement. No memory is allocated here.
    pub(crate) fn render_block(
        &self,
        state: &mut RealtimeRenderState,
        start_frame: usize,
        output: &mut [f32],
    ) {
        let channels = usize::from(self.channels);
        if channels == 0 {
            output.fill(0.0);
            return;
        }
        let frames = output.len() / channels;
        let identity = self as *const RealtimeMixer as usize;
        if state.graph_identity != identity || state.next_frame != Some(start_frame) {
            state.reset_for(self, start_frame);
        }

        let attack_coefficient =
            1.0 - (-1.0 / (0.010 * self.sample_rate as f32)).exp();
        let release_coefficient =
            1.0 - (-1.0 / (0.100 * self.sample_rate as f32)).exp();

        for output_frame in 0..frames {
            let timeline_frame = start_frame.saturating_add(output_frame);
            while let Some(event) = self.events.get(state.event_cursor).copied() {
                if event.frame > timeline_frame {
                    break;
                }
                state.apply_event(event);
                state.event_cursor += 1;
            }

            state.track_scratch[..self.tracks.len() * 2].fill(0.0);
            for active_index in state.active_clips.iter().copied() {
                let clip = &self.clips[active_index];
                let offset = timeline_frame - clip.start_frame;
                if offset >= clip.duration_frames {
                    continue;
                }
                let source_frame = clip.source_start_frame + offset;
                let source_index = source_frame * clip.source_channels;
                let fade = fade_envelope(
                    offset as u64,
                    clip.duration_frames as u64,
                    clip.fade_in_frames as u64,
                    clip.fade_out_frames as u64,
                );
                let gain = self.tracks[clip.track_index].gain * clip.gain * fade;
                let track_offset = clip.track_index * 2;
                match (clip.source_channels, channels) {
                    (1, 1) => {
                        state.track_scratch[track_offset] +=
                            clip.asset.samples()[source_index] * gain;
                    }
                    (1, 2) => {
                        let sample = clip.asset.samples()[source_index] * gain;
                        state.track_scratch[track_offset] += sample * clip.left_pan_gain;
                        state.track_scratch[track_offset + 1] += sample * clip.right_pan_gain;
                    }
                    (2, 1) => {
                        let sample = (clip.asset.samples()[source_index]
                            + clip.asset.samples()[source_index + 1]) * 0.5;
                        state.track_scratch[track_offset] += sample * gain;
                    }
                    (2, 2) => {
                        state.track_scratch[track_offset] +=
                            clip.asset.samples()[source_index] * gain * clip.left_pan_gain;
                        state.track_scratch[track_offset + 1] +=
                            clip.asset.samples()[source_index + 1] * gain * clip.right_pan_gain;
                    }
                    _ => {}
                }
            }

            let mut left = 0.0_f32;
            let mut right = 0.0_f32;
            for (track_index, track) in self.tracks.iter().enumerate() {
                let offset = track_index * 2;
                let mut track_left = state.track_scratch[offset];
                let mut track_right = state.track_scratch[offset + 1];

                if track.high_pass_alpha < 0.999_999 {
                    let filter_offset = track_index * 4;
                    let previous_input_left = state.filter_state[filter_offset];
                    let previous_output_left = state.filter_state[filter_offset + 1];
                    let previous_input_right = state.filter_state[filter_offset + 2];
                    let previous_output_right = state.filter_state[filter_offset + 3];
                    let filtered_left = track.high_pass_alpha
                        * (previous_output_left + track_left - previous_input_left);
                    let filtered_right = track.high_pass_alpha
                        * (previous_output_right + track_right - previous_input_right);
                    state.filter_state[filter_offset] = track_left;
                    state.filter_state[filter_offset + 1] = filtered_left;
                    state.filter_state[filter_offset + 2] = track_right;
                    state.filter_state[filter_offset + 3] = filtered_right;
                    track_left = filtered_left;
                    track_right = filtered_right;
                }

                let envelope = state.compressor_envelope[track_index];
                let peak = track_left.abs().max(track_right.abs());
                let coefficient = if peak > envelope {
                    attack_coefficient
                } else {
                    release_coefficient
                };
                let next_envelope = envelope + coefficient * (peak - envelope);
                state.compressor_envelope[track_index] = next_envelope;
                let compression_gain = if track.compressor_ratio > 1.0
                    && next_envelope > track.compressor_threshold
                {
                    let compressed = track.compressor_threshold
                        + (next_envelope - track.compressor_threshold)
                            / track.compressor_ratio;
                    compressed / next_envelope.max(0.000_001)
                } else {
                    1.0
                };

                left += track_left * track.gain * compression_gain;
                right += track_right * track.gain * compression_gain;
            }
            left *= self.master_gain;
            right *= self.master_gain;
            let output_index = output_frame * channels;
            if channels == 1 {
                output[output_index] = left;
            } else {
                output[output_index] = left;
                output[output_index + 1] = right;
            }
        }

        for sample in output.iter_mut().skip(frames * channels) {
            *sample = 0.0;
        }
        state.next_frame = Some(start_frame.saturating_add(frames));
    }
}

/// Builds the realtime graph before opening the device stream. Each distinct
/// source WAV is held by one shared immutable AudioBuffer; clips referencing
/// the same WAV reuse that allocation. The owned FFI path moves PCM buffers
/// into Arc without copying their sample payloads.
pub(crate) fn build_realtime_mixer(
    session: &MixSession,
    assets: &HashMap<String, AudioBuffer>,
) -> Result<Arc<RealtimeMixer>, AudioError> {
    // This borrowed form is useful for deterministic unit tests. The FFI
    // playback path uses the owned form below to avoid duplicating PCM data.
    let shared = assets
        .iter()
        .map(|(id, asset)| (id.clone(), Arc::new(asset.clone())))
        .collect::<HashMap<_, _>>();
    build_realtime_mixer_shared(session, &shared)
}

/// Moves decoded WAV buffers into shared immutable allocations. The engine
/// builder handle relinquishes its asset map as soon as playback is created,
/// so source PCM is not copied a second time for a realtime session.
pub(crate) fn build_realtime_mixer_owned(
    session: &MixSession,
    assets: HashMap<String, AudioBuffer>,
) -> Result<Arc<RealtimeMixer>, AudioError> {
    let shared = assets
        .into_iter()
        .map(|(id, asset)| (id, Arc::new(asset)))
        .collect::<HashMap<_, _>>();
    build_realtime_mixer_shared(session, &shared)
}


fn validate_track_dsp(
    sample_rate: u32,
    high_pass_hz: f32,
    compressor_threshold: f32,
    compressor_ratio: f32,
) -> Result<f32, AudioError> {
    let nyquist = sample_rate as f32 * 0.5;
    if !high_pass_hz.is_finite()
        || high_pass_hz < 0.0
        || high_pass_hz >= nyquist
        || !compressor_threshold.is_finite()
        || !(0.001..=1.0).contains(&compressor_threshold)
        || !compressor_ratio.is_finite()
        || !(1.0..=20.0).contains(&compressor_ratio)
    {
        return Err(AudioError::InvalidArgument(
            "track DSP expects high-pass below Nyquist, threshold 0.001..1.0 and compressor ratio 1..20".into(),
        ));
    }
    if high_pass_hz == 0.0 {
        Ok(1.0)
    } else {
        Ok((-2.0 * std::f32::consts::PI * high_pass_hz / sample_rate as f32).exp())
    }
}

fn build_realtime_mixer_shared(
    session: &MixSession,
    assets: &HashMap<String, Arc<AudioBuffer>>,
) -> Result<Arc<RealtimeMixer>, AudioError> {
    validate_audio_format(session.sample_rate, session.channels)?;
    if !session.master_gain.is_finite() || session.master_gain < 0.0 {
        return Err(AudioError::InvalidArgument(
            "master gain must be finite and non-negative".into(),
        ));
    }
    if session.tracks.len() > MAX_REALTIME_TRACKS {
        return Err(AudioError::InvalidArgument(format!(
            "realtime sessions support at most {MAX_REALTIME_TRACKS} tracks"
        )));
    }

    let has_solo = session.tracks.iter().any(|track| track.solo && !track.muted);
    let mut realtime_tracks = Vec::with_capacity(session.tracks.len());
    let mut realtime_clips = Vec::new();
    let mut events = Vec::new();
    let mut output_frames = 0_usize;

    for track in &session.tracks {
        let high_pass_alpha = validate_track_dsp(
            session.sample_rate,
            track.high_pass_hz,
            track.compressor_threshold,
            track.compressor_ratio,
        )?;
        if track.id.trim().is_empty()
            || !track.gain.is_finite()
            || track.gain < 0.0
            || !track.pan.is_finite()
            || !(-1.0..=1.0).contains(&track.pan)
        {
            return Err(AudioError::InvalidArgument(format!(
                "track {} has an invalid id, gain or pan",
                track.id
            )));
        }

        let audible = !track.muted && (!has_solo || track.solo);
        if !audible {
            continue;
        }
        if realtime_tracks.len() == MAX_REALTIME_TRACKS {
            return Err(AudioError::InvalidArgument(format!(
                "realtime sessions support at most {MAX_REALTIME_TRACKS} audible tracks"
            )));
        }
        let track_index = realtime_tracks.len();
        realtime_tracks.push(RealtimeTrack {
            gain: track.gain,
            high_pass_alpha,
            compressor_threshold: track.compressor_threshold,
            compressor_ratio: track.compressor_ratio,
        });

        for clip in &track.clips {
            if clip.id.trim().is_empty()
                || clip.media_id.trim().is_empty()
                || clip.duration_frames == 0
                || !clip.gain.is_finite()
                || clip.gain < 0.0
                || !clip.pan.is_finite()
                || !(-1.0..=1.0).contains(&clip.pan)
                || clip.fade_in_frames > clip.duration_frames
                || clip.fade_out_frames > clip.duration_frames
            {
                return Err(AudioError::InvalidArgument(format!(
                    "track {} contains an invalid clip",
                    track.id
                )));
            }
            if clip.muted {
                continue;
            }

            let asset = assets
                .get(&clip.media_id)
                .ok_or_else(|| AudioError::AssetNotFound(clip.media_id.clone()))?;
            if asset.sample_rate() != session.sample_rate {
                return Err(AudioError::SampleRateMismatch {
                    asset_rate: asset.sample_rate(),
                    session_rate: session.sample_rate,
                });
            }
            let source_end = clip
                .source_start_frame
                .checked_add(clip.duration_frames)
                .ok_or(AudioError::SizeOverflow)?;
            if source_end > asset.frame_count() {
                return Err(AudioError::InvalidArgument(format!(
                    "clip {} reads beyond the end of asset {}",
                    clip.id, clip.media_id
                )));
            }
            if realtime_clips.len() >= MAX_REALTIME_CLIPS {
                return Err(AudioError::InvalidArgument(format!(
                    "realtime sessions support at most {MAX_REALTIME_CLIPS} audible clips"
                )));
            }

            let timeline_end = clip
                .start_frame
                .checked_add(clip.duration_frames)
                .ok_or(AudioError::SizeOverflow)?;
            let timeline_end =
                usize::try_from(timeline_end).map_err(|_| AudioError::SizeOverflow)?;
            let start_frame =
                usize::try_from(clip.start_frame).map_err(|_| AudioError::SizeOverflow)?;
            let source_start_frame =
                usize::try_from(clip.source_start_frame).map_err(|_| AudioError::SizeOverflow)?;
            let duration_frames =
                usize::try_from(clip.duration_frames).map_err(|_| AudioError::SizeOverflow)?;
            let source_channels = usize::from(asset.channels());

            let combined_pan = (track.pan + clip.pan).clamp(-1.0, 1.0);
            let (left_pan_gain, right_pan_gain) =
                match (asset.channels(), session.channels) {
                    (1, 2) => {
                        let angle = (f64::from(combined_pan) + 1.0)
                            * std::f64::consts::FRAC_PI_4;
                        (angle.cos() as f32, angle.sin() as f32)
                    }
                    (2, 2) => (
                        if combined_pan > 0.0 {
                            (f64::from(combined_pan)
                                * std::f64::consts::FRAC_PI_2).cos() as f32
                        } else {
                            1.0
                        },
                        if combined_pan < 0.0 {
                            (f64::from(-combined_pan)
                                * std::f64::consts::FRAC_PI_2).cos() as f32
                        } else {
                            1.0
                        },
                    ),
                    _ => (1.0, 1.0),
                };

            let clip_index = realtime_clips.len();
            realtime_clips.push(RealtimeClip {
                track_index,
                start_frame,
                source_start_frame,
                duration_frames,
                source_channels,
                asset: Arc::clone(asset),
                gain: clip.gain,
                left_pan_gain,
                right_pan_gain,
                fade_in_frames: usize::try_from(clip.fade_in_frames)
                    .map_err(|_| AudioError::SizeOverflow)?,
                fade_out_frames: usize::try_from(clip.fade_out_frames)
                    .map_err(|_| AudioError::SizeOverflow)?,
            });
            events.push(ClipEvent {
                frame: start_frame,
                clip_index,
                is_start: true,
            });
            events.push(ClipEvent {
                frame: timeline_end,
                clip_index,
                is_start: false,
            });
            output_frames = output_frames.max(timeline_end);
        }
    }

    // End events sort before start events at the same frame so adjacent clips
    // do not overlap by an unintended extra sample.
    events.sort_unstable_by(|left, right| {
        left.frame
            .cmp(&right.frame)
            .then_with(|| left.is_start.cmp(&right.is_start))
    });

    Ok(Arc::new(RealtimeMixer {
        sample_rate: session.sample_rate,
        channels: session.channels,
        total_frames: u64::try_from(output_frames).map_err(|_| AudioError::SizeOverflow)?,
        tracks: realtime_tracks,
        clips: realtime_clips,
        events,
        master_gain: session.master_gain,
    }))
}

// ---------------- C ABI for Flutter FFI ----------------

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::os::raw::c_char;
use std::ptr;
use std::slice;

thread_local! {
    static FFI_LAST_ERROR: RefCell<CString> =
        RefCell::new(CString::new("").expect("empty CString is valid"));
}

/// Opaque engine session allocated by aura_engine_create.
pub struct AuraEngineHandle {
    session: MixSession,
    assets: HashMap<String, AudioBuffer>,
}

pub(crate) fn set_ffi_error(message: &str) {
    let sanitized = message.replace('\0', " ");
    let value = CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("native audio engine error").expect("static string"));
    FFI_LAST_ERROR.with(|last| *last.borrow_mut() = value);
}

fn ffi_status<F>(operation: F) -> i32
where
    F: FnOnce() -> Result<(), AudioError>,
{
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => {
            set_ffi_error("");
            0
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            -1
        }
        Err(_) => {
            set_ffi_error("native audio engine panicked while processing the request");
            -2
        }
    }
}

unsafe fn read_ffi_string(value: *const c_char, field: &str) -> Result<String, AudioError> {
    if value.is_null() {
        return Err(AudioError::InvalidArgument(format!("{field} pointer is null")));
    }
    // SAFETY: The public C ABI contract requires a valid NUL-terminated UTF-8 string.
    let value = unsafe { CStr::from_ptr(value) };
    value.to_str()
        .map(str::to_owned)
        .map_err(|_| AudioError::InvalidArgument(format!("{field} must be valid UTF-8")))
}

unsafe fn checked_handle<'a>(
    handle: *mut AuraEngineHandle,
) -> Result<&'a mut AuraEngineHandle, AudioError> {
    if handle.is_null() {
        return Err(AudioError::InvalidArgument("engine handle is null".into()));
    }
    // SAFETY: The C ABI caller must pass a live handle returned by aura_engine_create
    // and must not use that handle concurrently or after aura_engine_destroy.
    Ok(unsafe { &mut *handle })
}

/// Returns the current C ABI version. Increment on incompatible ABI changes.
#[no_mangle]
pub extern "C" fn aura_engine_abi_version() -> u32 {
    4
}

/// Returns a static NUL-terminated engine version string.
#[no_mangle]
pub extern "C" fn aura_engine_version() -> *const c_char {
    b"0.1.0\0".as_ptr().cast()
}

/// Creates an isolated offline-render session.
///
/// # Safety
/// The returned handle must be destroyed exactly once with aura_engine_destroy.
#[no_mangle]
pub extern "C" fn aura_engine_create(
    sample_rate: u32,
    channels: u16,
) -> *mut AuraEngineHandle {
    match catch_unwind(AssertUnwindSafe(|| {
        validate_audio_format(sample_rate, channels)?;
        Ok::<_, AudioError>(Box::into_raw(Box::new(AuraEngineHandle {
            session: MixSession::new(sample_rate, channels),
            assets: HashMap::new(),
        })))
    })) {
        Ok(Ok(handle)) => {
            set_ffi_error("");
            handle
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("native audio engine failed to create a session");
            ptr::null_mut()
        }
    }
}

/// Destroys a handle returned by aura_engine_create.
///
/// # Safety
/// handle must be null or a live handle returned by aura_engine_create, not
/// previously destroyed and not in use by another call.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_destroy(handle: *mut AuraEngineHandle) {
    if !handle.is_null() {
        // SAFETY: Ownership is transferred back exactly once by this function's contract.
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(handle));
        }));
    }
}

/// Decodes and registers a PCM/IEEE-float WAV asset.
///
/// # Safety
/// handle must be live. asset_id must point to a valid NUL-terminated UTF-8
/// string. wav_data must reference wav_len readable bytes.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_add_wav_asset(
    handle: *mut AuraEngineHandle,
    asset_id: *const c_char,
    wav_data: *const u8,
    wav_len: usize,
) -> i32 {
    ffi_status(|| {
        if wav_data.is_null() || wav_len < 12 || wav_len > 1_073_741_824 {
            return Err(AudioError::InvalidArgument(
                "WAV buffer must be non-null and between 12 bytes and 1 GiB".into(),
            ));
        }
        // SAFETY: The pointer and length are validated and caller guarantees readable memory.
        let bytes = unsafe { slice::from_raw_parts(wav_data, wav_len) };
        let id = unsafe { read_ffi_string(asset_id, "asset_id")? };
        let buffer = AudioBuffer::from_wav(bytes)?;
        let engine = unsafe { checked_handle(handle)? };
        engine.assets.insert(id, buffer);
        Ok(())
    })
}

/// Adds a mix track.
///
/// # Safety
/// handle must be live. track_id must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_add_track(
    handle: *mut AuraEngineHandle,
    track_id: *const c_char,
    gain: f32,
    pan: f32,
    muted: u8,
    solo: u8,
) -> i32 {
    ffi_status(|| {
        let id = unsafe { read_ffi_string(track_id, "track_id")? };
        if id.trim().is_empty() || !gain.is_finite() || gain < 0.0
            || !pan.is_finite() || !(-1.0..=1.0).contains(&pan) {
            return Err(AudioError::InvalidArgument("track id, gain or pan is invalid".into()));
        }
        let engine = unsafe { checked_handle(handle)? };
        if engine.session.tracks.iter().any(|track| track.id == id) {
            return Err(AudioError::InvalidArgument(format!("duplicate track id: {id}")));
        }
        let mut track = Track::new(id);
        track.gain = gain;
        track.pan = pan;
        track.muted = muted != 0;
        track.solo = solo != 0;
        engine.session.tracks.push(track);
        Ok(())
    })
}

/// Adds a clip referencing a previously registered WAV asset.
///
/// # Safety
/// handle must be live; track_id, clip_id and asset_id must each be valid
/// NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_add_clip(
    handle: *mut AuraEngineHandle,
    track_id: *const c_char,
    clip_id: *const c_char,
    asset_id: *const c_char,
    start_frame: u64,
    source_start_frame: u64,
    duration_frames: u64,
    gain: f32,
    pan: f32,
    muted: u8,
    fade_in_frames: u64,
    fade_out_frames: u64,
) -> i32 {
    ffi_status(|| {
        let track_name = unsafe { read_ffi_string(track_id, "track_id")? };
        let clip_name = unsafe { read_ffi_string(clip_id, "clip_id")? };
        let asset_name = unsafe { read_ffi_string(asset_id, "asset_id")? };
        if clip_name.trim().is_empty() || asset_name.trim().is_empty()
            || duration_frames == 0 || !gain.is_finite() || gain < 0.0
            || !pan.is_finite() || !(-1.0..=1.0).contains(&pan) {
            return Err(AudioError::InvalidArgument("clip id, duration, gain or pan is invalid".into()));
        }
        let engine = unsafe { checked_handle(handle)? };
        let track = engine.session.tracks.iter_mut()
            .find(|track| track.id == track_name)
            .ok_or_else(|| AudioError::InvalidArgument(format!("track not found: {track_name}")))?;
        if track.clips.iter().any(|clip| clip.id == clip_name) {
            return Err(AudioError::InvalidArgument(format!("duplicate clip id: {clip_name}")));
        }
        let mut clip = Clip::new(
            clip_name, asset_name, start_frame, source_start_frame, duration_frames,
        );
        clip.gain = gain;
        clip.pan = pan;
        clip.muted = muted != 0;
        clip.fade_in_frames = fade_in_frames;
        clip.fade_out_frames = fade_out_frames;
        track.clips.push(clip);
        Ok(())
    })
}

/// Renders the session and returns a newly allocated PCM WAV buffer.
///
/// # Safety
/// handle must be live. All output pointers must point to writable storage.
/// On success, free *out_data with aura_engine_free_buffer exactly once.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_render_wav(
    handle: *mut AuraEngineHandle,
    bit_depth: u16,
    out_data: *mut *mut u8,
    out_len: *mut usize,
    out_sample_peak: *mut f32,
    out_clipped_samples: *mut usize,
) -> i32 {
    ffi_status(|| {
        if out_data.is_null() || out_len.is_null()
            || out_sample_peak.is_null() || out_clipped_samples.is_null() {
            return Err(AudioError::InvalidArgument("render output pointers must not be null".into()));
        }
        // SAFETY: Output pointers are checked and writable per the public API contract.
        unsafe {
            *out_data = ptr::null_mut();
            *out_len = 0;
            *out_sample_peak = 0.0;
            *out_clipped_samples = 0;
        }

        let engine = unsafe { checked_handle(handle)? };
        let report = render_mix(&engine.session, &engine.assets)?;
        let wav = report.to_wav_pcm(bit_depth)?;
        let mut boxed = wav.into_boxed_slice();
        let length = boxed.len();
        let data = boxed.as_mut_ptr();
        let _ = Box::into_raw(boxed);

        // SAFETY: The output slots are valid and ownership of the boxed slice is transferred.
        unsafe {
            *out_data = data;
            *out_len = length;
            *out_sample_peak = report.sample_peak;
            *out_clipped_samples = report.clipped_samples;
        }
        Ok(())
    })
}



/// Starts direct callback-driven multitrack playback for the prepared session.
///
/// The engine handle may be destroyed after this function returns: the output
/// stream owns an immutable snapshot of the decoded source buffers and clip
/// graph. The callback performs sample mixing directly and does not render a
/// complete WAV beforehand.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_realtime_playback_start(
    handle: *mut AuraEngineHandle,
    out_total_frames: *mut u64,
) -> *mut device_io::AuraAudioPlaybackHandle {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() || out_total_frames.is_null() {
            return Err(AudioError::InvalidArgument(
                "realtime playback handle and output pointer must not be null".into(),
            ));
        }
        // SAFETY: Caller supplies a live engine handle and writable output slot.
        let engine = unsafe { &mut *handle };
        let assets = std::mem::take(&mut engine.assets);
        let mixer = build_realtime_mixer_owned(&engine.session, assets)?;
        let total_frames = mixer.total_frames;
        let playback = device_io::start_realtime_playback(mixer)?;
        // SAFETY: The pointer was checked above and is writable by the ABI contract.
        unsafe { *out_total_frames = total_frames; }
        Ok::<_, AudioError>(playback)
    }));

    match result {
        Ok(Ok(playback)) => {
            set_ffi_error("");
            playback
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("realtime multitrack playback failed unexpectedly");
            ptr::null_mut()
        }
    }
}

/// Atomically publishes a newly prepared session graph to a running
/// multitrack playback stream. Source WAV decoding and graph validation happen
/// before publication; the output callback switches at the next block boundary.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_replace_session(
    playback: *mut device_io::AuraAudioPlaybackHandle,
    session_handle: *mut AuraEngineHandle,
    out_total_frames: *mut u64,
) -> i32 {
    ffi_status(|| {
        if playback.is_null() || session_handle.is_null() || out_total_frames.is_null() {
            return Err(AudioError::InvalidArgument(
                "playback, session and output pointers must not be null".into(),
            ));
        }
        // SAFETY: Caller supplies live playback/session handles and a writable output slot.
        let engine = unsafe { &mut *session_handle };
        let assets = std::mem::take(&mut engine.assets);
        let mixer = build_realtime_mixer_owned(&engine.session, assets)?;
        let total_frames = unsafe {
            device_io::replace_realtime_session(playback, mixer)?
        };
        // SAFETY: Output pointer was validated and is writable by the C ABI contract.
        unsafe { *out_total_frames = total_frames; }
        Ok(())
    })
}

/// Frees a buffer allocated by aura_engine_render_wav.
///
/// # Safety
/// data and len must be the exact pointer and length returned by a successful
/// aura_engine_render_wav call, and must not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn aura_engine_free_buffer(data: *mut u8, len: usize) {
    if !data.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let slice = ptr::slice_from_raw_parts_mut(data, len);
            // SAFETY: Caller transfers the original boxed-slice allocation exactly once.
            unsafe { drop(Box::from_raw(slice)); }
        }));
    }
}

/// Returns the last error message for the calling thread.
///
/// # Safety
/// The returned pointer remains valid until the next Aura engine call on this thread.
#[no_mangle]
pub extern "C" fn aura_engine_last_error() -> *const c_char {
    FFI_LAST_ERROR.with(|last| last.borrow().as_ptr())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(id: &str, channels: u16, samples: &[f32]) -> HashMap<String, AudioBuffer> {
        let mut result = HashMap::new();
        result.insert(id.to_string(), AudioBuffer::new(48_000, channels, samples.to_vec()).unwrap());
        result
    }

    #[test]
    fn places_clips_at_exact_sample_frames_and_exports_a_valid_wav() {
        let assets = asset("voice", 1, &[0.25, 0.5, -0.25]);
        let mut session = MixSession::new(48_000, 1);
        let mut track = Track::new("lead");
        track.clips.push(Clip::new("take", "voice", 2, 0, 3));
        session.tracks.push(track);

        let report = render_mix(&session, &assets).unwrap();
        assert_eq!(report.audio.frame_count(), 5);
        assert_eq!(&report.audio.samples()[..2], &[0.0, 0.0]);
        assert_eq!(&report.audio.samples()[2..], &[0.25, 0.5, -0.25]);

        let wav = report.to_wav_pcm(16).unwrap();
        let decoded = AudioBuffer::from_wav(&wav).unwrap();
        assert_eq!(decoded.sample_rate(), 48_000);
        assert_eq!(decoded.channels(), 1);
        assert_eq!(decoded.frame_count(), 5);
        assert!((decoded.samples()[3] - 0.5).abs() < 0.0001);
    }

    #[test]
    fn applies_track_and_clip_gain() {
        let assets = asset("voice", 1, &[0.5, -0.5]);
        let mut session = MixSession::new(48_000, 1);
        let mut track = Track::new("lead");
        track.gain = 0.5;
        let mut clip = Clip::new("take", "voice", 0, 0, 2);
        clip.gain = 0.5;
        track.clips.push(clip);
        session.tracks.push(track);

        let report = render_mix(&session, &assets).unwrap();
        assert!((report.audio.samples()[0] - 0.125).abs() < 0.000001);
        assert!((report.audio.samples()[1] + 0.125).abs() < 0.000001);
    }

    #[test]
    fn pans_mono_audio_to_the_requested_stereo_side() {
        let assets = asset("voice", 1, &[1.0]);
        let mut session = MixSession::new(48_000, 2);
        let mut track = Track::new("lead");
        let mut clip = Clip::new("take", "voice", 0, 0, 1);
        clip.pan = -1.0;
        track.clips.push(clip);
        session.tracks.push(track);

        let report = render_mix(&session, &assets).unwrap();
        assert!((report.audio.samples()[0] - 1.0).abs() < 0.000001);
        assert!(report.audio.samples()[1].abs() < 0.000001);
    }

    #[test]
    fn mute_and_solo_are_respected() {
        let assets = asset("one", 1, &[0.2, 0.2]);
        let mut second = AudioBuffer::new(48_000, 1, vec![0.4, 0.4]).unwrap();
        let mut all = assets;
        all.insert("two".into(), second.clone());

        let mut first_track = Track::new("first");
        first_track.clips.push(Clip::new("a", "one", 0, 0, 2));
        let mut second_track = Track::new("second");
        second_track.solo = true;
        second_track.clips.push(Clip::new("b", "two", 0, 0, 2));

        let mut session = MixSession::new(48_000, 1);
        session.tracks = vec![first_track, second_track];
        let report = render_mix(&session, &all).unwrap();
        assert_eq!(report.audio.samples(), &[0.4, 0.4]);

        session.tracks[1].muted = true;
        let report = render_mix(&session, &all).unwrap();
        assert_eq!(report.audio.samples(), &[0.2, 0.2]);

        second = AudioBuffer::new(48_000, 1, vec![0.4, 0.4]).unwrap();
        assert_eq!(second.frame_count(), 2);
    }

    #[test]
    fn applies_linear_fades_and_reports_overload_before_export() {
        let assets = asset("voice", 1, &[1.0, 1.0, 1.0, 1.0]);
        let mut session = MixSession::new(48_000, 1);
        let mut track = Track::new("lead");
        let mut clip = Clip::new("take", "voice", 0, 0, 4);
        clip.fade_in_frames = 2;
        clip.fade_out_frames = 2;
        track.clips.push(clip);
        session.tracks.push(track);

        let report = render_mix(&session, &assets).unwrap();
        assert_eq!(report.audio.samples(), &[0.0, 0.5, 0.5, 0.0]);

        session.master_gain = 3.0;
        let overloaded = render_mix(&session, &assets).unwrap();
        assert!(overloaded.sample_peak > 1.0);
        assert_eq!(overloaded.clipped_samples, 2);
        let exported = AudioBuffer::from_wav(&overloaded.to_wav_pcm(24).unwrap()).unwrap();
        assert!(exported.samples().iter().all(|sample| *sample <= 1.0 && *sample >= -1.0));
    }

    #[test]
    fn rejects_mismatched_sample_rates_and_missing_assets() {
        let mut assets = HashMap::new();
        assets.insert("voice".into(), AudioBuffer::new(44_100, 1, vec![0.1]).unwrap());
        let mut session = MixSession::new(48_000, 1);
        let mut track = Track::new("lead");
        track.clips.push(Clip::new("take", "voice", 0, 0, 1));
        session.tracks.push(track);
        assert!(matches!(
            render_mix(&session, &assets),
            Err(AudioError::SampleRateMismatch { .. })
        ));

        session.tracks[0].clips[0].media_id = "missing".into();
        assert_eq!(render_mix(&session, &assets), Err(AudioError::AssetNotFound("missing".into())));
    }

    #[test]
    fn c_abi_reports_version_four_for_realtime_multitrack_playback() {
        assert_eq!(aura_engine_abi_version(), 4);
    }

    #[test]
    fn c_abi_can_create_mix_render_and_release_output() {
        use std::ffi::CString;

        let source = AudioBuffer::new(48_000, 1, vec![0.25, -0.5, 0.75])
            .unwrap()
            .to_wav_pcm(16)
            .unwrap();
        let asset_id = CString::new("voice").unwrap();
        let track_id = CString::new("lead").unwrap();
        let clip_id = CString::new("take-1").unwrap();

        let handle = aura_engine_create(48_000, 1);
        assert!(!handle.is_null());

        // SAFETY: All strings, buffers and output slots live for the duration
        // of the calls; the handle is created above and destroyed once below.
        unsafe {
            assert_eq!(
                aura_engine_add_wav_asset(
                    handle,
                    asset_id.as_ptr(),
                    source.as_ptr(),
                    source.len(),
                ),
                0
            );
            assert_eq!(
                aura_engine_add_track(handle, track_id.as_ptr(), 1.0, 0.0, 0, 0),
                0
            );
            assert_eq!(
                aura_engine_add_clip(
                    handle,
                    track_id.as_ptr(),
                    clip_id.as_ptr(),
                    asset_id.as_ptr(),
                    1,
                    0,
                    3,
                    0.5,
                    0.0,
                    0,
                    0,
                    0,
                ),
                0
            );

            let mut output = ptr::null_mut();
            let mut output_len = 0_usize;
            let mut peak = 0.0_f32;
            let mut clipped = 0_usize;
            assert_eq!(
                aura_engine_render_wav(
                    handle,
                    16,
                    &mut output,
                    &mut output_len,
                    &mut peak,
                    &mut clipped,
                ),
                0
            );
            assert!(!output.is_null());
            let rendered = slice::from_raw_parts(output, output_len);
            let decoded = AudioBuffer::from_wav(rendered).unwrap();
            assert_eq!(decoded.frame_count(), 4);
            assert!((decoded.samples()[1] - 0.125).abs() < 0.0001);
            assert!((decoded.samples()[2] + 0.25).abs() < 0.0001);
            assert!(peak <= 1.0);
            assert_eq!(clipped, 0);
            aura_engine_free_buffer(output, output_len);
            aura_engine_destroy(handle);
        }
    }



    #[test]
    fn block_mixer_matches_offline_mix_for_overlapping_tracks_and_fades() {
        let mut assets = HashMap::new();
        assets.insert(
            "voice".into(),
            AudioBuffer::new(48_000, 1, vec![0.25, 0.5, 0.75, 1.0]).unwrap(),
        );
        assets.insert(
            "room".into(),
            AudioBuffer::new(48_000, 2, vec![0.2, -0.2, 0.4, -0.4]).unwrap(),
        );
        let mut lead = Track::new("lead");
        let mut lead_clip = Clip::new("lead-clip", "voice", 0, 0, 4);
        lead_clip.fade_in_frames = 2;
        lead_clip.gain = 0.7;
        lead.clips.push(lead_clip);
        let mut room = Track::new("room");
        room.pan = 0.25;
        let mut room_clip = Clip::new("room-clip", "room", 1, 0, 2);
        room_clip.fade_out_frames = 1;
        room.clips.push(room_clip);
        let mut session = MixSession::new(48_000, 2);
        session.tracks = vec![lead, room];

        let offline = render_mix(&session, &assets).unwrap();
        let realtime = build_realtime_mixer(&session, &assets).unwrap();
        let mut state = RealtimeRenderState::new();
        let mut block = vec![0.0_f32; 4];
        let mut actual = Vec::new();
        for start in (0..realtime.total_frames as usize).step_by(2) {
            let count = (realtime.total_frames as usize - start).min(2);
            realtime.render_block(&mut state, start, &mut block[..count * 2]);
            actual.extend_from_slice(&block[..count * 2]);
        }
        assert_eq!(actual.len(), offline.audio.samples().len());
        for (actual, expected) in actual.iter().zip(offline.audio.samples()) {
            assert!((actual - expected).abs() < 0.000001);
        }
    }

    #[test]
    fn block_scheduler_handles_seek_and_adjacent_clip_boundaries() {
        let assets = asset("voice", 1, &[0.25, 0.5, 0.75, 1.0]);
        let mut track = Track::new("voice");
        track.clips.push(Clip::new("first", "voice", 0, 0, 2));
        track.clips.push(Clip::new("second", "voice", 2, 2, 2));
        let mut session = MixSession::new(48_000, 1);
        session.tracks.push(track);
        let mixer = build_realtime_mixer(&session, &assets).unwrap();
        let mut state = RealtimeRenderState::new();
        let mut output = [0.0_f32; 2];

        mixer.render_block(&mut state, 0, &mut output);
        assert_eq!(output, [0.25, 0.5]);
        mixer.render_block(&mut state, 2, &mut output);
        assert_eq!(output, [0.75, 1.0]);
        // A backwards seek rebuilds the active set from the sorted events.
        mixer.render_block(&mut state, 1, &mut output);
        assert_eq!(output, [0.5, 0.75]);
    }

    #[test]
    fn realtime_scheduler_reuses_one_asset_buffer_for_repeated_clips() {
        let assets = asset("voice", 1, &[0.25, 0.5]);
        let mut track = Track::new("voice");
        track.clips.push(Clip::new("one", "voice", 0, 0, 2));
        track.clips.push(Clip::new("two", "voice", 4, 0, 2));
        let mut session = MixSession::new(48_000, 1);
        session.tracks.push(track);
        let mixer = build_realtime_mixer(&session, &assets).unwrap();
        let first = &mixer.clips[0].asset;
        let second = &mixer.clips[1].asset;
        assert!(Arc::ptr_eq(first, second));
        let mut state = RealtimeRenderState::new(&mixer);
        let mut output = [0.0_f32; 2];
        mixer.render_block(&mut state, 4, &mut output);
        assert_eq!(output, [0.25, 0.5]);
    }

    #[test]
    fn realtime_scheduler_rejects_clip_source_ranges_outside_the_asset() {
        let assets = asset("voice", 1, &[0.25, 0.5]);
        let mut track = Track::new("lead");
        track.clips.push(Clip::new("out-of-range", "voice", 0, 1, 2));
        let mut session = MixSession::new(48_000, 1);
        session.tracks.push(track);
        assert!(matches!(
            build_realtime_mixer(&session, &assets),
            Err(AudioError::InvalidArgument(_))
        ));
    }

    #[test]
    fn reads_and_writes_pcm_24_bit_and_rejects_bad_headers() {
        let input = AudioBuffer::new(48_000, 2, vec![-1.0, 0.0, 0.25, 1.0]).unwrap();
        let encoded = input.to_wav_pcm(24).unwrap();
        let decoded = AudioBuffer::from_wav(&encoded).unwrap();
        assert_eq!(decoded.channels(), 2);
        assert!((decoded.samples()[0] + 1.0).abs() < 0.000001);
        assert!((decoded.samples()[2] - 0.25).abs() < 0.000001);
        assert!(AudioBuffer::from_wav(b"not a wav").is_err());
    }
}

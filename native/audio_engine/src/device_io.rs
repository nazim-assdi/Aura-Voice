//! Cross-platform live microphone capture using CPAL.
//!
//! The realtime callback only converts and copies samples into a preallocated
//! single-producer/single-consumer ring. It never allocates, locks, performs
//! file I/O, or calls into Flutter.

use std::cell::UnsafeCell;
use std::ffi::{CStr, CString};
use std::fmt::Write as _;
use std::os::raw::c_char;
use std::ptr;
use std::str::FromStr;
use std::time::Instant;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, AtomicU64, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{DeviceId, SampleFormat, Stream, SupportedStreamConfig};

use crate::{
    set_ffi_error, AudioError, RealtimeMixer, RealtimeRenderState,
    MAX_REALTIME_BLOCK_FRAMES, RealtimeGraph,
};

struct FloatRing {
    slots: Box<[UnsafeCell<f32>]>,
    mask: usize,
    channels: usize,
    read_index: AtomicUsize,
    write_index: AtomicUsize,
    dropped_frames: AtomicU64,
    callback_error: AtomicU32,
}

// SAFETY: The ring is strictly single-producer/single-consumer. The audio
// callback owns the write side and the FFI reader owns the read side. Atomic
// release/acquire publication prevents either side reading a slot while the
// other side is mutating it.
unsafe impl Send for FloatRing {}
unsafe impl Sync for FloatRing {}

impl FloatRing {
    fn new(requested_samples: usize, channels: usize) -> Result<Self, AudioError> {
        if !(1..=2).contains(&channels) {
            return Err(AudioError::InvalidArgument(
                "capture ring supports mono or stereo output".into(),
            ));
        }
        let capacity = requested_samples
            .max(1024)
            .checked_next_power_of_two()
            .ok_or(AudioError::SizeOverflow)?;
        let slots = (0..capacity)
            .map(|_| UnsafeCell::new(0.0_f32))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        Ok(Self {
            slots,
            mask: capacity - 1,
            channels,
            read_index: AtomicUsize::new(0),
            write_index: AtomicUsize::new(0),
            dropped_frames: AtomicU64::new(0),
            callback_error: AtomicU32::new(0),
        })
    }

    fn push_interleaved(&self, data: &[f32], input_channels: usize) {
        if input_channels == 0 || data.len() % input_channels != 0 {
            return;
        }
        let frames = data.len() / input_channels;
        for frame in 0..frames {
            let write = self.write_index.load(Ordering::Relaxed);
            let read = self.read_index.load(Ordering::Acquire);
            let occupied = write.wrapping_sub(read);
            if occupied > self.slots.len().saturating_sub(self.channels) {
                self.dropped_frames.fetch_add(
                    (frames - frame) as u64,
                    Ordering::Relaxed,
                );
                break;
            }

            let source = frame * input_channels;
            if self.channels == 1 {
                let mut mono = 0.0_f32;
                for channel in 0..input_channels {
                    mono += data[source + channel];
                }
                // SAFETY: The producer has reserved this unpublished slot.
                unsafe {
                    *self.slots[write & self.mask].get() =
                        (mono / input_channels as f32).clamp(-1.0, 1.0);
                }
            } else {
                for channel in 0..2 {
                    // SAFETY: The producer has reserved both unpublished slots.
                    unsafe {
                        *self.slots[write.wrapping_add(channel) & self.mask].get() =
                            data[source + channel].clamp(-1.0, 1.0);
                    }
                }
            }
            self.write_index
                .store(write.wrapping_add(self.channels), Ordering::Release);
        }
    }


    fn available_frames(&self) -> usize {
        let write = self.write_index.load(Ordering::Acquire);
        let read = self.read_index.load(Ordering::Acquire);
        write.wrapping_sub(read) / self.channels
    }

    fn capacity_frames(&self) -> usize {
        self.slots.len() / self.channels
    }

    /// Reads one interpolated source frame at the output clock rate. The SPSC
    /// consumer owns the read cursor; no locks or allocations occur here.
    fn read_resampled_frame(
        &self,
        phase: &mut f64,
        source_frames_per_output: f64,
    ) -> Option<(f32, f32)> {
        let read = self.read_index.load(Ordering::Relaxed);
        let write = self.write_index.load(Ordering::Acquire);
        let available_frames = write.wrapping_sub(read) / self.channels;
        let source_index = phase.floor() as usize;
        if available_frames <= source_index + 1 {
            return None;
        }

        let fraction = (*phase - source_index as f64) as f32;
        let sample_at = |frame: usize, channel: usize| -> f32 {
            let source_channel = if self.channels == 1 { 0 } else { channel.min(1) };
            let index = read
                .wrapping_add(frame * self.channels)
                .wrapping_add(source_channel);
            // SAFETY: Acquire observed these producer-published frames. The
            // SPSC read cursor is owned exclusively by this callback.
            unsafe { *self.slots[index & self.mask].get() }
        };
        let left_a = sample_at(source_index, 0);
        let left_b = sample_at(source_index + 1, 0);
        let right_a = if self.channels == 1 {
            left_a
        } else {
            sample_at(source_index, 1)
        };
        let right_b = if self.channels == 1 {
            left_b
        } else {
            sample_at(source_index + 1, 1)
        };
        let left = left_a + (left_b - left_a) * fraction;
        let right = right_a + (right_b - right_a) * fraction;

        *phase += source_frames_per_output;
        let requested_advance = phase.floor() as usize;
        if requested_advance > 0 {
            let advance = requested_advance.min(available_frames.saturating_sub(1));
            self.read_index.store(
                read.wrapping_add(advance * self.channels),
                Ordering::Release,
            );
            *phase -= advance as f64;
        }
        Some((left, right))
    }

    fn read_frames(&self, output: &mut [f32], max_frames: usize) -> usize {
        let requested_samples = max_frames.saturating_mul(self.channels);
        let writable_samples = requested_samples.min(output.len());
        let frame_limit = writable_samples / self.channels;
        let read = self.read_index.load(Ordering::Relaxed);
        let write = self.write_index.load(Ordering::Acquire);
        let available = write.wrapping_sub(read);
        let frames = (available / self.channels).min(frame_limit);
        let samples = frames * self.channels;

        for (offset, destination) in output.iter_mut().take(samples).enumerate() {
            // SAFETY: Acquire observed the producer's Release publication and
            // the consumer exclusively owns all slots before its read cursor.
            *destination = unsafe {
                *self.slots[read.wrapping_add(offset) & self.mask].get()
            };
        }
        self.read_index
            .store(read.wrapping_add(samples), Ordering::Release);
        frames
    }
}

/// Opaque live input stream. The caller must stop it exactly once.
pub struct AuraAudioCaptureHandle {
    _stream: Stream,
    ring: Arc<FloatRing>,
    channels: u16,
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 8);
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            value if value.is_control() => {
                let _ = write!(escaped, "\\u{:04x}", value as u32);
            }
            value => escaped.push(value),
        }
    }
    escaped
}

fn list_input_devices_json() -> Result<String, AudioError> {
    let host = cpal::default_host();
    let default_id = host
        .default_input_device()
        .and_then(|device| device.id().ok())
        .map(|id| id.to_string());

    let devices = host
        .input_devices()
        .map_err(|error| AudioError::InvalidArgument(format!("cannot enumerate input devices: {error}")))?;

    let mut json = String::from("[");
    let mut first = true;
    for device in devices {
        let id = device
            .id()
            .map_err(|error| AudioError::InvalidArgument(format!("cannot read device id: {error}")))?
            .to_string();
        let name = device.to_string();
        let config = device.default_input_config().ok();
        if !first {
            json.push(',');
        }
        first = false;
        let _ = write!(
            json,
            "{{\"id\":\"{}\",\"name\":\"{}\",\"isDefault\":{},\"channels\":{},\"sampleRate\":{}}}",
            json_escape(&id),
            json_escape(&name),
            default_id.as_deref() == Some(id.as_str()),
            config.as_ref().map(|value| value.channels()).unwrap_or(0),
            config.as_ref().map(|value| value.sample_rate()).unwrap_or(0),
        );
    }
    json.push(']');
    Ok(json)
}

/// Negotiated output device and stream format. It is selected before the
/// graph is converted, so the device callback always runs at this exact rate.
pub(crate) struct OutputTarget {
    device: cpal::Device,
    supported: SupportedStreamConfig,
}

impl OutputTarget {
    pub(crate) fn sample_rate(&self) -> u32 {
        self.supported.sample_rate()
    }
}

fn preferred_rate_in_range(minimum: u32, maximum: u32, preferred: u32) -> u32 {
    preferred.clamp(minimum, maximum)
}

pub(crate) fn select_output_target(
    requested_id: Option<&str>,
    preferred_sample_rate: u32,
    required_channels: u16,
) -> Result<OutputTarget, AudioError> {
    let host = cpal::default_host();
    let device = if let Some(value) = requested_id.filter(|value| !value.trim().is_empty()) {
        let id = DeviceId::from_str(value).map_err(|error| {
            AudioError::InvalidArgument(format!("invalid output device id: {error}"))
        })?;
        let device_host = cpal::host_from_id(id.host()).map_err(|error| {
            AudioError::InvalidArgument(format!("output audio host unavailable: {error}"))
        })?;
        device_host.device_by_id(&id).ok_or_else(|| {
            AudioError::InvalidArgument("selected output device is no longer available".into())
        })?
    } else {
        host.default_output_device().ok_or_else(|| {
            AudioError::InvalidArgument("no default audio output device is available".into())
        })?
    };

    let ranges = device.supported_output_configs().map_err(|error| {
        AudioError::InvalidArgument(format!("cannot query output configurations: {error}"))
    })?;
    let mut best: Option<(u32, SupportedStreamConfig)> = None;
    for range in ranges.filter(|range| range.channels() >= required_channels) {
        let rate = preferred_rate_in_range(
            range.min_sample_rate(),
            range.max_sample_rate(),
            preferred_sample_rate,
        );
        let candidate = range.with_sample_rate(rate);
        let distance = rate.abs_diff(preferred_sample_rate);
        if best.as_ref().map(|(best_distance, _)| distance < *best_distance).unwrap_or(true) {
            best = Some((distance, candidate));
        }
    }
    let (_, supported) = best.ok_or_else(|| {
        AudioError::InvalidArgument(format!(
            "output device does not support at least {required_channels} channel(s)"
        ))
    })?;
    Ok(OutputTarget { device, supported })
}

/// Returns JSON describing the available operating-system output devices.
/// Release the returned value with aura_audio_string_free.
fn list_output_devices_json() -> Result<String, AudioError> {
    let host = cpal::default_host();
    let default_id = host
        .default_output_device()
        .and_then(|device| device.id().ok())
        .map(|id| id.to_string());
    let devices = host.output_devices().map_err(|error| {
        AudioError::InvalidArgument(format!("cannot enumerate output devices: {error}"))
    })?;

    let mut json = String::from("[");
    let mut first = true;
    for device in devices {
        let id = device.id().map_err(|error| {
            AudioError::InvalidArgument(format!("cannot read output device id: {error}"))
        })?.to_string();
        let name = device.to_string();
        let default = device.default_output_config().ok();
        let mut min_rate = u32::MAX;
        let mut max_rate = 0_u32;
        let mut max_channels = 0_u16;
        if let Ok(ranges) = device.supported_output_configs() {
            for range in ranges {
                min_rate = min_rate.min(range.min_sample_rate());
                max_rate = max_rate.max(range.max_sample_rate());
                max_channels = max_channels.max(range.channels());
            }
        }
        if !first {
            json.push(',');
        }
        first = false;
        let _ = write!(
            json,
            "{{\"id\":\"{}\",\"name\":\"{}\",\"isDefault\":{},\"channels\":{},\"sampleRate\":{},\"minSampleRate\":{},\"maxSampleRate\":{}}}",
            json_escape(&id),
            json_escape(&name),
            default_id.as_deref() == Some(id.as_str()),
            default.as_ref().map(|value| value.channels()).unwrap_or(max_channels),
            default.as_ref().map(|value| value.sample_rate()).unwrap_or(0),
            if min_rate == u32::MAX { 0 } else { min_rate },
            max_rate,
        );
    }
    json.push(']');
    Ok(json)
}

/// Lists system output devices. The JSON string must be released with
/// aura_audio_string_free.
#[no_mangle]
pub extern "C" fn aura_audio_output_devices_json() -> *mut c_char {
    match std::panic::catch_unwind(list_output_devices_json) {
        Ok(Ok(json)) => match CString::new(json) {
            Ok(value) => {
                set_ffi_error("");
                value.into_raw()
            }
            Err(_) => {
                set_ffi_error("output device list contained an invalid string");
                ptr::null_mut()
            }
        },
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("output device enumeration panicked");
            ptr::null_mut()
        }
    }
}

fn build_capture_stream(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    format: SampleFormat,
    ring: Arc<FloatRing>,
    input_channels: usize,
) -> Result<Stream, AudioError> {
    let error_ring = Arc::clone(&ring);
    let on_error = move |_error: cpal::Error| {
        error_ring.callback_error.store(1, Ordering::Release);
    };
    let timeout = None;

    macro_rules! build_stream {
        ($sample:ty, $convert:expr) => {{
            let callback_ring = Arc::clone(&ring);
            device
                .build_input_stream::<$sample, _, _>(
                    config.clone(),
                    move |data: &[$sample], _| {
                        // The conversion and copy path is bounded and allocation-free.
                        let mut frame = 0_usize;
                        let channels = input_channels;
                        while frame + channels <= data.len() {
                            let start = frame;
                            if callback_ring.channels == 1 {
                                let mut sum = 0.0_f32;
                                for channel in 0..channels {
                                    sum += ($convert)(data[start + channel]);
                                }
                                let mono = sum / channels as f32;
                                let temporary = [mono];
                                callback_ring.push_interleaved(&temporary, 1);
                            } else {
                                let temporary = [
                                    ($convert)(data[start]),
                                    ($convert)(data[start + 1]),
                                ];
                                callback_ring.push_interleaved(&temporary, 2);
                            }
                            frame += channels;
                        }
                    },
                    on_error,
                    timeout,
                )
                .map_err(|error| AudioError::InvalidArgument(format!("cannot open microphone stream: {error}")))?
        }};
    }

    let stream = match format {
        SampleFormat::F32 => build_stream!(f32, |sample: f32| sample),
        SampleFormat::F64 => build_stream!(f64, |sample: f64| sample as f32),
        SampleFormat::I16 => build_stream!(i16, |sample: i16| f32::from(sample) / 32768.0),
        SampleFormat::U16 => build_stream!(u16, |sample: u16| (f32::from(sample) - 32768.0) / 32768.0),
        SampleFormat::I32 => build_stream!(i32, |sample: i32| sample as f32 / 2_147_483_648.0),
        SampleFormat::U32 => build_stream!(u32, |sample: u32| (sample as f64 / 2_147_483_648.0 - 1.0) as f32),
        SampleFormat::I8 => build_stream!(i8, |sample: i8| f32::from(sample) / 128.0),
        SampleFormat::U8 => build_stream!(u8, |sample: u8| (f32::from(sample) - 128.0) / 128.0),
        unsupported => {
            return Err(AudioError::InvalidArgument(format!(
                "microphone sample format {unsupported} is not supported yet"
            )));
        }
    };
    Ok(stream)
}

/// Returns JSON describing available microphone inputs. Release with
/// aura_audio_string_free.
#[no_mangle]
pub extern "C" fn aura_audio_input_devices_json() -> *mut c_char {
    match std::panic::catch_unwind(list_input_devices_json) {
        Ok(Ok(json)) => match CString::new(json) {
            Ok(value) => {
                set_ffi_error("");
                value.into_raw()
            }
            Err(_) => {
                set_ffi_error("device list contained an invalid string");
                ptr::null_mut()
            }
        },
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("audio device enumeration panicked");
            ptr::null_mut()
        }
    }
}

/// Frees the JSON string returned by aura_audio_input_devices_json.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: Caller must provide the original pointer returned above once.
        let _ = std::panic::catch_unwind(|| unsafe { drop(CString::from_raw(value)); });
    }
}

/// Starts microphone capture for a stable CPAL device id. Pass null or an
/// empty id to use the system default input. The caller owns the returned
/// handle and must stop it exactly once.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_capture_start(
    device_id: *const c_char,
    buffer_milliseconds: u32,
    out_sample_rate: *mut u32,
    out_channels: *mut u16,
) -> *mut AuraAudioCaptureHandle {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if out_sample_rate.is_null() || out_channels.is_null() {
            return Err(AudioError::InvalidArgument("capture output pointers must not be null".into()));
        }
        let requested_id = if device_id.is_null() {
            None
        } else {
            // SAFETY: The public ABI requires a valid NUL-terminated UTF-8 string.
            let raw = unsafe { CStr::from_ptr(device_id) };
            let value = raw
                .to_str()
                .map_err(|_| AudioError::InvalidArgument("device id must be valid UTF-8".into()))?;
            if value.trim().is_empty() { None } else { Some(value.to_owned()) }
        };

        let device = if let Some(value) = requested_id {
            let id = DeviceId::from_str(&value)
                .map_err(|error| AudioError::InvalidArgument(format!("invalid audio device id: {error}")))?;
            let host = cpal::host_from_id(id.host())
                .map_err(|error| AudioError::InvalidArgument(format!("audio host unavailable: {error}")))?;
            host.device_by_id(&id)
                .ok_or_else(|| AudioError::InvalidArgument("selected microphone is no longer available".into()))?
        } else {
            cpal::default_host()
                .default_input_device()
                .ok_or_else(|| AudioError::InvalidArgument("no default microphone is available".into()))?
        };

        let supported = device
            .default_input_config()
            .map_err(|error| AudioError::InvalidArgument(format!("cannot read microphone format: {error}")))?;
        let input_channels = usize::from(supported.channels());
        if input_channels == 0 {
            return Err(AudioError::InvalidArgument("microphone reports zero input channels".into()));
        }
        let channels = input_channels.min(2);
        let sample_rate = supported.sample_rate();
        let buffer_ms = buffer_milliseconds.clamp(100, 5000) as usize;
        let requested_samples = (sample_rate as usize)
            .checked_mul(channels)
            .and_then(|value| value.checked_mul(buffer_ms))
            .map(|value| value / 1000)
            .ok_or(AudioError::SizeOverflow)?;
        let ring = Arc::new(FloatRing::new(requested_samples, channels)?);
        let config: cpal::StreamConfig = supported.clone().into();
        let stream = build_capture_stream(
            &device,
            &config,
            supported.sample_format(),
            Arc::clone(&ring),
            input_channels,
        )?;
        stream
            .play()
            .map_err(|error| AudioError::InvalidArgument(format!("cannot start microphone stream: {error}")))?;

        // SAFETY: Pointers were checked above and the caller supplies writable output slots.
        unsafe {
            *out_sample_rate = sample_rate;
            *out_channels = channels as u16;
        }
        Ok::<_, AudioError>(Box::into_raw(Box::new(AuraAudioCaptureHandle {
            _stream: stream,
            ring,
            channels: channels as u16,
        })))
    }));

    match result {
        Ok(Ok(handle)) => {
            set_ffi_error("");
            handle
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("microphone capture failed unexpectedly");
            ptr::null_mut()
        }
    }
}

/// Pauses the input stream while keeping buffered frames available to read.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_capture_pause(
    handle: *mut AuraAudioCaptureHandle,
) -> i32 {
    if handle.is_null() {
        set_ffi_error("capture handle is null");
        return -1;
    }
    // SAFETY: Caller guarantees a live handle and no concurrent stop operation.
    let capture = unsafe { &*handle };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| capture._stream.pause())) {
        Ok(Ok(())) => {
            set_ffi_error("");
            0
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            -1
        }
        Err(_) => {
            set_ffi_error("failed to pause microphone capture");
            -2
        }
    }
}

/// Reads up to max_frames from the capture ring. Returns actual frames read.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_capture_read(
    handle: *mut AuraAudioCaptureHandle,
    output: *mut f32,
    max_frames: u32,
) -> u32 {
    if handle.is_null() || output.is_null() || max_frames == 0 {
        set_ffi_error("capture handle, output buffer and frame count must be valid");
        return 0;
    }
    // SAFETY: Caller guarantees a live handle and output storage for
    // max_frames * channels samples, with no concurrent stop/read operations.
    let capture = unsafe { &*handle };
    let sample_count = (max_frames as usize).saturating_mul(usize::from(capture.channels));
    let buffer = unsafe { std::slice::from_raw_parts_mut(output, sample_count) };
    let frames = capture.ring.read_frames(buffer, max_frames as usize);
    set_ffi_error("");
    frames as u32
}

/// Returns the number of frames dropped because the consumer did not read fast
/// enough. A non-zero value is a recording-overrun warning.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_capture_dropped_frames(
    handle: *const AuraAudioCaptureHandle,
) -> u64 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: The pointer must remain a live handle for this read-only query.
    unsafe { &*handle }.ring.dropped_frames.load(Ordering::Relaxed)
}

/// Returns 0 while the device callback is healthy and 1 after a callback error.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_capture_status(
    handle: *const AuraAudioCaptureHandle,
) -> u32 {
    if handle.is_null() {
        return 1;
    }
    // SAFETY: The pointer must remain a live handle for this read-only query.
    unsafe { &*handle }.ring.callback_error.load(Ordering::Acquire)
}

/// Stops and releases a capture stream. The handle must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_capture_stop(handle: *mut AuraAudioCaptureHandle) {
    if !handle.is_null() {
        // SAFETY: Caller transfers the unique Box ownership exactly once.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(handle));
        }));
    }
}


/// Direct microphone-to-output monitor. Two independent device callbacks
/// communicate through a preallocated SPSC ring; the output side converts the
/// input clock to the negotiated output clock without blocking.
pub struct AuraAudioMonitorHandle {
    _input_stream: Stream,
    _output_stream: Stream,
    ring: Arc<FloatRing>,
    gain: Arc<AtomicU32>,
    underrun_frames: Arc<AtomicU64>,
    output_error: Arc<AtomicU32>,
    input_sample_rate: u32,
    output_sample_rate: u32,
}

fn monitor_clock_step(
    nominal_source_frames_per_output: f64,
    queued_input_frames: usize,
    target_queued_frames: usize,
) -> f64 {
    if target_queued_frames == 0 {
        return nominal_source_frames_per_output;
    }
    // A bounded 500 ppm occupancy servo compensates for independent hardware
    // oscillator drift without making audible pitch changes or blocking either
    // device callback. More queued input means the output side consumes faster.
    let error = (queued_input_frames as f64 - target_queued_frames as f64)
        / target_queued_frames as f64;
    let correction = (error * 0.0005).clamp(-0.0005, 0.0005);
    nominal_source_frames_per_output * (1.0 + correction)
}

fn build_monitor_output_stream(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    format: SampleFormat,
    ring: Arc<FloatRing>,
    input_sample_rate: u32,
    output_sample_rate: u32,
    output_channels: usize,
    gain: Arc<AtomicU32>,
    underrun_frames: Arc<AtomicU64>,
    output_error: Arc<AtomicU32>,
) -> Result<Stream, AudioError> {
    let error_state = Arc::clone(&output_error);
    let on_error = move |_error: cpal::Error| {
        error_state.store(1, Ordering::Release);
    };
    let source_frames_per_output =
        f64::from(input_sample_rate) / f64::from(output_sample_rate);

    macro_rules! build_output {
        ($sample:ty, $convert:expr) => {{
            let callback_ring = Arc::clone(&ring);
            let callback_gain = Arc::clone(&gain);
            let callback_underruns = Arc::clone(&underrun_frames);
            let callback_error = Arc::clone(&output_error);
            let mut phase = 0.0_f64;
            device
                .build_output_stream::<$sample, _, _>(
                    config,
                    move |data: &mut [$sample], _| {
                        if output_channels == 0 {
                            callback_error.store(1, Ordering::Release);
                            return;
                        }
                        let frames = data.len() / output_channels;
                        let monitor_gain =
                            f32::from_bits(callback_gain.load(Ordering::Acquire));
                        let target_queued_frames =
                            (callback_ring.capacity_frames() / 2).max(2);
                        let adjusted_source_step = monitor_clock_step(
                            source_frames_per_output,
                            callback_ring.available_frames(),
                            target_queued_frames,
                        );
                        let mut missed = 0_u64;
                        for frame in 0..frames {
                            let (left, right) = match callback_ring.read_resampled_frame(
                                &mut phase,
                                adjusted_source_step,
                            ) {
                                Some((left, right)) =>
                                    (left * monitor_gain, right * monitor_gain),
                                None => {
                                    missed += 1;
                                    (0.0, 0.0)
                                }
                            };
                            let offset = frame * output_channels;
                            data[offset] = ($convert)(left);
                            if output_channels > 1 {
                                data[offset + 1] = ($convert)(right);
                                for channel in 2..output_channels {
                                    data[offset + channel] = ($convert)(0.0);
                                }
                            }
                        }
                        for sample in data.iter_mut().skip(frames * output_channels) {
                            *sample = ($convert)(0.0);
                        }
                        if missed > 0 {
                            callback_underruns.fetch_add(missed, Ordering::Relaxed);
                        }
                    },
                    on_error,
                    None,
                )
                .map_err(|error| {
                    AudioError::InvalidArgument(format!(
                        "cannot open microphone monitor output: {error}"
                    ))
                })?
        }};
    }

    let stream = match format {
        SampleFormat::F32 => build_output!(f32, |sample: f32| sample),
        SampleFormat::F64 => build_output!(f64, |sample: f32| sample as f64),
        SampleFormat::I16 => build_output!(i16, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16
        }),
        SampleFormat::U16 => build_output!(u16, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 32767.5 + 32767.5).round() as u16
        }),
        SampleFormat::I32 => build_output!(i32, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 2_147_483_647.0).round() as i32
        }),
        SampleFormat::U32 => build_output!(u32, |sample: f32| {
            (sample.clamp(-1.0, 1.0) as f64 * 2_147_483_647.5 + 2_147_483_647.5)
                .round() as u32
        }),
        SampleFormat::I8 => build_output!(i8, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 127.0).round() as i8
        }),
        SampleFormat::U8 => build_output!(u8, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 127.5 + 127.5).round() as u8
        }),
        unsupported => {
            return Err(AudioError::InvalidArgument(format!(
                "monitor output sample format {unsupported} is not supported yet"
            )));
        }
    };
    Ok(stream)
}

/// Starts direct low-latency microphone monitoring. Null device ids select the
/// OS defaults. The ring target is 30 ms and is bounded between 20 and 250 ms.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_start(
    input_device_id: *const c_char,
    output_device_id: *const c_char,
    buffer_milliseconds: u32,
    initial_gain: f32,
) -> *mut AuraAudioMonitorHandle {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !initial_gain.is_finite() || !(0.0..=2.0).contains(&initial_gain) {
            return Err(AudioError::InvalidArgument(
                "monitor gain must be between 0.0 and 2.0".into(),
            ));
        }
        let requested_input = if input_device_id.is_null() {
            None
        } else {
            let raw = unsafe { CStr::from_ptr(input_device_id) };
            let value = raw.to_str().map_err(|_| {
                AudioError::InvalidArgument("input device id must be valid UTF-8".into())
            })?;
            if value.trim().is_empty() { None } else { Some(value.to_owned()) }
        };
        let requested_output = if output_device_id.is_null() {
            None
        } else {
            let raw = unsafe { CStr::from_ptr(output_device_id) };
            let value = raw.to_str().map_err(|_| {
                AudioError::InvalidArgument("output device id must be valid UTF-8".into())
            })?;
            if value.trim().is_empty() { None } else { Some(value.to_owned()) }
        };

        let input_device = if let Some(value) = requested_input {
            let id = DeviceId::from_str(&value).map_err(|error| {
                AudioError::InvalidArgument(format!("invalid input device id: {error}"))
            })?;
            let host = cpal::host_from_id(id.host()).map_err(|error| {
                AudioError::InvalidArgument(format!("input audio host unavailable: {error}"))
            })?;
            host.device_by_id(&id).ok_or_else(|| {
                AudioError::InvalidArgument("selected microphone is no longer available".into())
            })?
        } else {
            cpal::default_host().default_input_device().ok_or_else(|| {
                AudioError::InvalidArgument("no default microphone is available".into())
            })?
        };

        let input_config = input_device.default_input_config().map_err(|error| {
            AudioError::InvalidArgument(format!("cannot read microphone format: {error}"))
        })?;
        let input_channels = usize::from(input_config.channels());
        if input_channels == 0 {
            return Err(AudioError::InvalidArgument(
                "microphone reports zero channels".into(),
            ));
        }
        let ring_channels = input_channels.min(2);
        let input_sample_rate = input_config.sample_rate();
        let buffer_ms = buffer_milliseconds.clamp(20, 250) as usize;
        let requested_samples = (input_sample_rate as usize)
            .checked_mul(ring_channels)
            .and_then(|value| value.checked_mul(buffer_ms))
            .map(|value| value / 1000)
            .ok_or(AudioError::SizeOverflow)?;
        let ring = Arc::new(FloatRing::new(requested_samples, ring_channels)?);
        let capture_config: cpal::StreamConfig = input_config.clone().into();
        let input_stream = build_capture_stream(
            &input_device,
            &capture_config,
            input_config.sample_format(),
            Arc::clone(&ring),
            input_channels,
        )?;

        let target = select_output_target(
            requested_output.as_deref(),
            input_sample_rate,
            1,
        )?;
        let output_sample_rate = target.sample_rate();
        let output_channels = usize::from(target.supported.channels());
        let output_format = target.supported.sample_format();
        let output_config = target.supported.config();
        let gain = Arc::new(AtomicU32::new(initial_gain.to_bits()));
        let underrun_frames = Arc::new(AtomicU64::new(0));
        let output_error = Arc::new(AtomicU32::new(0));
        let output_stream = build_monitor_output_stream(
            &target.device,
            output_config,
            output_format,
            Arc::clone(&ring),
            input_sample_rate,
            output_sample_rate,
            output_channels,
            Arc::clone(&gain),
            Arc::clone(&underrun_frames),
            Arc::clone(&output_error),
        )?;

        input_stream.play().map_err(|error| {
            AudioError::InvalidArgument(format!(
                "cannot start microphone monitor input: {error}"
            ))
        })?;
        output_stream.play().map_err(|error| {
            AudioError::InvalidArgument(format!(
                "cannot start microphone monitor output: {error}"
            ))
        })?;

        Ok::<_, AudioError>(Box::into_raw(Box::new(AuraAudioMonitorHandle {
            _input_stream: input_stream,
            _output_stream: output_stream,
            ring,
            gain,
            underrun_frames,
            output_error,
            input_sample_rate,
            output_sample_rate,
        })))
    }));

    match result {
        Ok(Ok(handle)) => {
            set_ffi_error("");
            handle
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("microphone monitoring failed unexpectedly");
            ptr::null_mut()
        }
    }
}

/// Returns the number of output frames where no input interpolation pair was
/// available. This detects ring starvation but is not a hardware latency test.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_underrun_frames(
    handle: *const AuraAudioMonitorHandle,
) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.underrun_frames.load(Ordering::Relaxed)
}

/// Input frames dropped because the microphone producer found the SPSC
/// ring full. This is distinct from output-side ring starvation.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_input_dropped_frames(
    handle: *const AuraAudioMonitorHandle,
) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.ring.dropped_frames.load(Ordering::Relaxed)
}

/// Returns 0 while the input and output callbacks are healthy, 1 on error.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_status(
    handle: *const AuraAudioMonitorHandle,
) -> u32 {
    if handle.is_null() { return 1; }
    let monitor = unsafe { &*handle };
    if monitor.ring.callback_error.load(Ordering::Acquire) != 0
        || monitor.output_error.load(Ordering::Acquire) != 0
    {
        1
    } else {
        0
    }
}

/// Returns the active input rate in Hz.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_input_sample_rate(
    handle: *const AuraAudioMonitorHandle,
) -> u32 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.input_sample_rate
}

/// Returns the active output rate in Hz.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_output_sample_rate(
    handle: *const AuraAudioMonitorHandle,
) -> u32 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.output_sample_rate
}

/// Changes monitor gain atomically without restarting either device stream.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_set_gain(
    handle: *const AuraAudioMonitorHandle,
    gain: f32,
) -> i32 {
    if handle.is_null() || !gain.is_finite() || !(0.0..=2.0).contains(&gain) {
        set_ffi_error("monitor gain must be between 0.0 and 2.0");
        return -1;
    }
    unsafe { &*handle }.gain.store(gain.to_bits(), Ordering::Release);
    set_ffi_error("");
    0
}

/// Stops both CPAL streams and releases the monitor ring.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_monitor_stop(
    handle: *mut AuraAudioMonitorHandle,
) {
    if !handle.is_null() {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(handle));
        }));
    }
}

/// Lock-free callback counters used for local real-device performance reports.
#[derive(Clone)]
struct RealtimeCallbackMetrics {
    callbacks: Arc<AtomicU64>,
    processed_frames: Arc<AtomicU64>,
    total_callback_ns: Arc<AtomicU64>,
    max_callback_ns: Arc<AtomicU64>,
    deadline_misses: Arc<AtomicU64>,
}

impl RealtimeCallbackMetrics {
    fn new() -> Self {
        Self {
            callbacks: Arc::new(AtomicU64::new(0)),
            processed_frames: Arc::new(AtomicU64::new(0)),
            total_callback_ns: Arc::new(AtomicU64::new(0)),
            max_callback_ns: Arc::new(AtomicU64::new(0)),
            deadline_misses: Arc::new(AtomicU64::new(0)),
        }
    }

    fn record(&self, started: Instant, frames: usize, sample_rate: u32) {
        let elapsed = started.elapsed().as_nanos().min(u64::MAX as u128) as u64;
        let frame_count = frames as u64;
        let deadline_ns = (u128::from(frame_count) * 1_000_000_000_u128
            / u128::from(sample_rate.max(1))) as u64;
        self.callbacks.fetch_add(1, Ordering::Relaxed);
        self.processed_frames.fetch_add(frame_count, Ordering::Relaxed);
        self.total_callback_ns.fetch_add(elapsed, Ordering::Relaxed);
        self.max_callback_ns.fetch_max(elapsed, Ordering::Relaxed);
        if elapsed > deadline_ns {
            self.deadline_misses.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Opaque OS output stream for standalone WAV or realtime session playback.
pub struct AuraAudioPlaybackHandle {
    _stream: Stream,
    total_frames: AtomicUsize,
    drain_frames: usize,
    /// Clock rate used by the active output stream and graph.
    output_sample_rate: u32,
    realtime_graph: Option<Arc<RealtimeGraph>>,
    position_frames: Arc<AtomicUsize>,
    paused: Arc<AtomicBool>,
    loop_enabled: Arc<AtomicBool>,
    loop_start_frames: Arc<AtomicUsize>,
    loop_end_frames: Arc<AtomicUsize>,
    stream_error: Arc<AtomicU32>,
    callback_metrics: RealtimeCallbackMetrics,
}

/// Atomically claims the next source frame. The callback uses compare-exchange
/// so an interactive seek cannot be overwritten by a stale local cursor.
/// This is lock-free and performs no allocation or blocking operation.
fn claim_playback_frame(
    position: &AtomicUsize,
    paused: &AtomicBool,
    loop_enabled: &AtomicBool,
    loop_start: &AtomicUsize,
    loop_end: &AtomicUsize,
) -> Option<usize> {
    if paused.load(Ordering::Acquire) {
        return None;
    }

    loop {
        let current = position.load(Ordering::Acquire);
        if loop_enabled.load(Ordering::Acquire) {
            let end = loop_end.load(Ordering::Acquire);
            let start = loop_start.load(Ordering::Acquire);
            if start < end && current >= end {
                let _ = position.compare_exchange(
                    current,
                    start,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
                continue;
            }
        }
        let next = current.saturating_add(1);
        if position
            .compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            return Some(current);
        }
    }
}

fn build_playback_stream(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    format: SampleFormat,
    samples: Arc<Vec<f32>>,
    source_channels: usize,
    output_channels: usize,
    position_frames: Arc<AtomicUsize>,
    paused: Arc<AtomicBool>,
    loop_enabled: Arc<AtomicBool>,
    loop_start_frames: Arc<AtomicUsize>,
    loop_end_frames: Arc<AtomicUsize>,
    stream_error: Arc<AtomicU32>,
) -> Result<Stream, AudioError> {
    let total_frames = samples.len() / source_channels;
    let error_state = Arc::clone(&stream_error);
    let on_error = move |_error: cpal::Error| {
        error_state.store(1, Ordering::Release);
    };

    macro_rules! build_output {
        ($sample:ty, $convert:expr) => {{
            let callback_samples = Arc::clone(&samples);
            let callback_position = Arc::clone(&position_frames);
            let callback_paused = Arc::clone(&paused);
            let callback_loop_enabled = Arc::clone(&loop_enabled);
            let callback_loop_start = Arc::clone(&loop_start_frames);
            let callback_loop_end = Arc::clone(&loop_end_frames);
            let callback_error = Arc::clone(&stream_error);
            device
                .build_output_stream::<$sample, _, _>(
                    config,
                    move |data: &mut [$sample], _| {
                        let channels = output_channels;
                        if channels == 0 {
                            callback_error.store(1, Ordering::Release);
                            return;
                        }
                        let frames = data.len() / channels;
                        for frame in 0..frames {
                            let source_frame = claim_playback_frame(
                                &callback_position,
                                &callback_paused,
                                &callback_loop_enabled,
                                &callback_loop_start,
                                &callback_loop_end,
                            );
                            for channel in 0..channels {
                                let sample = match source_frame {
                                    Some(source_frame) if source_frame < total_frames => {
                                        let source_offset = source_frame * source_channels;
                                        if source_channels == 1 {
                                            callback_samples[source_offset]
                                        } else if channels == 1 {
                                            (callback_samples[source_offset]
                                                + callback_samples[source_offset + 1]) * 0.5
                                        } else {
                                            callback_samples[source_offset + channel.min(1)]
                                        }
                                    }
                                    _ => 0.0,
                                };
                                data[frame * channels + channel] = ($convert)(sample);
                            }
                        }
                        // Leave a malformed partial final frame silent.
                        for output in data.iter_mut().skip(frames * channels) {
                            *output = ($convert)(0.0);
                        }
                    },
                    on_error,
                    None,
                )
                .map_err(|error| {
                    AudioError::InvalidArgument(format!(
                        "cannot open audio output stream: {error}"
                    ))
                })?
        }};
    }

    let stream = match format {
        SampleFormat::F32 => build_output!(f32, |sample: f32| sample),
        SampleFormat::F64 => build_output!(f64, |sample: f32| sample as f64),
        SampleFormat::I16 => build_output!(i16, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16
        }),
        SampleFormat::U16 => build_output!(u16, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 32767.5 + 32767.5).round() as u16
        }),
        SampleFormat::I32 => build_output!(i32, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 2_147_483_647.0).round() as i32
        }),
        SampleFormat::U32 => build_output!(u32, |sample: f32| {
            (sample.clamp(-1.0, 1.0) as f64 * 2_147_483_647.5 + 2_147_483_647.5)
                .round() as u32
        }),
        SampleFormat::I8 => build_output!(i8, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 127.0).round() as i8
        }),
        SampleFormat::U8 => build_output!(u8, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 127.5 + 127.5).round() as u8
        }),
        unsupported => {
            return Err(AudioError::InvalidArgument(format!(
                "output device sample format {unsupported} is not supported yet"
            )));
        }
    };
    Ok(stream)
}



/// Builds an OS output stream whose callback mixes the session directly from
/// immutable, pre-decoded clip buffers. No full-session WAV is created.
/// Claims one contiguous output block with a single atomic cursor update.
/// The returned block never crosses the active loop end or the stream-drain end.
fn claim_playback_block(
    position: &AtomicUsize,
    paused: &AtomicBool,
    loop_enabled: &AtomicBool,
    loop_start: &AtomicUsize,
    loop_end: &AtomicUsize,
    total_frames: usize,
    drain_frames: usize,
    maximum_frames: usize,
) -> Option<(usize, usize)> {
    if paused.load(Ordering::Acquire) {
        return None;
    }

    loop {
        let current = position.load(Ordering::Acquire);
        let boundary = if loop_enabled.load(Ordering::Acquire) {
            let start = loop_start.load(Ordering::Acquire);
            let end = loop_end.load(Ordering::Acquire);
            if start < end {
                if current >= end {
                    let _ = position.compare_exchange(
                        current,
                        start,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    );
                    continue;
                }
                end
            } else {
                total_frames.saturating_add(drain_frames)
            }
        } else {
            total_frames.saturating_add(drain_frames)
        };

        if current >= boundary || maximum_frames == 0 {
            return None;
        }
        let available = boundary - current;
        let count = available.min(maximum_frames);
        let next = current.saturating_add(count);
        if position
            .compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            return Some((current, count));
        }
        if paused.load(Ordering::Acquire) {
            return None;
        }
    }
}

fn build_realtime_playback_stream(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    format: SampleFormat,
    graph: Arc<RealtimeGraph>,
    output_channels: usize,
    drain_frames: usize,
    position_frames: Arc<AtomicUsize>,
    paused: Arc<AtomicBool>,
    loop_enabled: Arc<AtomicBool>,
    loop_start_frames: Arc<AtomicUsize>,
    loop_end_frames: Arc<AtomicUsize>,
    stream_error: Arc<AtomicU32>,
    sample_rate: u32,
    callback_metrics: RealtimeCallbackMetrics,
) -> Result<Stream, AudioError> {
    let error_state = Arc::clone(&stream_error);
    let on_error = move |_error: cpal::Error| {
        error_state.store(1, Ordering::Release);
    };

    macro_rules! build_output {
        ($sample:ty, $convert:expr) => {{
            let callback_graph = Arc::clone(&graph);
            let callback_position = Arc::clone(&position_frames);
            let callback_paused = Arc::clone(&paused);
            let callback_loop_enabled = Arc::clone(&loop_enabled);
            let callback_loop_start = Arc::clone(&loop_start_frames);
            let callback_loop_end = Arc::clone(&loop_end_frames);
            let callback_error = Arc::clone(&stream_error);
            let callback_metrics = callback_metrics.clone();
            let mut render_state = RealtimeRenderState::new();
            let mut block_buffer = [0.0_f32; MAX_REALTIME_BLOCK_FRAMES * 2];

            device
                .build_output_stream::<$sample, _, _>(
                    config,
                    move |data: &mut [$sample], _| {
                        let callback_started = Instant::now();
                        let channels = output_channels;
                        if channels == 0 {
                            callback_error.store(1, Ordering::Release);
                            return;
                        }

                        let output_frames = data.len() / channels;
                        let mut output_offset = 0_usize;
                        while output_offset < output_frames {
                            let requested = (output_frames - output_offset)
                                .min(MAX_REALTIME_BLOCK_FRAMES);
                            // The guard pins one immutable graph snapshot for
                            // this block. Publishing a new graph never blocks
                            // this callback; it takes effect at the next block.
                            let graph_guard = callback_graph.load();
                            let mixer = graph_guard.mixer();
                            let total_frames = match usize::try_from(mixer.total_frames) {
                                Ok(value) => value,
                                Err(_) => {
                                    callback_error.store(1, Ordering::Release);
                                    break;
                                }
                            };
                            let claim = claim_playback_block(
                                &callback_position,
                                &callback_paused,
                                &callback_loop_enabled,
                                &callback_loop_start,
                                &callback_loop_end,
                                total_frames,
                                drain_frames,
                                requested,
                            );

                            let Some((start_frame, block_frames)) = claim else {
                                for sample in data
                                    .iter_mut()
                                    .skip(output_offset * channels)
                                    .take((output_frames - output_offset) * channels)
                                {
                                    *sample = ($convert)(0.0);
                                }
                                break;
                            };

                            let render_channels = usize::from(mixer.channels);
                            let sample_count = block_frames * render_channels;
                            let mixed = &mut block_buffer[..sample_count];
                            mixer.render_block(
                                &mut render_state,
                                start_frame,
                                mixed,
                            );

                            for frame in 0..block_frames {
                                let source_offset = frame * render_channels;
                                let left = mixed[source_offset];
                                let right = if render_channels > 1 {
                                    mixed[source_offset + 1]
                                } else {
                                    left
                                };
                                let destination_offset = (output_offset + frame) * channels;
                                if channels == 1 {
                                    let mono = if render_channels == 1 {
                                        left
                                    } else {
                                        (left + right) * 0.5
                                    };
                                    data[destination_offset] = ($convert)(mono);
                                } else {
                                    data[destination_offset] = ($convert)(left);
                                    data[destination_offset + 1] = ($convert)(right);
                                    for channel in 2..channels {
                                        data[destination_offset + channel] =
                                            ($convert)(0.0);
                                    }
                                }
                            }
                            output_offset += block_frames;
                        }

                        for sample in data.iter_mut().skip(output_frames * channels) {
                            *sample = ($convert)(0.0);
                        }
                        callback_metrics.record(callback_started, output_frames, sample_rate);
                    },
                    on_error,
                    None,
                )
                .map_err(|error| {
                    AudioError::InvalidArgument(format!(
                        "cannot open realtime multitrack output stream: {error}"
                    ))
                })?
        }};
    }

    let stream = match format {
        SampleFormat::F32 => build_output!(f32, |sample: f32| sample),
        SampleFormat::F64 => build_output!(f64, |sample: f32| sample as f64),
        SampleFormat::I16 => build_output!(i16, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16
        }),
        SampleFormat::U16 => build_output!(u16, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 32767.5 + 32767.5).round() as u16
        }),
        SampleFormat::I32 => build_output!(i32, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 2_147_483_647.0).round() as i32
        }),
        SampleFormat::U32 => build_output!(u32, |sample: f32| {
            (sample.clamp(-1.0, 1.0) as f64 * 2_147_483_647.5 + 2_147_483_647.5)
                .round() as u32
        }),
        SampleFormat::I8 => build_output!(i8, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 127.0).round() as i8
        }),
        SampleFormat::U8 => build_output!(u8, |sample: f32| {
            (sample.clamp(-1.0, 1.0) * 127.5 + 127.5).round() as u8
        }),
        unsupported => {
            return Err(AudioError::InvalidArgument(format!(
                "output device sample format {unsupported} is not supported yet"
            )));
        }
    };
    Ok(stream)
}

/// Starts the immutable session snapshot through the default OS output device.
/// The returned handle uses the same transport controls as WAV playback.
pub(crate) fn start_realtime_playback(
    mixer: Arc<RealtimeMixer>,
    target: OutputTarget,
) -> Result<*mut AuraAudioPlaybackHandle, AudioError> {
    if mixer.total_frames == 0 {
        return Err(AudioError::InvalidArgument(
            "realtime playback requires at least one audible clip frame".into(),
        ));
    }

    let graph = RealtimeGraph::new(mixer);
    let initial = graph.load();
    let sample_rate = initial.mixer().sample_rate;
    let channels = initial.mixer().channels;
    let total_frames = usize::try_from(initial.mixer().total_frames)
        .map_err(|_| AudioError::SizeOverflow)?;
    drop(initial);

    let output_sample_rate = target.supported.sample_rate();
    if output_sample_rate != sample_rate {
        return Err(AudioError::InvalidArgument(
            "prepared mixer rate does not match the negotiated output rate".into(),
        ));
    }
    let output_channels = usize::from(target.supported.channels());
    if output_channels == 0 {
        return Err(AudioError::InvalidArgument(
            "output device reports zero channels".into(),
        ));
    }
    let format = target.supported.sample_format();
    let config = target.supported.config();
    let position_frames = Arc::new(AtomicUsize::new(0));
    let paused = Arc::new(AtomicBool::new(false));
    let loop_enabled = Arc::new(AtomicBool::new(false));
    let loop_start_frames = Arc::new(AtomicUsize::new(0));
    let loop_end_frames = Arc::new(AtomicUsize::new(0));
    let stream_error = Arc::new(AtomicU32::new(0));
    let callback_metrics = RealtimeCallbackMetrics::new();
    let drain_frames = (output_sample_rate / 4) as usize;

    let stream = build_realtime_playback_stream(
        &target.device,
        config,
        format,
        Arc::clone(&graph),
        output_channels,
        drain_frames,
        Arc::clone(&position_frames),
        Arc::clone(&paused),
        Arc::clone(&loop_enabled),
        Arc::clone(&loop_start_frames),
        Arc::clone(&loop_end_frames),
        Arc::clone(&stream_error),
        output_sample_rate,
        callback_metrics.clone(),
    )?;
    stream.play().map_err(|error| AudioError::InvalidArgument(format!(
        "cannot start realtime multitrack playback: {error}"
    )))?;

    let handle = Box::new(AuraAudioPlaybackHandle {
        _stream: stream,
        total_frames: AtomicUsize::new(total_frames),
        drain_frames,
        output_sample_rate,
        realtime_graph: Some(graph),
        position_frames,
        paused,
        loop_enabled,
        loop_start_frames,
        loop_end_frames,
        stream_error,
        callback_metrics,
    });
    Ok(Box::into_raw(handle))
}

/// Starts playing a PCM/IEEE-float WAV through the operating system's default
/// output device. No resampling is performed: the output device must support
/// the WAV's sample rate.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_start_wav(
    wav_data: *const u8,
    wav_len: usize,
    out_sample_rate: *mut u32,
    out_total_frames: *mut u64,
) -> *mut AuraAudioPlaybackHandle {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if wav_data.is_null() || wav_len < 44 || wav_len > 1_073_741_824 {
            return Err(AudioError::InvalidArgument(
                "WAV buffer must be non-null and between 44 bytes and 1 GiB".into(),
            ));
        }
        if out_sample_rate.is_null() || out_total_frames.is_null() {
            return Err(AudioError::InvalidArgument(
                "playback output pointers must not be null".into(),
            ));
        }
        // SAFETY: Caller guarantees wav_data points to wav_len readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(wav_data, wav_len) };
        let audio = crate::AudioBuffer::from_wav(bytes)?;
        let source_channels = usize::from(audio.channels());
        let sample_rate = audio.sample_rate();
        if !(1..=2).contains(&source_channels) || audio.frame_count() == 0 {
            return Err(AudioError::InvalidArgument(
                "playback expects a non-empty mono or stereo WAV".into(),
            ));
        }

        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| AudioError::InvalidArgument(
                "no default audio output device is available".into(),
            ))?;

        let supported = device
            .supported_output_configs()
            .map_err(|error| AudioError::InvalidArgument(format!(
                "cannot query output configurations: {error}"
            )))?
            .filter(|range| range.channels() >= source_channels as u16)
            .filter_map(|range| range.try_with_sample_rate(sample_rate))
            .next()
            .ok_or_else(|| AudioError::InvalidArgument(format!(
                "the default output device does not support {sample_rate} Hz playback"
            )))?;

        let output_channels = usize::from(supported.channels());
        if output_channels == 0 {
            return Err(AudioError::InvalidArgument(
                "output device reports zero channels".into(),
            ));
        }
        let format = supported.sample_format();
        let config = supported.config();
        let samples = Arc::new(audio.into_samples());
        let total_frames = samples.len() / source_channels;
        let position_frames = Arc::new(AtomicUsize::new(0));
        let paused = Arc::new(AtomicBool::new(false));
        let loop_enabled = Arc::new(AtomicBool::new(false));
        let loop_start_frames = Arc::new(AtomicUsize::new(0));
        let loop_end_frames = Arc::new(AtomicUsize::new(0));
        let stream_error = Arc::new(AtomicU32::new(0));
        let stream = build_playback_stream(
            &device,
            config,
            format,
            samples,
            source_channels,
            output_channels,
            Arc::clone(&position_frames),
            Arc::clone(&paused),
            Arc::clone(&loop_enabled),
            Arc::clone(&loop_start_frames),
            Arc::clone(&loop_end_frames),
            Arc::clone(&stream_error),
        )?;
        stream
            .play()
            .map_err(|error| AudioError::InvalidArgument(format!(
                "cannot start audio playback: {error}"
            )))?;

        // SAFETY: Output pointers are validated and writable per the C ABI contract.
        unsafe {
            *out_sample_rate = sample_rate;
            *out_total_frames = total_frames as u64;
        }
        Ok::<_, AudioError>(Box::into_raw(Box::new(AuraAudioPlaybackHandle {
            _stream: stream,
            total_frames: AtomicUsize::new(total_frames),
            drain_frames: (sample_rate / 4) as usize,
            output_sample_rate: sample_rate,
            realtime_graph: None,
            position_frames,
            paused,
            loop_enabled,
            loop_start_frames,
            loop_end_frames,
            stream_error,
            callback_metrics: RealtimeCallbackMetrics::new(),
        })))
    }));

    match result {
        Ok(Ok(handle)) => {
            set_ffi_error("");
            handle
        }
        Ok(Err(error)) => {
            set_ffi_error(&error.to_string());
            ptr::null_mut()
        }
        Err(_) => {
            set_ffi_error("audio playback failed unexpectedly");
            ptr::null_mut()
        }
    }
}

/// Realtime callback count since the stream was opened.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_callback_count(handle: *const AuraAudioPlaybackHandle) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.callback_metrics.callbacks.load(Ordering::Relaxed)
}

/// Output frames processed by the realtime callback.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_processed_frames(handle: *const AuraAudioPlaybackHandle) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.callback_metrics.processed_frames.load(Ordering::Relaxed)
}

/// Sum of measured callback execution time in nanoseconds.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_total_callback_ns(handle: *const AuraAudioPlaybackHandle) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.callback_metrics.total_callback_ns.load(Ordering::Relaxed)
}

/// Longest observed realtime callback execution time in nanoseconds.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_max_callback_ns(handle: *const AuraAudioPlaybackHandle) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.callback_metrics.max_callback_ns.load(Ordering::Relaxed)
}

/// Callback runs that exceeded their own output-block time budget.
/// This is a software deadline indicator, not a driver underrun counter.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_deadline_misses(handle: *const AuraAudioPlaybackHandle) -> u64 {
    if handle.is_null() { return 0; }
    unsafe { &*handle }.callback_metrics.deadline_misses.load(Ordering::Relaxed)
}

/// Returns the playback head in sample frames.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_position_frames(
    handle: *const AuraAudioPlaybackHandle,
) -> u64 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: Caller must provide a live playback handle.
    let playback = unsafe { &*handle };
    (playback.position_frames.load(Ordering::Acquire) as u64)
        .min(playback.total_frames.load(Ordering::Acquire) as u64)
}

/// Returns 0 while active (playing, paused or looping), 1 when complete, and 2 after an output stream error.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_status(
    handle: *const AuraAudioPlaybackHandle,
) -> u32 {
    if handle.is_null() {
        return 2;
    }
    // SAFETY: Caller must provide a live playback handle.
    let playback = unsafe { &*handle };
    if playback.stream_error.load(Ordering::Acquire) != 0 {
        return 2;
    }
    if playback.loop_enabled.load(Ordering::Acquire)
        || playback.paused.load(Ordering::Acquire)
    {
        return 0;
    }
    let drained_until = playback.total_frames.load(Ordering::Acquire).saturating_add(playback.drain_frames) as u64;
    if playback.position_frames.load(Ordering::Acquire) as u64 >= drained_until {
        1
    } else {
        0
    }
}

/// Pauses output while preserving the current sample-frame playhead.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_pause(
    handle: *mut AuraAudioPlaybackHandle,
) -> i32 {
    if handle.is_null() {
        set_ffi_error("playback handle is null");
        return -1;
    }
    // SAFETY: Caller must pass a live playback handle and not stop it concurrently.
    unsafe { &*handle }.paused.store(true, Ordering::Release);
    set_ffi_error("");
    0
}

/// Resumes output from the current sample-frame playhead.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_resume(
    handle: *mut AuraAudioPlaybackHandle,
) -> i32 {
    if handle.is_null() {
        set_ffi_error("playback handle is null");
        return -1;
    }
    // SAFETY: Caller must pass a live playback handle and not stop it concurrently.
    unsafe { &*handle }.paused.store(false, Ordering::Release);
    set_ffi_error("");
    0
}

/// Seeks to an exact frame. Seeking past the end is rejected.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_seek(
    handle: *mut AuraAudioPlaybackHandle,
    frame: u64,
) -> i32 {
    if handle.is_null() {
        set_ffi_error("playback handle is null");
        return -1;
    }
    // SAFETY: Caller must pass a live playback handle and not stop it concurrently.
    let playback = unsafe { &*handle };
    if frame > playback.total_frames.load(Ordering::Acquire) as u64 {
        set_ffi_error("seek frame is beyond the end of the audio");
        return -2;
    }
    let Ok(frame) = usize::try_from(frame) else {
        set_ffi_error("seek frame is too large for this platform");
        return -2;
    };
    playback.position_frames.store(frame, Ordering::Release);
    set_ffi_error("");
    0
}

/// Enables/disables a loop range in sample frames. A valid enabled range is
/// non-empty and must end no later than the decoded WAV length.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_set_loop(
    handle: *mut AuraAudioPlaybackHandle,
    start_frame: u64,
    end_frame: u64,
    enabled: u8,
) -> i32 {
    if handle.is_null() || enabled > 1 {
        set_ffi_error("playback handle or loop enabled flag is invalid");
        return -1;
    }
    // SAFETY: Caller must pass a live playback handle and not stop it concurrently.
    let playback = unsafe { &*handle };
    if enabled == 1 {
        if start_frame >= end_frame || end_frame > playback.total_frames.load(Ordering::Acquire) as u64 {
            set_ffi_error("loop range must be non-empty and inside the audio duration");
            return -2;
        }
        let (Ok(start), Ok(end)) =
            (usize::try_from(start_frame), usize::try_from(end_frame))
        else {
            set_ffi_error("loop range is too large for this platform");
            return -2;
        };
        playback.loop_start_frames.store(start, Ordering::Release);
        playback.loop_end_frames.store(end, Ordering::Release);
        playback.loop_enabled.store(true, Ordering::Release);
        if playback.position_frames.load(Ordering::Acquire) >= end {
            playback.position_frames.store(start, Ordering::Release);
        }
    } else {
        playback.loop_enabled.store(false, Ordering::Release);
    }
    set_ffi_error("");
    0
}

/// Returns the negotiated output clock for a live playback handle.
pub(crate) unsafe fn playback_output_sample_rate(
    handle: *const AuraAudioPlaybackHandle,
) -> Result<u32, AudioError> {
    if handle.is_null() {
        return Err(AudioError::InvalidArgument("playback handle is null".into()));
    }
    // SAFETY: The caller must keep the playback handle alive for this query.
    Ok(unsafe { &*handle }.output_sample_rate)
}

/// Replaces a playing session graph without stopping the output stream.
/// The callback picks up the new immutable snapshot at the next audio block.
pub(crate) unsafe fn replace_realtime_session(
    handle: *mut AuraAudioPlaybackHandle,
    mixer: Arc<RealtimeMixer>,
) -> Result<u64, AudioError> {
    if handle.is_null() {
        return Err(AudioError::InvalidArgument(
            "playback handle is null".into(),
        ));
    }
    // SAFETY: Caller passes a live playback handle and does not stop it concurrently.
    let playback = unsafe { &*handle };
    let graph = playback.realtime_graph.as_ref().ok_or_else(|| {
        AudioError::InvalidArgument(
            "live session replacement is only supported for multitrack playback".into(),
        )
    })?;
    if mixer.sample_rate != playback.output_sample_rate {
        return Err(AudioError::InvalidArgument(
            "replacement graph must use the active output device sample rate".into(),
        ));
    }
    let total_frames = usize::try_from(mixer.total_frames)
        .map_err(|_| AudioError::SizeOverflow)?;
    graph.publish(mixer)?;

    playback.total_frames.store(total_frames, Ordering::Release);
    let position = playback.position_frames.load(Ordering::Acquire);
    if position > total_frames {
        playback.position_frames.store(total_frames, Ordering::Release);
    }
    if playback.loop_enabled.load(Ordering::Acquire) {
        let loop_end = playback.loop_end_frames.load(Ordering::Acquire);
        if loop_end > total_frames {
            playback.loop_enabled.store(false, Ordering::Release);
        } else if position >= loop_end {
            playback.position_frames.store(
                playback.loop_start_frames.load(Ordering::Acquire),
                Ordering::Release,
            );
        }
    }
    Ok(total_frames as u64)
}

/// Stops playback and releases the operating-system output stream.
#[no_mangle]
pub unsafe extern "C" fn aura_audio_playback_stop(
    handle: *mut AuraAudioPlaybackHandle,
) {
    if !handle.is_null() {
        // SAFETY: Caller transfers the unique Box ownership exactly once.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(handle));
        }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_rate_selection_clamps_to_the_nearest_supported_range() {
        assert_eq!(preferred_rate_in_range(44_100, 96_000, 48_000), 48_000);
        assert_eq!(preferred_rate_in_range(48_000, 96_000, 44_100), 48_000);
        assert_eq!(preferred_rate_in_range(8_000, 32_000, 48_000), 32_000);
    }

    #[test]
    fn playback_cursor_does_not_advance_while_paused() {
        let position = AtomicUsize::new(17);
        let paused = AtomicBool::new(true);
        let looping = AtomicBool::new(false);
        let start = AtomicUsize::new(0);
        let end = AtomicUsize::new(100);

        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            None
        );
        assert_eq!(position.load(Ordering::Acquire), 17);

        paused.store(false, Ordering::Release);
        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            Some(17)
        );
        assert_eq!(position.load(Ordering::Acquire), 18);
    }

    #[test]
    fn playback_cursor_wraps_at_loop_end_without_allocating() {
        let position = AtomicUsize::new(12);
        let paused = AtomicBool::new(false);
        let looping = AtomicBool::new(true);
        let start = AtomicUsize::new(10);
        let end = AtomicUsize::new(13);

        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            Some(12)
        );
        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            Some(10)
        );
        assert_eq!(position.load(Ordering::Acquire), 11);
    }

    #[test]
    fn playback_cursor_continues_normally_when_loop_is_disabled() {
        let position = AtomicUsize::new(8);
        let paused = AtomicBool::new(false);
        let looping = AtomicBool::new(false);
        let start = AtomicUsize::new(2);
        let end = AtomicUsize::new(5);

        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            Some(8)
        );
        assert_eq!(position.load(Ordering::Acquire), 9);
    }

    #[test]
    fn playback_cursor_observes_a_seek_at_the_next_frame_boundary() {
        let position = AtomicUsize::new(4);
        let paused = AtomicBool::new(false);
        let looping = AtomicBool::new(false);
        let start = AtomicUsize::new(0);
        let end = AtomicUsize::new(100);

        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            Some(4)
        );
        position.store(73, Ordering::Release);
        assert_eq!(
            claim_playback_frame(&position, &paused, &looping, &start, &end),
            Some(73)
        );
        assert_eq!(position.load(Ordering::Acquire), 74);
    }

    #[test]
    fn monitor_clock_servo_corrects_queue_drift_within_500_ppm() {
        let nominal = 3.0_f64;
        let low = monitor_clock_step(nominal, 0, 1000);
        let high = monitor_clock_step(nominal, 2000, 1000);
        assert!(low < nominal);
        assert!(high > nominal);
        assert!((low / nominal - 1.0).abs() <= 0.000501);
        assert!((high / nominal - 1.0).abs() <= 0.000501);
        assert_eq!(monitor_clock_step(nominal, 500, 0), nominal);
    }

    #[test]
    fn monitor_resampler_interpolates_input_clock_without_channel_skew() {
        let ring = FloatRing::new(16, 1).unwrap();
        ring.push_interleaved(&[0.0, 1.0, 0.0, -1.0], 1);
        let mut phase = 0.0;
        let first = ring.read_resampled_frame(&mut phase, 0.5).unwrap();
        let second = ring.read_resampled_frame(&mut phase, 0.5).unwrap();
        assert!((first.0 - 0.0).abs() < 0.000001);
        assert!((first.1 - 0.0).abs() < 0.000001);
        assert!((second.0 - 0.5).abs() < 0.000001);
        assert!((second.1 - 0.5).abs() < 0.000001);
    }

    #[test]
    fn ring_round_trips_stereo_frames_without_interleaving() {
        let ring = FloatRing::new(16, 2).unwrap();
        ring.push_interleaved(&[0.1, -0.1, 0.2, -0.2], 2);
        let mut output = [0.0_f32; 4];
        assert_eq!(ring.read_frames(&mut output, 2), 2);
        assert_eq!(output, [0.1, -0.1, 0.2, -0.2]);
    }

    #[test]
    fn ring_downmixes_to_mono_without_losing_channel_alignment() {
        let ring = FloatRing::new(1024, 1).unwrap();
        ring.push_interleaved(&[1.0, -1.0, 0.5, 0.5], 2);
        let mut output = [0.0_f32; 2];
        assert_eq!(ring.read_frames(&mut output, 2), 2);
        assert_eq!(output, [0.0, 0.5]);
        assert_eq!(ring.dropped_frames.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ring_reports_dropped_frames_when_the_consumer_falls_behind() {
        let ring = FloatRing::new(1024, 1).unwrap();
        let input = vec![0.25_f32; 1025];
        ring.push_interleaved(&input, 1);
        assert_eq!(ring.dropped_frames.load(Ordering::Relaxed), 1);
        let mut output = vec![0.0_f32; 1024];
        assert_eq!(ring.read_frames(&mut output, 1024), 1024);
        assert!(output.iter().all(|sample| (*sample - 0.25).abs() < 0.000001));
    }

    #[test]
    fn ring_never_exposes_unwritten_samples() {
        let ring = FloatRing::new(1024, 1).unwrap();
        let mut output = [0.0_f32; 8];
        assert_eq!(ring.read_frames(&mut output, 8), 0);
    }
}

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
use std::sync::atomic::{AtomicU32, AtomicUsize, AtomicU64, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{DeviceId, SampleFormat, Stream};

use crate::{set_ffi_error, AudioError};

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
            config.as_ref().map(|value| value.sample_rate().0).unwrap_or(0),
        );
    }
    json.push(']');
    Ok(json)
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
        let sample_rate = supported.sample_rate().0;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_round_trips_stereo_frames_without_interleaving() {
        let ring = FloatRing::new(16, 2).unwrap();
        ring.push_interleaved(&[0.1, -0.1, 0.2, -0.2], 2);
        let mut output = [0.0_f32; 4];
        assert_eq!(ring.read_frames(&mut output, 2), 2);
        assert_eq!(output, [0.1, -0.1, 0.2, -0.2]);
    }

    #[test]
    fn ring_downmixes_to_mono_and_reports_overruns_in_whole_frames() {
        let ring = FloatRing::new(1024, 1).unwrap();
        ring.push_interleaved(&[1.0, -1.0, 0.5, 0.5], 2);
        let mut output = [0.0_f32; 2];
        assert_eq!(ring.read_frames(&mut output, 2), 2);
        assert_eq!(output, [0.0, 0.5]);
        assert_eq!(ring.dropped_frames.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ring_never_exposes_unwritten_samples() {
        let ring = FloatRing::new(1024, 1).unwrap();
        let mut output = [0.0_f32; 8];
        assert_eq!(ring.read_frames(&mut output, 8), 0);
    }
}

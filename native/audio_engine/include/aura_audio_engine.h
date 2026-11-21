#ifndef AURA_AUDIO_ENGINE_H
#define AURA_AUDIO_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AuraEngineHandle AuraEngineHandle;

uint32_t aura_engine_abi_version(void);
const char *aura_engine_version(void);
const char *aura_engine_last_error(void);

AuraEngineHandle *aura_engine_create(uint32_t sample_rate, uint16_t channels);
void aura_engine_destroy(AuraEngineHandle *handle);

int32_t aura_engine_add_wav_asset(
    AuraEngineHandle *handle,
    const char *asset_id,
    const uint8_t *wav_data,
    size_t wav_len
);

int32_t aura_engine_add_track(
    AuraEngineHandle *handle,
    const char *track_id,
    float gain,
    float pan,
    uint8_t muted,
    uint8_t solo
);

/* Track-level realtime DSP. 0 Hz disables the high-pass filter;
 * threshold is a linear amplitude in 0.001..=1.0 and ratio is 1..=20. */
int32_t aura_engine_set_track_dsp(
    AuraEngineHandle *handle,
    const char *track_id,
    float high_pass_hz,
    float compressor_threshold,
    float compressor_ratio
);

int32_t aura_engine_add_clip(
    AuraEngineHandle *handle,
    const char *track_id,
    const char *clip_id,
    const char *asset_id,
    uint64_t start_frame,
    uint64_t source_start_frame,
    uint64_t duration_frames,
    float gain,
    float pan,
    uint8_t muted,
    uint64_t fade_in_frames,
    uint64_t fade_out_frames
);

int32_t aura_engine_render_wav(
    AuraEngineHandle *handle,
    uint16_t bit_depth,
    uint8_t **out_data,
    size_t *out_len,
    float *out_sample_peak,
    size_t *out_clipped_samples
);

void aura_engine_free_buffer(uint8_t *data, size_t len);

/* Realtime microphone capture (CPAL). */
typedef struct AuraAudioCaptureHandle AuraAudioCaptureHandle;

char *aura_audio_input_devices_json(void);
void aura_audio_string_free(char *value);
AuraAudioCaptureHandle *aura_audio_capture_start(
    const char *device_id,
    uint32_t buffer_milliseconds,
    uint32_t *out_sample_rate,
    uint16_t *out_channels
);
int32_t aura_audio_capture_pause(AuraAudioCaptureHandle *handle);
uint32_t aura_audio_capture_read(
    AuraAudioCaptureHandle *handle,
    float *output,
    uint32_t max_frames
);
uint64_t aura_audio_capture_dropped_frames(const AuraAudioCaptureHandle *handle);
uint32_t aura_audio_capture_status(const AuraAudioCaptureHandle *handle);
void aura_audio_capture_stop(AuraAudioCaptureHandle *handle);

/* Direct microphone-to-output monitor. buffer_milliseconds requests both the
 * SPSC ring target and a CPAL callback buffer size; actual host sizes vary. */
typedef struct AuraAudioMonitorHandle AuraAudioMonitorHandle;
AuraAudioMonitorHandle *aura_audio_monitor_start(
    const char *input_device_id,
    const char *output_device_id,
    uint32_t buffer_milliseconds,
    float initial_gain
);
uint64_t aura_audio_monitor_underrun_frames(const AuraAudioMonitorHandle *handle);
uint64_t aura_audio_monitor_input_dropped_frames(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_status(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_input_sample_rate(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_output_sample_rate(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_requested_buffer_milliseconds(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_ring_capacity_frames(const AuraAudioMonitorHandle *handle);
/* buffer_frames are CPAL estimates; callback_frames are the latest
 * observed callback payload sizes and can vary from one invocation to another. */
uint32_t aura_audio_monitor_input_buffer_frames(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_output_buffer_frames(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_input_callback_frames(const AuraAudioMonitorHandle *handle);
uint32_t aura_audio_monitor_output_callback_frames(const AuraAudioMonitorHandle *handle);
uint64_t aura_audio_monitor_input_capture_to_callback_ns(const AuraAudioMonitorHandle *handle);
uint64_t aura_audio_monitor_output_callback_to_playback_ns(const AuraAudioMonitorHandle *handle);
uint64_t aura_audio_monitor_estimated_latency_ns(const AuraAudioMonitorHandle *handle);
uint64_t aura_audio_monitor_maximum_estimated_latency_ns(const AuraAudioMonitorHandle *handle);
uint64_t aura_audio_monitor_latency_estimate_count(const AuraAudioMonitorHandle *handle);
int32_t aura_audio_monitor_set_gain(const AuraAudioMonitorHandle *handle, float gain);
void aura_audio_monitor_stop(AuraAudioMonitorHandle *handle);

/* OS-device playback. Multitrack sessions and standalone WAV preview both
 * support explicit output-device selection and worker-side sample-rate
 * conversion before the CPAL callback. Both support sample-frame transport. */
typedef struct AuraAudioPlaybackHandle AuraAudioPlaybackHandle;

/* Starts direct callback-driven playback of the registered session.
 * Decoded clip buffers are mixed on the audio callback; no mix WAV is rendered. */
AuraAudioPlaybackHandle *aura_engine_realtime_playback_start(
    AuraEngineHandle *handle,
    const char *output_device_id,
    uint32_t *out_engine_sample_rate,
    uint64_t *out_total_frames
);

/* Publishes a replacement session graph while multitrack playback stays active.
 * The callback switches to the new immutable graph at the next audio block. */
int32_t aura_audio_playback_replace_session(
    AuraAudioPlaybackHandle *playback,
    AuraEngineHandle *session_handle,
    uint64_t *out_total_frames
);

AuraAudioPlaybackHandle *aura_audio_playback_start_wav(
    const uint8_t *wav_data,
    size_t wav_len,
    const char *output_device_id,
    uint32_t *out_source_sample_rate,
    uint32_t *out_engine_sample_rate,
    uint64_t *out_total_frames
);
uint64_t aura_audio_playback_position_frames(const AuraAudioPlaybackHandle *handle);
uint32_t aura_audio_playback_status(const AuraAudioPlaybackHandle *handle);
int32_t aura_audio_playback_pause(AuraAudioPlaybackHandle *handle);
int32_t aura_audio_playback_resume(AuraAudioPlaybackHandle *handle);
int32_t aura_audio_playback_seek(AuraAudioPlaybackHandle *handle, uint64_t frame);
int32_t aura_audio_playback_set_loop(
    AuraAudioPlaybackHandle *handle,
    uint64_t start_frame,
    uint64_t end_frame,
    uint8_t enabled
);
void aura_audio_playback_stop(AuraAudioPlaybackHandle *handle);

#ifdef __cplusplus
}
#endif

#endif

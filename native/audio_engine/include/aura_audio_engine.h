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
uint32_t aura_audio_capture_read(
    AuraAudioCaptureHandle *handle,
    float *output,
    uint32_t max_frames
);
uint64_t aura_audio_capture_dropped_frames(const AuraAudioCaptureHandle *handle);
uint32_t aura_audio_capture_status(const AuraAudioCaptureHandle *handle);
void aura_audio_capture_stop(AuraAudioCaptureHandle *handle);

#ifdef __cplusplus
}
#endif

#endif

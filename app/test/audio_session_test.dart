import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/features/session/models/audio_session.dart';

void main() {
  group('AudioSession', () {
    test('round-trips a multitrack project without losing sample-frame timing', () {
      final original = AudioSession(
        id: 'session-001',
        title: 'Narration',
        sampleRate: 48000,
        channels: 2,
        bitDepth: 24,
        tracks: [
          AudioTrack(
            id: 'track-voice',
            name: 'Lead Voice',
            kind: AudioTrackKind.voice,
            clips: [
              AudioClip(
                id: 'clip-001',
                mediaId: 'asset-voice-take-1',
                startFrame: 24000,
                sourceStartFrame: 960,
                durationFrames: 192000,
                gain: 0.85,
                pan: -0.1,
              ),
            ],
          ),
          AudioTrack(
            id: 'track-music',
            name: 'Music Bed',
            kind: AudioTrackKind.music,
            muted: true,
          ),
        ],
        markers: [AudioMarker(id: 'marker-1', label: 'Intro', frame: 48000)],
      );

      final encoded = jsonEncode(original.toJson());
      final restored = AudioSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(encoded) as Map),
      );

      expect(restored.sampleRate, 48000);
      expect(restored.bitDepth, 24);
      expect(restored.tracks, hasLength(2));
      expect(restored.tracks.first.clips.single.startFrame, 24000);
      expect(restored.tracks.first.clips.single.durationFrames, 192000);
      expect(restored.tracks.first.clips.single.gain, 0.85);
      expect(restored.markers.single.frame, 48000);
      expect(restored.tracks[1].muted, isTrue);
    });

    test('rejects invalid clip durations and sample rates', () {
      expect(
        () => AudioClip(
          id: 'clip',
          mediaId: 'asset',
          startFrame: 0,
          sourceStartFrame: 0,
          durationFrames: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => AudioSession(
          id: 'session',
          title: 'Invalid',
          sampleRate: 1000,
          channels: 2,
          bitDepth: 24,
        ),
        throwsArgumentError,
      );
    });

    test('rejects unknown future schema versions', () {
      expect(
        () => AudioSession.fromJson({
          'schemaVersion': 99,
          'id': 'future',
          'title': 'Future project',
          'sampleRate': 48000,
          'channels': 2,
          'bitDepth': 24,
        }),
        throwsFormatException,
      );
    });
  });
}

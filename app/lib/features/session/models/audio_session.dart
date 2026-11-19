/// Versioned, sample-frame-based project model for Aura Voice sessions.
///
/// Positions are integer sample frames (not floating-point seconds), so edit
/// boundaries remain deterministic across save/load and render operations.
enum AudioTrackKind { voice, music, effects, bus }

class AudioClip {
  AudioClip({
    required this.id,
    required this.mediaId,
    required this.startFrame,
    required this.sourceStartFrame,
    required this.durationFrames,
    this.gain = 1,
    this.pan = 0,
    this.muted = false,
    this.fadeInFrames = 0,
    this.fadeOutFrames = 0,
  }) {
    if (id.trim().isEmpty || mediaId.trim().isEmpty) {
      throw ArgumentError('Clip id and mediaId must not be empty.');
    }
    if (fadeInFrames < 0 || fadeOutFrames < 0 ||
        fadeInFrames > durationFrames || fadeOutFrames > durationFrames) {
      throw ArgumentError('Clip fades must be between zero and the clip duration.');
    }
    if (startFrame < 0 || sourceStartFrame < 0 || durationFrames <= 0) {
      throw ArgumentError('Clip frame positions must be non-negative and duration must be positive.');
    }
    if (!gain.isFinite || gain < 0) {
      throw ArgumentError.value(gain, 'gain', 'Must be a finite non-negative linear value.');
    }
    if (!pan.isFinite || pan < -1 || pan > 1) {
      throw ArgumentError.value(pan, 'pan', 'Must be between -1.0 (left) and 1.0 (right).');
    }
  }

  final String id;
  final String mediaId;
  final int startFrame;
  final int sourceStartFrame;
  final int durationFrames;
  final double gain;
  final double pan;
  final bool muted;
  final int fadeInFrames;
  final int fadeOutFrames;

  /// Splits this clip into two non-destructive source ranges.
  ///
  /// Existing edge fades stay at the outside edges. The split point must be
  /// beyond the fade-in and leave enough frames for the original fade-out.
  List<AudioClip> splitAtFrameOffset(
    int frameOffset, {
    required String firstId,
    required String secondId,
  }) {
    if (frameOffset <= 0 || frameOffset >= durationFrames) {
      throw RangeError.range(frameOffset, 1, durationFrames - 1, 'frameOffset');
    }
    final secondDuration = durationFrames - frameOffset;
    if (fadeInFrames > frameOffset || fadeOutFrames > secondDuration) {
      throw ArgumentError(
        'The split point must leave the original fade-in and fade-out on the outside clip edges.',
      );
    }
    return [
      AudioClip(
        id: firstId,
        mediaId: mediaId,
        startFrame: startFrame,
        sourceStartFrame: sourceStartFrame,
        durationFrames: frameOffset,
        gain: gain,
        pan: pan,
        muted: muted,
        fadeInFrames: fadeInFrames,
      ),
      AudioClip(
        id: secondId,
        mediaId: mediaId,
        startFrame: startFrame + frameOffset,
        sourceStartFrame: sourceStartFrame + frameOffset,
        durationFrames: secondDuration,
        gain: gain,
        pan: pan,
        muted: muted,
        fadeOutFrames: fadeOutFrames,
      ),
    ];
  }

  Map<String, Object> toJson() => {
        'id': id,
        'mediaId': mediaId,
        'startFrame': startFrame,
        'sourceStartFrame': sourceStartFrame,
        'durationFrames': durationFrames,
        'gain': gain,
        'pan': pan,
        'muted': muted,
        'fadeInFrames': fadeInFrames,
        'fadeOutFrames': fadeOutFrames,
      };

  factory AudioClip.fromJson(Map<String, dynamic> json) => AudioClip(
        id: json['id'] as String,
        mediaId: json['mediaId'] as String,
        startFrame: json['startFrame'] as int,
        sourceStartFrame: json['sourceStartFrame'] as int,
        durationFrames: json['durationFrames'] as int,
        gain: (json['gain'] as num?)?.toDouble() ?? 1,
        pan: (json['pan'] as num?)?.toDouble() ?? 0,
        muted: json['muted'] as bool? ?? false,
        fadeInFrames: json['fadeInFrames'] as int? ?? 0,
        fadeOutFrames: json['fadeOutFrames'] as int? ?? 0,
      );
}

class AudioTrack {
  AudioTrack({
    required this.id,
    required this.name,
    this.kind = AudioTrackKind.voice,
    this.gain = 1,
    this.pan = 0,
    this.muted = false,
    this.solo = false,
    this.armed = false,
    List<AudioClip> clips = const [],
  }) : clips = List.unmodifiable(clips) {
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw ArgumentError('Track id and name must not be empty.');
    }
    if (!gain.isFinite || gain < 0) {
      throw ArgumentError.value(gain, 'gain', 'Must be a finite non-negative linear value.');
    }
    if (!pan.isFinite || pan < -1 || pan > 1) {
      throw ArgumentError.value(pan, 'pan', 'Must be between -1.0 and 1.0.');
    }
    final clipIds = this.clips.map((clip) => clip.id).toSet();
    if (clipIds.length != this.clips.length) {
      throw ArgumentError('Clip ids must be unique within a track.');
    }
  }

  final String id;
  final String name;
  final AudioTrackKind kind;
  final double gain;
  final double pan;
  final bool muted;
  final bool solo;
  final bool armed;
  final List<AudioClip> clips;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'gain': gain,
        'pan': pan,
        'muted': muted,
        'solo': solo,
        'armed': armed,
        'clips': clips.map((clip) => clip.toJson()).toList(),
      };

  factory AudioTrack.fromJson(Map<String, dynamic> json) => AudioTrack(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: AudioTrackKind.values.firstWhere(
          (kind) => kind.name == (json['kind'] as String? ?? 'voice'),
          orElse: () => AudioTrackKind.voice,
        ),
        gain: (json['gain'] as num?)?.toDouble() ?? 1,
        pan: (json['pan'] as num?)?.toDouble() ?? 0,
        muted: json['muted'] as bool? ?? false,
        solo: json['solo'] as bool? ?? false,
        armed: json['armed'] as bool? ?? false,
        clips: (json['clips'] as List<dynamic>? ?? const [])
            .map((item) => AudioClip.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
      );
}

class AudioMarker {
  AudioMarker({required this.id, required this.label, required this.frame}) {
    if (id.trim().isEmpty || label.trim().isEmpty || frame < 0) {
      throw ArgumentError('Marker requires an id, label and non-negative frame.');
    }
  }

  final String id;
  final String label;
  final int frame;

  Map<String, Object> toJson() => {'id': id, 'label': label, 'frame': frame};

  factory AudioMarker.fromJson(Map<String, dynamic> json) => AudioMarker(
        id: json['id'] as String,
        label: json['label'] as String,
        frame: json['frame'] as int,
      );
}

class AudioSession {
  AudioSession({
    required this.id,
    required this.title,
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    List<AudioTrack> tracks = const [],
    List<AudioMarker> markers = const [],
  })  : tracks = List.unmodifiable(tracks),
        markers = List.unmodifiable(markers) {
    if (id.trim().isEmpty || title.trim().isEmpty) {
      throw ArgumentError('Session id and title must not be empty.');
    }
    if (sampleRate < 8000 || sampleRate > 384000) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be between 8000 and 384000 Hz.');
    }
    if (channels < 1 || channels > 8) {
      throw ArgumentError.value(channels, 'channels', 'Must be between 1 and 8.');
    }
    if (![16, 24, 32].contains(bitDepth)) {
      throw ArgumentError.value(bitDepth, 'bitDepth', 'Supported project depths are 16, 24 and 32.');
    }
    final trackIds = this.tracks.map((track) => track.id).toSet();
    if (trackIds.length != this.tracks.length) {
      throw ArgumentError('Track ids must be unique within a session.');
    }
    final markerIds = this.markers.map((marker) => marker.id).toSet();
    if (markerIds.length != this.markers.length) {
      throw ArgumentError('Marker ids must be unique within a session.');
    }
  }

  static const currentSchemaVersion = 1;

  final String id;
  final String title;
  final int sampleRate;
  final int channels;
  final int bitDepth;
  final List<AudioTrack> tracks;
  final List<AudioMarker> markers;

  Map<String, Object> toJson() => {
        'schemaVersion': currentSchemaVersion,
        'id': id,
        'title': title,
        'sampleRate': sampleRate,
        'channels': channels,
        'bitDepth': bitDepth,
        'tracks': tracks.map((track) => track.toJson()).toList(),
        'markers': markers.map((marker) => marker.toJson()).toList(),
      };

  factory AudioSession.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int? ?? 1;
    if (version != currentSchemaVersion) {
      throw FormatException('Unsupported Aura Voice session schema version: $version');
    }
    return AudioSession(
      id: json['id'] as String,
      title: json['title'] as String,
      sampleRate: json['sampleRate'] as int,
      channels: json['channels'] as int,
      bitDepth: json['bitDepth'] as int,
      tracks: (json['tracks'] as List<dynamic>? ?? const [])
          .map((item) => AudioTrack.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(),
      markers: (json['markers'] as List<dynamic>? ?? const [])
          .map((item) => AudioMarker.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(),
    );
  }
}

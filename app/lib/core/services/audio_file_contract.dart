import 'dart:typed_data';

/// Contract implemented by native and unsupported-platform audio readers.
abstract interface class AudioFileReader {
  Future<Uint8List> read(String path);
}

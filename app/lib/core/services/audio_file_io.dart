import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readAudioFile(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('The audio file no longer exists.', path);
  }
  final length = await file.length();
  if (length < 44 || length > 268435456) {
    throw FileSystemException(
      'Preview supports WAV files from 44 bytes up to 256 MiB.',
      path,
    );
  }
  return file.readAsBytes();
}

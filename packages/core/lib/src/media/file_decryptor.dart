import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../crypto/bytes.dart';
import '../crypto/spade.dart';
import 'mp4.dart';

class FileSampleStore implements SampleStore {
  final RandomAccessFile file;
  FileSampleStore(this.file);
  @override
  int get length => file.lengthSync();
  @override
  Uint8List read(int offset, int size) {
    file.setPositionSync(offset);
    final result = Uint8List(size);
    var read = 0;
    while (read < size) {
      final n = file.readIntoSync(result, read, size);
      if (n == 0) throw const FormatException('Unexpected MP4 EOF');
      read += n;
    }
    return result;
  }

  @override
  void write(int offset, Uint8List bytes) {
    file.setPositionSync(offset);
    file.writeFromSync(bytes);
  }
}

class FileDecryptor {
  /// Working files only: caller atomically publishes the result after success.
  static Future<int> decrypt(String path, String spadeA) => Isolate.run(() {
    final decoded = Spade.decode(spadeA);
    if (decoded == null) {
      throw const FormatException('Unsupported or malformed spade key');
    }
    return decryptWithKeySync(path, decoded.hex);
  });
  static int decryptWithKeySync(String path, String keyHex) {
    final file = File(path).openSync(mode: FileMode.append);
    try {
      final store = FileSampleStore(file),
          plan = Mp4Cenc.inspect(FileSampleStore(file));
      if (plan.encryptedSamples == 0) {
        throw const FormatException('Expected CENC samples');
      }
      final count = Mp4Cenc.decrypt(store, plan, unhex(keyHex));
      final after = Mp4Cenc.inspect(store);
      if (after.encryptedSamples != 0) {
        throw StateError('CENC metadata remains');
      }
      file.flushSync();
      return count;
    } finally {
      file.closeSync();
    }
  }

  static Future<void> validateClear(String path) => Isolate.run(() {
    final file = File(path).openSync();
    try {
      final plan = Mp4Cenc.inspect(FileSampleStore(file));
      if (plan.encryptedSamples != 0) {
        throw const FormatException('Media still encrypted');
      }
    } finally {
      file.closeSync();
    }
  });
}

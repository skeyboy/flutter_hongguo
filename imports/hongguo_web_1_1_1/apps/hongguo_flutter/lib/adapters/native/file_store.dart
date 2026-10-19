import 'dart:io';
import 'dart:typed_data';
import 'package:hongguo_core/hongguo_core.dart';

class NativeFileStore implements RandomAccessStore {
  final RandomAccessFile file;
  NativeFileStore(this.file);
  @override
  int get length => file.lengthSync();
  @override
  Uint8List read(int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > length) {
      throw FormatException('文件读取越界');
    }
    file.setPositionSync(offset);
    final data = Uint8List(count);
    var read = 0;
    while (read < count) {
      final n = file.readIntoSync(data, read, count);
      if (n == 0) throw const FormatException('文件提前结束');
      read += n;
    }
    return data;
  }

  @override
  void write(int offset, List<int> data) {
    file.setPositionSync(offset);
    file.writeFromSync(data);
  }
}

/// Runs inside an isolate. Input/output are paths; full media never crosses isolates.
void decryptFile(Map<String, String> args) {
  final file = File(args['path']!).openSync(mode: FileMode.append);
  try {
    final store = NativeFileStore(file), span = findMoov(store);
    final analysis = analyzeMp4(
      ByteView(store.read(span.start, span.size), span.start),
    );
    validateMediaLayout(store, analysis.tracks);
    final encrypted = analysis.tracks.where((t) => t.encrypted).toList();
    final spade = args['spade'] ?? '';
    if (encrypted.isNotEmpty && spade.isEmpty) {
      throw const FormatException('加密轨道缺少 spade v1 密钥');
    }
    if (spade.isNotEmpty) {
      final key = Spade.toKey(spade).key;
      if (key == null) throw UnsupportedError('无法解析 spade v1 密钥');
      if (encrypted.isEmpty) throw UnsupportedError('模型声明加密但 MP4 未提供 CENC 索引');
      for (final track in encrypted) {
        decryptTrack(store, track, unhex(key));
      }
      final cleaned = stripEncryption(
        ByteView(store.read(span.start, span.size), span.start),
      );
      store.write(span.start, cleaned);
    }
    // Reparse the delivered file; all indexed samples must remain in file bounds.
    final cleanSpan = findMoov(store),
        clean = analyzeMp4(
          ByteView(
            store.read(cleanSpan.start, cleanSpan.size),
            cleanSpan.start,
          ),
        );
    validateMediaLayout(store, clean.tracks);
    if (clean.tracks.any((t) => t.encrypted)) throw StateError('解密后仍有加密信令');
    for (final track in clean.tracks) {
      for (var i = 0; i < track.sizes.length; i++) {
        if (track.offsets[i] < 0 ||
            track.offsets[i] + track.sizes[i] > store.length) {
          throw const FormatException('成品样本越界');
        }
      }
    }
    file.flushSync();
  } finally {
    file.closeSync();
  }
}

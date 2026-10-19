import 'dart:typed_data';

/// Synchronous random access is used only inside a platform worker isolate.
abstract interface class RandomAccessStore {
  int get length;
  Uint8List read(int offset, int count);
  void write(int offset, List<int> data);
}

class MemoryStore implements RandomAccessStore {
  final Uint8List data;
  MemoryStore(List<int> data) : data = Uint8List.fromList(data);
  @override
  int get length => data.length;
  @override
  Uint8List read(int offset, int count) =>
      Uint8List.fromList(data.sublist(offset, offset + count));
  @override
  void write(int offset, List<int> bytes) =>
      data.setRange(offset, offset + bytes.length, bytes);
}

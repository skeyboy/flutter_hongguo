import 'dart:io';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:path/path.dart' as p;

class NativeJsonStore implements KeyValueStore {
  final Directory directory;
  NativeJsonStore(this.directory);
  File _file(String key) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(key)) throw ArgumentError.value(key);
    return File(p.join(directory.path, '$key.json'));
  }

  @override
  Future<String?> read(String key) async {
    final f = _file(key);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await directory.create(recursive: true);
    final f = _file(key), part = File('${_file(key).path}.part');
    await part.writeAsString(value, flush: true);
    await part.rename(f.path);
  }
}

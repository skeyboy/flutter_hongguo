import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/search/search_history.dart';
import 'package:hongguo_app/settings/settings_store.dart';

class MemoryBackend implements PreferencesBackend {
  Map<String, dynamic>? data;
  bool fail = false;

  @override
  Future<Map<String, dynamic>?> read() async => data;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('disk full');
    data = value;
  }
}

/// Holds the write open so a queued save stays observable before it lands.
class SlowBackend implements PreferencesBackend {
  final released = Completer<void>();
  Map<String, dynamic>? data;

  @override
  Future<Map<String, dynamic>?> read() async => data;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    await released.future;
    data = value;
  }
}

void main() {
  test('newest first and a repeated term moves up', () async {
    final store = SearchHistory();
    await store.record('玄幻');
    await store.record('都市');
    await store.record('玄幻');
    expect(store.recent, ['玄幻', '都市']);
  });

  test('blanks are ignored and the list stays bounded', () async {
    final store = SearchHistory();
    for (var index = 0; index < 15; index++) {
      await store.record('词$index');
    }
    await store.record('   ');
    expect(store.recent, hasLength(SearchHistory.retained));
    expect(store.recent.first, '词14');
    expect(store.matching(''), hasLength(SearchHistory.shown));
  });

  test('matching narrows while typing', () async {
    final store = SearchHistory();
    await store.record('都市夜归人');
    await store.record('都市怪谈');
    await store.record('山海之间');
    expect(store.matching('都市'), ['都市怪谈', '都市夜归人']);
    expect(store.matching(' 山海 '), ['山海之间']);
    expect(store.matching('没有'), isEmpty);
  });

  test('one row can be removed', () async {
    final store = SearchHistory();
    await store.record('留下');
    await store.record('删掉');
    await store.remove('删掉');
    expect(store.recent, ['留下']);
  });

  test('the saved list is readable by the next session', () async {
    final backend = MemoryBackend();
    await SearchHistory(backend: backend).record('上一个会话');
    final reloaded = SearchHistory(backend: backend);
    await reloaded.load();
    expect(reloaded.recent, ['上一个会话']);
  });

  test('a failed write does not fake a saved history', () async {
    final backend = MemoryBackend()..fail = true;
    final store = SearchHistory(backend: backend);
    await expectLater(store.record('写不进去'), throwsStateError);
    expect(store.recent, isEmpty);
  });

  test('flush waits for the queued save', () async {
    final backend = SlowBackend();
    final store = SearchHistory(backend: backend);
    unawaited(store.record('退出时在写'));
    expect(store.recent, isEmpty);
    backend.released.complete();
    await store.flush();
    expect(store.recent, ['退出时在写']);
    expect(backend.data?['queries'], ['退出时在写']);
  });

  test('a file from another version is refused', () async {
    final backend = MemoryBackend()
      ..data = {
        'version': 2,
        'queries': ['旧'],
      };
    await expectLater(SearchHistory(backend: backend).load(), throwsStateError);
  });
}

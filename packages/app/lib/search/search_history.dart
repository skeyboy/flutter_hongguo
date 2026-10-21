import '../settings/settings_store.dart';

/// The most recent search terms, newest first.
///
/// This lives in its own preferences file rather than inside the personal
/// library because every library edit rewrites all watch records, and typing a
/// search must not pay for that.
class SearchHistory {
  static const retained = 12;
  static const shown = 3;

  final PreferencesBackend? backend;
  SearchHistory({this.backend});

  final _queries = <String>[];
  Future<void>? _loading;
  Future<void> _writes = Future.value();

  List<String> get recent => List.unmodifiable(_queries);

  /// Up to [shown] rows: the newest ones, or the closest matches once the
  /// viewer has started typing.
  List<String> matching(String typed) {
    final needle = typed.trim().toLowerCase();
    final hits = needle.isEmpty
        ? _queries
        : _queries.where((item) => item.toLowerCase().contains(needle));
    return List.unmodifiable(hits.take(shown).toList());
  }

  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });

  Future<void> _load() async {
    final data = await backend?.read();
    if (data == null) return;
    if (data['version'] != 1) throw StateError('搜索历史版本不受支持');
    final stored = <String>[];
    for (final value in data['queries'] as List? ?? []) {
      final item = '$value'.trim();
      if (item.isNotEmpty && !stored.contains(item)) stored.add(item);
      if (stored.length >= retained) break;
    }
    _queries
      ..clear()
      ..addAll(stored);
  }

  Future<void> record(String query) => _edit((queries) {
    final value = query.trim();
    if (value.isEmpty) return;
    queries.remove(value);
    queries.insert(0, value);
  });

  Future<void> remove(String query) =>
      _edit((queries) => queries.remove(query));

  /// Shutdown waits for the queued save, because a search is recorded without
  /// blocking the keyboard on the disk.
  Future<void> flush() => _writes;

  Future<void> _edit(void Function(List<String> queries) edit) {
    final result = _writes.then((_) async {
      await load();
      final queries = List<String>.of(_queries);
      edit(queries);
      final next = queries.take(retained).toList();
      await backend?.write({'version': 1, 'queries': next});
      _queries
        ..clear()
        ..addAll(next);
    });
    _writes = result.catchError((Object _) {});
    return result;
  }
}

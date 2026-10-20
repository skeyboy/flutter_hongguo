import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../catalog/library_cache.dart' show dramaJson;
import '../platform/runtime_contract.dart';
import '../settings/settings_store.dart';

enum DownloadPhase { queued, running, paused, ready, failed, cancelled }

class EpisodeDownload {
  final Drama drama;
  final Episode episode;
  final String quality;
  DownloadPhase phase;
  String message;
  double? fraction;
  int bytes;
  bool automaticPause;
  EpisodeDownload({
    required this.drama,
    required this.episode,
    required this.quality,
    this.phase = DownloadPhase.queued,
    this.message = '等待下载',
    this.bytes = 0,
    this.fraction,
    this.automaticPause = false,
  });
  String get key => '${episode.vid}_$quality';
  bool get retained =>
      ![DownloadPhase.failed, DownloadPhase.cancelled].contains(phase);
  Map<String, dynamic> toJson() => {
    'drama': dramaJson(drama),
    'vid': episode.vid,
    'index': episode.index,
    'title': episode.title,
    'quality': quality,
    'phase': phase.name,
    'bytes': bytes,
    'fraction': fraction,
    'message': message,
  };
  factory EpisodeDownload.fromJson(Map<String, dynamic> json) {
    final vid = json['vid'] as String, quality = json['quality'] as String;
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid) ||
        !RegExp(r'^(best|auto|\d{3,4}p)$').hasMatch(quality)) {
      throw const FormatException('Invalid download identity');
    }
    return EpisodeDownload(
      drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      episode: Episode(
        vid: vid,
        index: json['index'] as int,
        title: json['title'] as String? ?? '',
      ),
      quality: quality,
      message: json['message'] as String? ?? '',
      fraction: (json['fraction'] as num?)?.toDouble().clamp(0, 1),
      bytes: (json['bytes'] as int? ?? 0).clamp(0, 1 << 50),
      phase: DownloadPhase.values.byName(json['phase'] as String),
    );
  }
}

class _ActiveDownload {
  final EpisodeDownload task;
  PlaybackJob? job;
  bool released = false;
  _ActiveDownload(this.task);
  void stop() {
    job?.cancel();
    release();
  }

  void release() {
    if (!released && job != null) {
      released = true;
      job!.release();
    }
  }
}

/// Process-owned queue. The media pipeline remains the sole publisher of
/// validated MP4 files; task status alone never establishes offline readiness.
class DownloadManager extends ChangeNotifier with WidgetsBindingObserver {
  final PreferencesBackend backend;
  final AppSettings Function() settings;
  final Future<List<LocalEpisode>> Function() files;
  final PlaybackJob Function(
    EpisodeDownload,
    void Function(PreparationProgress),
  )
  prepare;
  final Future<void> Function(DramaDetail) remember;
  final Future<void> Function(String, String) deleteFile;
  final bool mobile, television;
  DownloadManager({
    required this.backend,
    required this.settings,
    required this.files,
    required this.prepare,
    required this.remember,
    required this.deleteFile,
    this.mobile = false,
    this.television = false,
  });
  final _tasks = <String, EpisodeDownload>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  Future<void> _mutations = Future.value();
  bool _loaded = false;
  _ActiveDownload? _active;
  bool _closed = false,
      _attached = false,
      _foreground = true,
      _settingsChanging = false;
  int _players = 0;
  DateTime? _lastProgress, _lastCheckpoint;
  String? warning;
  List<EpisodeDownload> get tasks =>
      List.unmodifiable(_tasks.values.toList().reversed);
  int get pendingCount => _tasks.values
      .where(
        (t) =>
            t.phase == DownloadPhase.queued || t.phase == DownloadPhase.running,
      )
      .length;
  int get readyCount =>
      _tasks.values.where((t) => t.phase == DownloadPhase.ready).length;
  int get _readyBytes => _tasks.values
      .where((t) => t.phase == DownloadPhase.ready)
      .fold(0, (n, t) => n + t.bytes);
  EpisodeDownload? taskFor(String vid, String quality) =>
      _tasks['${vid}_$quality'];
  bool retains(String vid, String quality) =>
      !_loaded || (taskFor(vid, quality)?.retained ?? false);
  bool running(String vid, String quality) =>
      taskFor(vid, quality)?.phase == DownloadPhase.running;
  String? get _blocked {
    if (_settingsChanging) return '正在更新下载策略';
    if (!_foreground &&
        (television || (mobile && !settings().backgroundDownloads))) {
      return '回到前台后继续';
    }
    if (_players > 0 && settings().concurrentPreparations <= 1) {
      return '正在播放，等待空闲后继续';
    }
    return null;
  }

  bool _notificationScheduled = false;
  void _emit() {
    if (_closed || _notificationScheduled) return;
    _notificationScheduled = true;
    // Coalesce state events and never notify an offstage page synchronously
    // while another route is being mounted or disposed.
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (!_closed) notifyListeners();
    });
  }

  Future<void> load() => _loading ??= _load().catchError((Object e) {
    _loading = null;
    throw e;
  });
  Future<void> _load() async {
    final data = await backend.read();
    if (data != null) {
      if (data['version'] != 1) throw StateError('下载记录版本不受支持');
      final parsed = <String, EpisodeDownload>{};
      for (final json in data['tasks'] as List? ?? []) {
        final task = EpisodeDownload.fromJson(
          Map<String, dynamic>.from(json as Map),
        );
        if (task.phase == DownloadPhase.queued ||
            task.phase == DownloadPhase.running) {
          task.phase = DownloadPhase.paused;
          task.message = '上次未完成，点击继续';
        }
        task.message = switch (task.phase) {
          DownloadPhase.ready => '已下载',
          DownloadPhase.failed => '上次下载未完成，请重试',
          DownloadPhase.cancelled => '已取消',
          DownloadPhase.paused => '已暂停，点击继续',
          _ => '等待下载',
        };
        parsed[task.key] = task;
      }
      _tasks.addAll(parsed);
    }
    _loaded = true;
    _emit();
  }

  Future<void> _save() {
    if (!_loaded) return Future.error(StateError('下载记录尚未读取，未写入变更'));
    final result = _writes.then((_) async {
      await backend.write({
        'version': 1,
        'tasks': _tasks.values.map((t) => t.toJson()).toList(),
      });
      if (warning != null) {
        warning = null;
        _emit();
      }
    });
    _writes = result.catchError((Object _) {
      warning = '下载记录保存失败，请检查存储空间；未保存的任务可能在重启后丢失';
      _emit();
    });
    return result;
  }

  void _checkpoint() {
    if (!_loaded) return;
    unawaited(_save().catchError((Object _) {}));
  }

  Future<void> flush() => _writes;
  Future<void> reconcile() async {
    await load();
    final available = {
      for (final f in await files()) '${f.vid}_${f.quality}': f,
    };
    for (final task in _tasks.values) {
      if (task.phase == DownloadPhase.running) continue;
      final file = available[task.key];
      if (file != null && task.retained) {
        task.phase = DownloadPhase.ready;
        task.bytes = file.bytes;
        task.fraction = 1;
        task.message = '已下载';
      } else if (task.phase == DownloadPhase.ready) {
        task.phase = DownloadPhase.failed;
        task.message = '文件已移除，请重新下载';
        task.bytes = 0;
      }
    }
    await _save();
    _emit();
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<int> enqueue(
    DramaDetail detail,
    Iterable<int> positions,
    String quality,
  ) => _serialized(() => _enqueue(detail, positions.toList(), quality));
  Future<int> _enqueue(
    DramaDetail detail,
    Iterable<int> positions,
    String quality,
  ) async {
    if (_closed) throw StateError('下载队列已关闭');
    await load();
    final chosen = positions.toSet().map((i) {
      if (i < 0 || i >= detail.episodes.length) {
        throw ArgumentError('Invalid episode');
      }
      final episode = detail.episodes[i];
      if (!RegExp(r'^\d{1,30}$').hasMatch(episode.vid) ||
          !RegExp(r'^(best|auto|\d{3,4}p)$').hasMatch(quality)) {
        throw ArgumentError('Invalid download');
      }
      return EpisodeDownload(
        drama: detail.drama,
        episode: episode,
        quality: quality,
      );
    }).toList();
    final add = chosen
        .where(
          (t) => ![
            DownloadPhase.ready,
            DownloadPhase.running,
            DownloadPhase.queued,
          ].contains(_tasks[t.key]?.phase),
        )
        .toList();
    if (add.isEmpty) return 0;
    final retained =
        _tasks.values.where((t) => t.retained).map((t) => t.key).toSet()
          ..addAll(add.map((t) => t.key));
    if (retained.length > settings().maxCacheFiles) {
      throw StateError('已达下载集数上限，请先删除下载或调整缓存设置');
    }
    if (_tasks.length + add.where((t) => !_tasks.containsKey(t.key)).length >
        500) {
      throw StateError('任务记录已达上限，请先整理下载管理');
    }
    if (_readyBytes >= settings().maxCacheMb * 1024 * 1024) {
      throw StateError('已达下载容量上限，请先删除下载或调整设置');
    }
    await remember(detail);
    final old = Map<String, EpisodeDownload>.from(_tasks);
    for (final task in add) {
      _tasks[task.key] = task;
    }
    try {
      await _save();
    } catch (_) {
      _tasks
        ..clear()
        ..addAll(old);
      rethrow;
    }
    _emit();
    _pump();
    return add.length;
  }

  void _pump() {
    if (_closed || !_loaded || _active != null || _blocked != null) return;
    final task = _tasks.values
        .where((t) => t.phase == DownloadPhase.queued)
        .firstOrNull;
    if (task == null) return;
    final active = _ActiveDownload(task);
    _active = active;
    task.phase = DownloadPhase.running;
    task.message = '正在准备';
    task.fraction = null;
    _lastCheckpoint = null;
    _lastProgress = null;
    _emit();
    unawaited(_run(active));
  }

  bool _current(_ActiveDownload a) =>
      !_closed &&
      identical(_active, a) &&
      identical(_tasks[a.task.key], a.task);
  Future<void> _run(_ActiveDownload active) async {
    final task = active.task;
    try {
      await _save();
      if (!_current(active)) return;
      if (readyCount >= settings().maxCacheFiles ||
          _readyBytes >= settings().maxCacheMb * 1024 * 1024) {
        throw StateError('quota');
      }
      final job = prepare(task, (p) {
        if (!_current(active)) return;
        final allocated = p.total > p.received ? p.total : p.received;
        if (allocated > 0 &&
            _readyBytes + allocated > settings().maxCacheMb * 1024 * 1024) {
          task.phase = DownloadPhase.failed;
          task.message = '超过下载容量上限，请清理下载或调整设置';
          _active = null;
          active.stop();
          _checkpoint();
          _emit();
          _pump();
          return;
        }
        final changed = task.message != p.label;
        task.message = p.label;
        task.fraction = p.fraction;
        final now = DateTime.now();
        if (changed ||
            _lastProgress == null ||
            now.difference(_lastProgress!).inMilliseconds >= 200) {
          _lastProgress = now;
          _emit();
        }
        if (changed ||
            _lastCheckpoint == null ||
            now.difference(_lastCheckpoint!).inSeconds >= 1) {
          _lastCheckpoint = now;
          _checkpoint();
        }
      });
      active.job = job;
      final result = job.source;
      if (!_current(active)) active.stop();
      await result;
      if (!_current(active)) return;
      final file = (await files())
          .where((f) => '${f.vid}_${f.quality}' == task.key)
          .firstOrNull;
      if (!_current(active)) return;
      if (file == null) throw StateError('Completion file missing');
      if (readyCount >= settings().maxCacheFiles ||
          _readyBytes + file.bytes > settings().maxCacheMb * 1024 * 1024) {
        throw StateError('quota');
      }
      task.phase = DownloadPhase.ready;
      task.message = '已下载';
      task.fraction = 1;
      task.bytes = file.bytes;
      task.automaticPause = false;
      await _save();
      _emit();
    } catch (_) {
      if (_current(active)) {
        if (task.phase == DownloadPhase.ready) {
          // The validated file is already published and must stay protected
          // even if the final task-state write failed (e.g. disk full).
          task.message = '已下载，记录保存待重试';
        } else {
          task.phase = DownloadPhase.failed;
          task.message = '下载未完成，请检查网络、存储或签名设置后重试';
          task.fraction = null;
        }
        _checkpoint();
        _emit();
      }
    } finally {
      active.release();
      if (identical(_active, active)) _active = null;
      _pump();
    }
  }

  void pause(String key, {bool automatic = false, String? reason}) {
    final task = _tasks[key];
    if (task == null ||
        ![DownloadPhase.queued, DownloadPhase.running].contains(task.phase)) {
      return;
    }
    task.phase = DownloadPhase.paused;
    task.message = reason ?? '已暂停，继续时可能重新传输';
    task.automaticPause = automatic;
    if (_active?.task == task) {
      final active = _active!;
      _active = null;
      active.stop();
    }
    _checkpoint();
    _emit();
    _pump();
  }

  void resume(String key) {
    final task = _tasks[key];
    if (task == null ||
        ![
          DownloadPhase.paused,
          DownloadPhase.failed,
          DownloadPhase.cancelled,
        ].contains(task.phase)) {
      return;
    }
    final retained =
        _tasks.values.where((t) => t.retained).map((t) => t.key).toSet()
          ..add(task.key);
    if (retained.length > settings().maxCacheFiles ||
        _readyBytes >= settings().maxCacheMb * 1024 * 1024) {
      task.phase = DownloadPhase.failed;
      task.message = '超过下载上限，请清理下载或调整设置';
      _checkpoint();
      _emit();
      return;
    }
    task.phase = DownloadPhase.queued;
    task.message = '等待下载';
    task.fraction = null;
    task.automaticPause = false;
    _checkpoint();
    _emit();
    _pump();
  }

  void cancel(String key) {
    final task = _tasks[key];
    if (task == null || task.phase == DownloadPhase.ready) return;
    pause(key);
    task.phase = DownloadPhase.cancelled;
    task.message = '已取消';
    task.automaticPause = false;
    _checkpoint();
    _emit();
    _pump();
  }

  Future<void> forget(String vid, String quality) =>
      _serialized(() => _forget(vid, quality));
  Future<void> _forget(String vid, String quality) async {
    final key = '${vid}_$quality';
    if (_active?.task.key == key) cancel(key);
    final old = _tasks.remove(key);
    try {
      await _save();
    } catch (_) {
      if (old != null) _tasks[key] = old;
      rethrow;
    }
    _emit();
  }

  Future<void> remove(String key) async {
    final task = _tasks[key];
    if (task == null) return;
    final existing = (await files())
        .where((f) => '${f.vid}_${f.quality}' == key)
        .firstOrNull;
    if (existing?.inUse == true) throw StateError('正在使用该视频，请结束播放后再删除');
    cancel(key);
    if (task.phase == DownloadPhase.ready || existing != null) {
      await deleteFile(task.episode.vid, task.quality);
      if ((await files()).any((f) => '${f.vid}_${f.quality}' == key)) {
        throw StateError('文件正在使用或无法删除，请稍后重试');
      }
    }
    await forget(task.episode.vid, task.quality);
  }

  void _applyPolicy() {
    final blocked = _blocked;
    if (blocked != null) {
      for (final task in _tasks.values.toList()) {
        pause(task.key, automatic: true, reason: blocked);
      }
    } else {
      for (final task in _tasks.values.where(
        (t) => t.phase == DownloadPhase.paused && t.automaticPause,
      )) {
        task.phase = DownloadPhase.queued;
        task.message = '等待下载';
        task.automaticPause = false;
      }
      _checkpoint();
      _emit();
      _pump();
    }
  }

  void setForeground(bool value) {
    _foreground = value;
    _applyPolicy();
  }

  void playbackEntered() {
    _players++;
    _applyPolicy();
  }

  void playbackLeft() {
    if (_players > 0) _players--;
    _applyPolicy();
  }

  void policyChanged() => _applyPolicy();
  void beginSettingsChange() {
    _settingsChanging = true;
    _applyPolicy();
  }

  void endSettingsChange() {
    _settingsChanging = false;
    _applyPolicy();
  }

  void attachLifecycle() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      setForeground(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setForeground(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      setForeground(false);
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    if (_attached) WidgetsBinding.instance.removeObserver(this);
    _active?.stop();
    _active = null;
    for (final task in _tasks.values) {
      if (task.phase == DownloadPhase.running ||
          task.phase == DownloadPhase.queued) {
        task.phase = DownloadPhase.paused;
        task.message = '上次未完成，点击继续';
        task.automaticPause = false;
      }
    }
    await _save().catchError((Object _) {});
    await flush();
  }
}

import 'dart:async';

import 'playback_failure.dart';

/// 自动连播的「一次延迟重试」预算。
///
/// 自动切集发生在上一集的 completed 通知里：此时上一集的 platform view 还在
/// 拆除，TV 的新 controller 紧接着 initialize，原生播放器尚未释放时会偶发
/// 平台错误。立刻重试仍会撞上同一个窗口，所以这里只安排一次**延迟**重播。
///
/// 本类不碰手动重试：错误卡片上的「重新准备」直接调 _play，用户选集也直接
/// 调 _play。它们只会调用 [cancel] 让待触发的重播失效。
class AutoNextRecovery {
  AutoNextRecovery({
    this.delay = const Duration(milliseconds: 800),
    RecoveryTimer Function(Duration delay, void Function() onFire)? timerFactory,
    bool Function(Object error)? transient,
  }) : _timerFactory = timerFactory ?? _TimerHandle.new,
        _transient = transient ?? isTransientAutoNextFailure;

  /// 让原生 video_player / platform view 完成拆除再重播。
  final Duration delay;
  final RecoveryTimer Function(Duration delay, void Function() onFire)
  _timerFactory;
  final bool Function(Object error) _transient;

  RecoveryTimer? _timer;
  int _generation = 0;
  int? _target;
  bool _retryUsed = false;
  bool _disposed = false;

  /// 本次连播切换是否已经用掉重试预算。
  bool get retryUsed => _retryUsed;

  /// 是否挂着一次尚未触发的重播。
  bool get pending => _timer != null;

  /// 开始一次自动切集：作废上一笔待触发重播，并重置「只重试一次」的预算。
  void begin(int target) {
    _cancelTimer();
    _generation++;
    _target = target;
    _retryUsed = false;
  }

  /// 当前自动切集失败时调用。只有瞬时失败、且预算未用完、且 [active] 仍为真
  /// 才安排重播；返回 true 表示确实安排了。
  ///
  /// [active] 应校验页面仍在树中、位置仍是本次切集的目标、且未被用户接管。
  /// [retry] 必须直接播 [target]，不要再经过本类，否则会形成重试循环。
  bool fail(
    Object error, {
    required bool Function() active,
    required void Function(int target) retry,
  }) {
    if (_disposed) return false;
    final target = _target;
    if (target == null || _retryUsed || _timer != null) return false;
    if (!active()) return false;
    if (!_transient(error)) return false;

    final generation = _generation;
    _retryUsed = true;
    var fired = false;
    _timer = _timerFactory(delay, () {
      // 计时器只该生效一次：重复触发不得再次拉起播放。
      if (fired) return;
      fired = true;
      _timer = null;
      if (_disposed || generation != _generation || !active()) return;
      // 先解绑目标：这次重播本身再失败也不该再排一次。
      _target = null;
      retry(target);
    });
    return true;
  }

  /// 本次切集已确认成功，丢弃残留的目标记录。
  void settle() {
    _cancelTimer();
    _target = null;
  }

  /// 用户导航离开、手动选集、切后台：待触发的重播立刻失效。
  /// 预算不在这里重置——手动路径不该获得一次「免费」自动重试。
  void cancel() {
    _generation++;
    _cancelTimer();
    _target = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 测试与生产共用的计时器句柄。生产用 [Timer]，测试注入可手动触发的假件。
abstract class RecoveryTimer {
  void cancel();
}

class _TimerHandle implements RecoveryTimer {
  final Timer _timer;
  _TimerHandle(Duration delay, void Function() onFire)
    : _timer = Timer(delay, onFire);
  @override
  void cancel() => _timer.cancel();
}

/// 自动切集里值得「再播一次」的失败。
///
/// 平台错误（video_player 的 errorDescription 包成 [PlaybackRuntimeError]）
/// 最常见：取源已成功，只是新 controller 打开时撞上旧 platform view 的拆除。
/// 取源侧的超时/网络/三层无片源/结构不全也会偶发；取消、本地缺文件、
/// 地址被拒与未知异常不在此列——前者是用户主动行为，后者重试不会变好。
bool isTransientAutoNextFailure(Object error) {
  if (error is PlaybackRuntimeError) return true;
  return switch (PlaybackFailure.classify(error).kind) {
    PlaybackFailureKind.timeout ||
    PlaybackFailureKind.network ||
    PlaybackFailureKind.incomplete ||
    PlaybackFailureKind.noSource => true,
    _ => false,
  };
}

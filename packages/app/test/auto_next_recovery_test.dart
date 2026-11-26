import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/playback/auto_next_recovery.dart';
import 'package:hongguo_app/playback/playback_failure.dart';

/// 可手动触发、可断言已取消的假计时器：测试不依赖真实等待。
class _FakeTimer implements RecoveryTimer {
  _FakeTimer(this.delay, this.onFire);
  final Duration delay;
  final void Function() onFire;
  bool cancelled = false;
  int fireCount = 0;

  @override
  void cancel() => cancelled = true;

  void fire() {
    if (cancelled) return;
    fireCount++;
    onFire();
  }
}

void main() {
  late List<_FakeTimer> timers;
  late AutoNextRecovery recovery;
  late List<int> retried;
  late bool active;

  setUp(() {
    timers = <_FakeTimer>[];
    retried = <int>[];
    active = true;
    recovery = AutoNextRecovery(
      timerFactory: (delay, onFire) {
        final timer = _FakeTimer(delay, onFire);
        timers.add(timer);
        return timer;
      },
    );
  });

  bool fail(Object error) => recovery.fail(
    error,
    active: () => active,
    retry: retried.add,
  );

  test('瞬时失败只安排一次延迟重播，重播目标就是自动切集的目标', () {
    recovery.begin(4);
    expect(
      fail(const PlaybackRuntimeError('platform view released')),
      isTrue,
    );
    expect(recovery.pending, isTrue);
    expect(timers, hasLength(1));
    expect(timers.single.delay, const Duration(milliseconds: 800));

    timers.single.fire();
    expect(retried, <int>[4]);
    expect(recovery.retryUsed, isTrue);
    expect(recovery.pending, isFalse);

    // 重播再失败也不该排第二次；旧计时器已失效。
    expect(fail(const PlaybackRuntimeError('again')), isFalse);
    expect(timers, hasLength(1));
    timers.single.fire();
    expect(retried, <int>[4]);
  });

  test('永久性失败不安排重播', () {
    for (final error in <Object>[
      const RequestCancelled(),
      StateError('该集本地缓存已不存在'),
      StateError('No compatible media URL/key'),
      const FormatException('boom'),
    ]) {
      recovery.begin(2);
      expect(fail(error), isFalse, reason: '$error 不该重试');
      expect(timers, isEmpty, reason: '$error 不该排计时器');
      expect(recovery.pending, isFalse);
    }
  });

  test('取源侧瞬时错误也安排重播', () {
    for (final error in <Object>[
      const MetadataDeadlineExceeded(),
      const IncompleteCatalogResponse('缺字段'),
      const PlaybackUnavailable('三层都没片源'),
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      ),
    ]) {
      recovery.begin(1);
      expect(fail(error), isTrue, reason: '$error 应重试');
      recovery.settle();
    }
  });

  test('取消后待触发的重播不再执行，也不再接受新的失败', () {
    recovery.begin(6);
    expect(fail(const PlaybackRuntimeError('oops')), isTrue);
    recovery.cancel();

    expect(timers.single.cancelled, isTrue);
    timers.single.fire();
    expect(retried, isEmpty);

    // 手动选集后的失败不再获得自动重试预算。
    expect(fail(const PlaybackRuntimeError('oops again')), isFalse);
    expect(timers, hasLength(1));
  });

  test('dispose 后待触发的重播不再执行', () {
    recovery.begin(3);
    expect(fail(const PlaybackRuntimeError('oops')), isTrue);
    recovery.dispose();

    expect(timers.single.cancelled, isTrue);
    timers.single.fire();
    expect(retried, isEmpty);
    expect(fail(const PlaybackRuntimeError('late')), isFalse);
  });

  test('用户已接管或页面失活时不安排重播', () {
    active = false;
    recovery.begin(5);
    expect(fail(const PlaybackRuntimeError('oops')), isFalse);
    expect(timers, isEmpty);
  });

  test('下一次自动切集恢复一次重试预算', () {
    recovery.begin(0);
    expect(fail(const PlaybackRuntimeError('first')), isTrue);
    timers.single.fire();
    expect(retried, <int>[0]);

    recovery.begin(1);
    expect(recovery.retryUsed, isFalse);
    expect(fail(const PlaybackRuntimeError('second')), isTrue);
    timers[1].fire();
    expect(retried, <int>[0, 1]);
  });

  test('begin 作废上一笔待触发的重播，不会播到旧目标', () {
    recovery.begin(7);
    expect(fail(const PlaybackRuntimeError('slow')), isTrue);
    recovery.begin(8); // 新一次自动切集抢在计时器触发前开始

    expect(timers.single.cancelled, isTrue);
    timers.single.fire();
    expect(retried, isEmpty);

    expect(fail(const PlaybackRuntimeError('slow again')), isTrue);
    timers[1].fire();
    expect(retried, <int>[8]);
  });
}

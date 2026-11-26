import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/screen_wake_lock.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('启用播放时申请锁，暂停时释放锁', () async {
    final calls = <bool>[];
    final lock = ScreenWakeLock(
      supported: () => true,
      toggle: (enabled) async => calls.add(enabled),
    );

    await lock.acquire();
    expect(lock.active, isTrue);
    await lock.release();
    expect(lock.active, isFalse);

    expect(calls, <bool>[true, false]);
  });

  test('重复启用或释放是幂等的', () async {
    final calls = <bool>[];
    final lock = ScreenWakeLock(
      supported: () => true,
      toggle: (enabled) async => calls.add(enabled),
    );

    await lock.acquire();
    await lock.acquire();
    await lock.setActive(true);
    await lock.release();
    await lock.release();
    await lock.setActive(false);

    expect(calls, <bool>[true, false]);
  });

  test('一轮播放结束后再次播放会重新申请锁', () async {
    final calls = <bool>[];
    final lock = ScreenWakeLock(
      supported: () => true,
      toggle: (enabled) async => calls.add(enabled),
    );

    await lock.acquire();
    await lock.release();
    await lock.acquire();
    await lock.release();

    expect(calls, <bool>[true, false, true, false]);
  });

  test('不支持的平台上完全不触碰插件', () async {
    var called = false;
    final lock = ScreenWakeLock(
      supported: () => false,
      toggle: (_) async => called = true,
    );

    await lock.acquire();
    await lock.setActive(true);
    await lock.release();

    expect(called, isFalse);
    expect(lock.active, isFalse);
  });

  test('非 Android 平台走 no-op，Android 平台才调用插件', () async {
    final calls = <bool>[];
    // flutter test 默认把 defaultTargetPlatform 设为 Android；显式覆盖以
    // 验证桌面/iOS 路径不会改动系统锁。
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final nonAndroid = ScreenWakeLock(
      toggle: (enabled) async => calls.add(enabled),
    );
    await nonAndroid.acquire();
    expect(calls, isEmpty);
    expect(nonAndroid.active, isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final android = ScreenWakeLock(
      toggle: (enabled) async => calls.add(enabled),
    );
    await android.acquire();
    expect(calls, <bool>[true]);
    expect(android.active, isTrue);
  });

  test('插件未注册或系统拒绝时播放不受影响，本地状态回滚', () async {
    for (final error in <Object>[
      MissingPluginException('wakelock_plus'),
      StateError('system refused'),
    ]) {
      final lock = ScreenWakeLock(
        supported: () => true,
        toggle: (_) => Future<void>.error(error),
      );
      await expectLater(lock.acquire(), completes);
      expect(lock.active, isFalse, reason: '$error');
    }
  });

  test('慢速 acquire 期间触发的 release 仍排在后面，不泄漏持有锁', () async {
    final calls = <bool>[];
    final gate = Completer<void>();
    final lock = ScreenWakeLock(
      supported: () => true,
      toggle: (enabled) async {
        calls.add(enabled);
        // 模拟平台通道迟迟没有返回：此时页面已经 pop 并请求释放。
        if (enabled) await gate.future;
      },
    );

    final acquiring = lock.acquire();
    final releasing = lock.release();
    gate.complete();
    await Future.wait([acquiring, releasing]);

    expect(calls, <bool>[true, false]);
    expect(lock.active, isFalse);
  });

  test('dispose 会释放已持有的锁', () async {
    final calls = <bool>[];
    final lock = ScreenWakeLock(
      supported: () => true,
      toggle: (enabled) async => calls.add(enabled),
    );

    await lock.acquire();
    await lock.dispose();

    expect(calls, <bool>[true, false]);
    expect(lock.active, isFalse);
  });
}

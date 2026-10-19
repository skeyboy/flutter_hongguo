import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'platform/runtime.dart';

typedef CoreProbe = Map<String, bool> Function();
final services = GetIt.asNewInstance()
  ..registerSingleton<CoreProbe>(runCoreDiagnostics);
final coreProbeProvider = Provider<CoreProbe>((ref) => services<CoreProbe>());
final runtimeProvider = FutureProvider<AppRuntime>((ref) async {
  final runtime = await createRuntime();
  ref.onDispose(() => runtime.dispose());
  return runtime;
});

final appSettingsProvider = StreamProvider<AppSettings>((ref) async* {
  final runtime = await ref.watch(runtimeProvider.future);
  if (runtime is! ConfigurableRuntime) {
    yield settingsFor(runtime);
    return;
  }
  yield* Stream<AppSettings>.multi((controller) {
    // Subscribe before the initial snapshot so a fast save cannot be lost.
    final subscription = runtime.settingsChanges.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.add(runtime.settings);
    controller.onCancel = subscription.cancel;
  });
});

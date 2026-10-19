import 'dart:math';
import 'dart:typed_data';

abstract interface class Clock {
  int get milliseconds;
}

class SystemClock implements Clock {
  const SystemClock();
  @override
  int get milliseconds => DateTime.now().millisecondsSinceEpoch;
}

abstract interface class RandomSource {
  Uint8List bytes(int count);
  int nextInt(int max);
}

class SecureRandomSource implements RandomSource {
  final Random _random = Random.secure();
  @override
  Uint8List bytes(int count) =>
      Uint8List.fromList(List.generate(count, (_) => _random.nextInt(256)));
  @override
  int nextInt(int max) => _random.nextInt(max);
}

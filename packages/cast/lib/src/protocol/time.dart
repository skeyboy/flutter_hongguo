/// UPnP spells instants and durations as `H:H:MM:SS.mmm`; the hour field may be
/// one or two digits and the milliseconds are always three.
const _timePattern =
    r'^(?<h>\d{1,2}):(?<m>\d{1,2}):(?<s>\d{1,2})(?:\.(?<ms>\d{1,3}))?$';

Duration? parseUpnpTime(String? value) {
  if (value == null) return null;
  final match = RegExp(_timePattern).firstMatch(value.trim());
  if (match == null) return null;
  final millis = (match.namedGroup('ms') ?? '0').padRight(3, '0');
  return Duration(
    hours: int.parse(match.namedGroup('h')!),
    minutes: int.parse(match.namedGroup('m')!),
    seconds: int.parse(match.namedGroup('s')!),
    milliseconds: int.parse(millis),
  );
}

String formatUpnpTime(Duration value) {
  final total = value.inMilliseconds.clamp(0, 1 << 51);
  String pad(int number, [int width = 2]) => '$number'.padLeft(width, '0');
  return '${pad(total ~/ 3600000)}:${pad((total ~/ 60000) % 60)}'
      ':${pad((total ~/ 1000) % 60)}.${pad(total % 1000, 3)}';
}

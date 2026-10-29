import 'package:hongguo_update/hongguo_update.dart';
import 'package:test/test.dart';

void main() {
  ReleaseVersion parse(String text) => ReleaseVersion.tryParse(text)!;

  test('a tag and a pubspec version describe the same release', () {
    expect(parse('v0.3.13').versionText, '0.3.13');
    expect(parse('0.3.13+25').versionText, '0.3.13');
    expect(parse('0.3.13+25').build, 25);
    expect(parse('7.2.2.32').versionText, '7.2.2.32');
    expect(parse('v0.3.13').toString(), 'v0.3.13');
  });

  test('the fourth segment is a rebuild of one tag, not a newer version', () {
    expect(parse('0.3.13+25').isNewerThan(parse('v0.3.13')), isFalse);
    expect(parse('0.3.13').isNewerThan(parse('0.3.13+25')), isFalse);
  });

  test('versions compare by segment, not by string', () {
    expect(parse('0.4').isNewerThan(parse('0.3.9')), isTrue);
    expect(parse('0.3.14').isNewerThan(parse('0.3.13+25')), isTrue);
    expect(parse('0.3.12').isNewerThan(parse('0.3.13')), isFalse);
    expect(parse('1.0.0').compareTo(parse('0.99.99')), 1);
  });

  test('a suffix never makes an older release look newer', () {
    expect(parse('0.3.13-beta').versionText, '0.3.13');
    expect(parse('0.3.13-beta').isNewerThan(parse('0.3.13')), isFalse);
    expect(parse('0.3.13-beta').isNewerThan(parse('0.3.12')), isTrue);
  });

  test('nonsense is no version at all', () {
    for (final text in ['', '  ', 'beta', 'v', '0..1']) {
      expect(ReleaseVersion.tryParse(text), isNull, reason: text);
    }
  });
}
